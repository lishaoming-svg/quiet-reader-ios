from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
import queue
import re
import secrets
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import webbrowser
import wave
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, quote, urlparse

from protocol import (
    MULTI_ROLE_VOICE,
    PROTOCOL_VERSION,
    JobRequest,
    NarrationChunk,
    ProtocolError,
    split_narration_chunks,
    timing_ranges,
)
from tts_backends import TTSBackend, create_backend


SERVER_VERSION = "0.5.2"
MAX_REQUEST_BYTES = 32 * 1024 * 1024
MAX_BATCH_JOBS = 5_000
SEGMENT_PAUSE_SECONDS = 0.12


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def local_ipv4() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("192.0.2.1", 80))
        return str(sock.getsockname()[0])
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


def audio_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as source:
        return source.getnframes() / max(1, source.getframerate())


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_file_name(value: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", value).strip(" .")
    return cleaned[:60] or "墨阅伴读包"


def merge_wave_files(paths: list[Path], output_path: Path, pause_seconds: float = 0.12) -> None:
    if not paths:
        raise RuntimeError("没有可合并的语音分段")
    with wave.open(str(paths[0]), "rb") as first:
        parameters = first.getparams()
        first_frames = first.readframes(first.getnframes())

    with wave.open(str(output_path), "wb") as target:
        target.setparams(parameters)
        target.writeframes(first_frames)
        silence_frames = int(parameters.framerate * pause_seconds)
        silence = bytes(silence_frames * parameters.nchannels * parameters.sampwidth)
        for path in paths[1:]:
            with wave.open(str(path), "rb") as source:
                if (
                    source.getnchannels() != parameters.nchannels
                    or source.getsampwidth() != parameters.sampwidth
                    or source.getframerate() != parameters.framerate
                ):
                    raise RuntimeError("语音分段格式不一致")
                target.writeframes(silence)
                target.writeframes(source.readframes(source.getnframes()))


@dataclass
class JobState:
    job_id: str
    request: JobRequest
    status: str = "queued"
    progress: float = 0.0
    completed_segments: int = 0
    total_segments: int = 0
    error: str | None = None
    audio_path: Path | None = None
    file_size: int = 0
    segments: list[dict[str, Any]] = field(default_factory=list)
    created_at: str = field(default_factory=utc_now)
    updated_at: str = field(default_factory=utc_now)

    def public_dict(self) -> dict[str, Any]:
        return {
            "protocol_version": PROTOCOL_VERSION,
            "job_id": self.job_id,
            "status": self.status,
            "progress": self.progress,
            "completed_segments": self.completed_segments,
            "total_segments": self.total_segments,
            "error": self.error,
            "file_size": self.file_size,
            "segments": self.segments,
            "chapter_index": self.request.chapter_index,
            "chapter_id": self.request.chapter_id,
            "chapter_title": self.request.chapter_title,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "audio_path": f"/v1/jobs/{self.job_id}/audio" if self.status == "completed" else None,
        }


class JobManager:
    def __init__(self, backend: TTSBackend, data_dir: Path, ffmpeg: str = "ffmpeg") -> None:
        self.backend = backend
        self.data_dir = data_dir
        self.ffmpeg = ffmpeg
        self.jobs_dir = data_dir / "jobs"
        self.audio_dir = data_dir / "audio"
        self.packages_dir = data_dir / "packages"
        self.jobs_dir.mkdir(parents=True, exist_ok=True)
        self.audio_dir.mkdir(parents=True, exist_ok=True)
        self.packages_dir.mkdir(parents=True, exist_ok=True)
        self.jobs: dict[str, JobState] = {}
        self.lock = threading.RLock()
        self.package_lock = threading.Lock()
        self.work_queue: queue.Queue[str | None] = queue.Queue()
        pending_jobs = self._restore_jobs()
        self.worker = threading.Thread(target=self._run_worker, name="audiobook-worker", daemon=True)
        self.worker.start()
        for job_id in pending_jobs:
            self.work_queue.put(job_id)

    def submit(self, request: JobRequest) -> JobState:
        job_id = request.stable_job_id
        with self.lock:
            existing = self.jobs.get(job_id)
            if existing:
                existing.request = request
                if existing.status == "failed" or (
                    existing.status == "completed" and not existing.segments
                ):
                    if existing.audio_path is not None and existing.audio_path.is_file():
                        existing.audio_path.unlink()
                    existing.status = "queued"
                    existing.progress = 0.0
                    existing.completed_segments = 0
                    existing.total_segments = 0
                    existing.error = None
                    existing.audio_path = None
                    existing.file_size = 0
                    existing.segments = []
                    existing.updated_at = utc_now()
                    self._persist(existing)
                    self.work_queue.put(job_id)
                else:
                    self._persist(existing)
                return existing
            audio_path = self.audio_dir / f"{job_id}.m4a"
            state = JobState(job_id=job_id, request=request)
            if audio_path.is_file() and audio_path.stat().st_size > 0:
                state.status = "completed"
                state.progress = 1.0
                state.audio_path = audio_path
                state.file_size = audio_path.stat().st_size
            self.jobs[job_id] = state
            self._persist(state)
            if state.status == "queued":
                self.work_queue.put(job_id)
            return state

    def get(self, job_id: str) -> JobState | None:
        with self.lock:
            return self.jobs.get(job_id)

    def delete_job(self, job_id: str) -> dict[str, Any]:
        with self.package_lock:
            with self.lock:
                state = self.jobs.get(job_id)
                if state is None:
                    raise ProtocolError("找不到听书任务")
                if state.status == "running":
                    raise ProtocolError("当前章节正在生成，请等待本章完成后删除")
                identity = (
                    state.request.book_id,
                    state.request.voice,
                    state.request.speed,
                )
                deleted_bytes = state.file_size
                self.jobs.pop(job_id)
                self._delete_job_files(state)
            self._invalidate_package(*identity)
        return {"deleted_count": 1, "deleted_bytes": deleted_bytes}

    def delete_book(self, book_id: str, voice: str, speed: float) -> dict[str, Any]:
        with self.package_lock:
            with self.lock:
                jobs = self._book_jobs(book_id, voice, speed)
                if not jobs:
                    raise ProtocolError("找不到这本书的生成记录")
                if any(job.status == "running" for job in jobs):
                    raise ProtocolError("这本书仍有章节正在生成，请等待当前章完成后删除")
                deleted_bytes = sum(job.file_size for job in jobs)
                for state in jobs:
                    self.jobs.pop(state.job_id, None)
                    self._delete_job_files(state)
            self._invalidate_package(book_id, voice, speed)
        return {"deleted_count": len(jobs), "deleted_bytes": deleted_bytes}

    def discard_superseded_pending(self, request: JobRequest) -> int:
        with self.lock:
            discarded_ids = [
                job_id
                for job_id, job in self.jobs.items()
                if job_id != request.stable_job_id
                and job.request.book_id == request.book_id
                and job.request.chapter_id == request.chapter_id
                and job.status in {"queued", "failed"}
            ]
            for job_id in discarded_ids:
                state = self.jobs.pop(job_id)
                state.status = "superseded"
                target = self.jobs_dir / f"{job_id}.json"
                if target.is_file():
                    target.unlink()
            return len(discarded_ids)

    def queue_summary(self) -> dict[str, int]:
        with self.lock:
            return {
                "running_count": sum(job.status == "running" for job in self.jobs.values()),
                "queued_count": sum(job.status == "queued" for job in self.jobs.values()),
                "failed_count": sum(job.status == "failed" for job in self.jobs.values()),
            }

    def dashboard_status(self) -> dict[str, Any]:
        with self.lock:
            jobs = sorted(
                self.jobs.values(),
                key=lambda job: (job.created_at, job.request.chapter_index, job.job_id),
            )
            book_groups: dict[tuple[str, str, float], dict[str, Any]] = {}
            job_items: list[dict[str, Any]] = []
            for job in jobs:
                request = job.request
                key = (request.book_id, request.voice, request.speed)
                group = book_groups.setdefault(
                    key,
                    {
                        "book_id": request.book_id,
                        "book_title": request.book_title,
                        "author": request.author,
                        "voice": request.voice,
                        "speed": request.speed,
                        "total_count": 0,
                        "completed_count": 0,
                        "running_count": 0,
                        "queued_count": 0,
                        "failed_count": 0,
                        "completed_bytes": 0,
                        "updated_at": job.updated_at,
                    },
                )
                group["total_count"] += 1
                count_key = f"{job.status}_count"
                if count_key in group:
                    group[count_key] += 1
                if job.status == "completed":
                    group["completed_bytes"] += job.file_size
                group["updated_at"] = max(group["updated_at"], job.updated_at)
                job_items.append(
                    {
                        "job_id": job.job_id,
                        "book_id": request.book_id,
                        "book_title": request.book_title,
                        "author": request.author,
                        "chapter_index": request.chapter_index,
                        "chapter_title": request.chapter_title,
                        "voice": request.voice,
                        "speed": request.speed,
                        "status": job.status,
                        "progress": job.progress,
                        "completed_segments": job.completed_segments,
                        "total_segments": job.total_segments,
                        "file_size": job.file_size,
                        "error": job.error,
                        "updated_at": job.updated_at,
                    }
                )
            books = sorted(
                book_groups.values(),
                key=lambda item: item["updated_at"],
                reverse=True,
            )
            return {
                "protocol_version": PROTOCOL_VERSION,
                "server_version": SERVER_VERSION,
                "engine": self.backend.engine_id,
                "engine_name": self.backend.display_name,
                "voices": self.backend.voices(),
                "queue": self.queue_summary(),
                "books": books,
                "jobs": job_items,
            }

    def book_status(self, book_id: str, voice: str, speed: float) -> dict[str, Any]:
        with self.lock:
            jobs = self._book_jobs(book_id, voice, speed)
            jobs.sort(key=lambda job: (job.request.chapter_index, job.request.chapter_id))
            counts = {
                status: sum(job.status == status for job in jobs)
                for status in ("completed", "running", "queued", "failed")
            }
            return {
                "protocol_version": PROTOCOL_VERSION,
                "book_id": book_id,
                "voice": voice,
                "generation_speed": speed,
                "total_count": len(jobs),
                "completed_count": counts["completed"],
                "running_count": counts["running"],
                "queued_count": counts["queued"],
                "failed_count": counts["failed"],
                "completed_bytes": sum(
                    job.file_size for job in jobs if job.status == "completed"
                ),
                "jobs": [
                    {
                        "job_id": job.job_id,
                        "chapter_id": job.request.chapter_id,
                        "chapter_index": job.request.chapter_index,
                        "chapter_title": job.request.chapter_title,
                        "status": job.status,
                        "progress": job.progress,
                        "file_size": job.file_size,
                    }
                    for job in jobs
                ],
            }

    def create_package(self, book_id: str, voice: str, speed: float) -> Path:
        with self.package_lock:
            return self._create_package(book_id, voice, speed)

    def _delete_job_files(self, state: JobState) -> None:
        audio_path = self.audio_dir / f"{state.job_id}.m4a"
        if audio_path.is_file():
            audio_path.unlink()
        metadata_path = self.jobs_dir / f"{state.job_id}.json"
        if metadata_path.is_file():
            metadata_path.unlink()

    def _invalidate_package(self, book_id: str, voice: str, speed: float) -> None:
        package_key = hashlib.sha256(
            f"{book_id}\n{voice}\n{speed:.2f}".encode("utf-8")
        ).hexdigest()[:24]
        for target in self.packages_dir.glob(f"*-{package_key}.qraudio"):
            target.unlink()
        marker = self.packages_dir / f"{package_key}.sha256"
        if marker.is_file():
            marker.unlink()

    def _create_package(self, book_id: str, voice: str, speed: float) -> Path:
        with self.lock:
            jobs = [
                job for job in self._book_jobs(book_id, voice, speed)
                if job.status == "completed"
                and job.audio_path is not None
                and job.audio_path.is_file()
                and job.segments
            ]
        if not jobs:
            raise ProtocolError("这本书还没有已完成且带时间轴的章节")
        jobs.sort(key=lambda job: (job.request.chapter_index, job.request.chapter_id))
        first = jobs[0].request
        fingerprint_source = "\n".join(
            f"{job.job_id}:{job.file_size}:{job.updated_at}" for job in jobs
        )
        fingerprint = hashlib.sha256(fingerprint_source.encode("utf-8")).hexdigest()
        package_key = hashlib.sha256(
            f"{book_id}\n{voice}\n{speed:.2f}".encode("utf-8")
        ).hexdigest()[:24]
        safe_title = _safe_file_name(first.book_title)
        target = self.packages_dir / f"{safe_title}-{package_key}.qraudio"
        marker = self.packages_dir / f"{package_key}.sha256"
        if (
            target.is_file()
            and target.stat().st_size > 0
            and marker.is_file()
            and marker.read_text(encoding="ascii").strip() == fingerprint
        ):
            return target

        chapters: list[dict[str, Any]] = []
        for job in jobs:
            audio_path = job.audio_path
            assert audio_path is not None
            file_name = f"chapters/{job.request.chapter_id}.m4a"
            chapters.append(
                {
                    "chapter_id": job.request.chapter_id,
                    "chapter_url": job.request.chapter_url,
                    "chapter_index": job.request.chapter_index,
                    "chapter_title": job.request.chapter_title,
                    "file_name": file_name,
                    "file_size": audio_path.stat().st_size,
                    "audio_sha256": _file_sha256(audio_path),
                    "text_sha256": job.request.text_sha256,
                    "segments": job.segments,
                }
            )
        manifest = {
            "format": "quietreader-readaloud",
            "format_version": 1,
            "protocol_version": PROTOCOL_VERSION,
            "created_at": utc_now(),
            "book_id": first.book_id,
            "book_title": first.book_title,
            "author": first.author,
            "voice": voice,
            "generation_speed": speed,
            "chapter_count": len(chapters),
            "package_fingerprint": fingerprint,
            "chapters": chapters,
        }
        temporary = target.with_suffix(".tmp")
        if temporary.exists():
            temporary.unlink()
        with zipfile.ZipFile(temporary, "w", allowZip64=True) as archive:
            archive.writestr(
                "manifest.json",
                json.dumps(manifest, ensure_ascii=False, indent=2),
                compress_type=zipfile.ZIP_DEFLATED,
            )
            for job, chapter in zip(jobs, chapters, strict=True):
                assert job.audio_path is not None
                archive.write(job.audio_path, chapter["file_name"], compress_type=zipfile.ZIP_STORED)
        temporary.replace(target)
        marker.write_text(fingerprint, encoding="ascii")
        return target

    def shutdown(self) -> None:
        self.work_queue.put(None)
        self.worker.join(timeout=5)

    def _persist(self, state: JobState) -> None:
        payload = state.public_dict() | {"request": state.request.storage_dict()}
        target = self.jobs_dir / f"{state.job_id}.json"
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        temporary.replace(target)

    def _restore_jobs(self) -> list[str]:
        pending: list[tuple[str, int, str]] = []
        for target in sorted(self.jobs_dir.glob("*.json")):
            try:
                payload = json.loads(target.read_text(encoding="utf-8"))
                request = JobRequest.from_storage_dict(payload["request"])
                job_id = str(payload["job_id"])
                audio_path = self.audio_dir / f"{job_id}.m4a"
                status = str(payload.get("status", "failed"))
                is_pending = False
                if status == "completed" and not audio_path.is_file():
                    status = "failed"
                if status == "completed" and not payload.get("segments"):
                    status = "failed"
                if status in {"queued", "running"}:
                    if request.text:
                        status = "queued"
                        is_pending = True
                    else:
                        status = "failed"
                state = JobState(
                    job_id=job_id,
                    request=request,
                    status=status,
                    progress=float(payload.get("progress", 0)),
                    completed_segments=int(payload.get("completed_segments", 0)),
                    total_segments=int(payload.get("total_segments", 0)),
                    error=payload.get("error"),
                    audio_path=audio_path if status == "completed" else None,
                    file_size=audio_path.stat().st_size if status == "completed" else 0,
                    segments=list(payload.get("segments", [])),
                    created_at=str(payload.get("created_at", utc_now())),
                    updated_at=str(payload.get("updated_at", utc_now())),
                )
                if status == "failed" and not state.error:
                    state.error = "服务重启后缺少可恢复的正文，请从手机重新提交"
                self.jobs[job_id] = state
                if is_pending:
                    pending.append((state.created_at, request.chapter_index, job_id))
            except (KeyError, TypeError, ValueError, json.JSONDecodeError):
                continue
        return [job_id for _, _, job_id in sorted(pending)]

    def _book_jobs(self, book_id: str, voice: str, speed: float) -> list[JobState]:
        return [
            job for job in self.jobs.values()
            if job.request.book_id == book_id
            and job.request.voice == voice
            and abs(job.request.speed - speed) < 0.001
        ]

    def _update(self, state: JobState, **values: Any) -> None:
        with self.lock:
            for key, value in values.items():
                setattr(state, key, value)
            state.updated_at = utc_now()
            self._persist(state)

    def _run_worker(self) -> None:
        while True:
            job_id = self.work_queue.get()
            if job_id is None:
                return
            state = self.get(job_id)
            if state is None or state.status != "queued":
                continue
            try:
                self._generate(state)
            except Exception as error:
                self._update(state, status="failed", error=str(error), progress=0.0)
            if self.work_queue.empty():
                self._export_ready_packages()

    def _export_ready_packages(self) -> None:
        with self.lock:
            combinations = {
                (job.request.book_id, job.request.voice, job.request.speed)
                for job in self.jobs.values()
                if job.status == "completed"
            }
            active = {
                (job.request.book_id, job.request.voice, job.request.speed)
                for job in self.jobs.values()
                if job.status in {"queued", "running"}
            }
        for book_id, voice, speed in combinations - active:
            try:
                self.create_package(book_id, voice, speed)
            except (OSError, ProtocolError, zipfile.BadZipFile):
                continue

    def _generate(self, state: JobState) -> None:
        chunks = split_narration_chunks(state.request.text, state.request.voice)
        if not chunks or "".join(chunk.text for chunk in chunks) != state.request.text:
            raise RuntimeError("正文分段完整性校验失败")
        self._update(
            state,
            status="running",
            total_segments=len(chunks),
            error=None,
            segments=[],
        )

        with tempfile.TemporaryDirectory(prefix=f"quietreader-{state.job_id}-") as raw_temp:
            temp_dir = Path(raw_temp)
            wave_paths: list[Path] = []
            timeline: list[dict[str, Any]] = []
            elapsed = 0.0
            for index, chunk in enumerate(chunks):
                segment_path = temp_dir / f"segment-{index:04d}.wav"
                synthesis_voice = _synthesis_voice(state.request.voice, chunk)
                self.backend.synthesize(
                    chunk.text,
                    segment_path,
                    synthesis_voice,
                    state.request.speed,
                )
                if not segment_path.is_file() or segment_path.stat().st_size < 256:
                    raise RuntimeError(f"第 {index + 1} 个语音分段生成失败")
                duration = audio_duration(segment_path)
                if duration <= 0.03:
                    raise RuntimeError(f"第 {index + 1} 个语音分段时长异常")
                if index > 0:
                    elapsed += SEGMENT_PAUSE_SECONDS
                timeline.extend(
                    _timeline_for_chunk(chunk, elapsed, duration, state.request.text)
                )
                elapsed += duration
                wave_paths.append(segment_path)
                completed = index + 1
                self._update(
                    state,
                    completed_segments=completed,
                    progress=completed / len(chunks) * 0.9,
                    segments=list(timeline),
                )

            merged_wave = temp_dir / "chapter.wav"
            merge_wave_files(wave_paths, merged_wave, pause_seconds=SEGMENT_PAUSE_SECONDS)
            final_path = self.audio_dir / f"{state.job_id}.m4a"
            temporary_m4a = temp_dir / "chapter.m4a"
            subprocess.run(
                [
                    self.ffmpeg,
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-y",
                    "-i",
                    str(merged_wave),
                    "-vn",
                    "-ac",
                    "1",
                    "-c:a",
                    "aac",
                    "-b:a",
                    "48k",
                    str(temporary_m4a),
                ],
                check=True,
            )
            if temporary_m4a.stat().st_size < 512:
                raise RuntimeError("章节音频编码失败")
            shutil.move(str(temporary_m4a), final_path)

        self._update(
            state,
            status="completed",
            progress=1.0,
            completed_segments=len(chunks),
            audio_path=final_path,
            file_size=final_path.stat().st_size,
            segments=timeline,
        )


def _synthesis_voice(requested_voice: str, chunk: NarrationChunk) -> str:
    if requested_voice == MULTI_ROLE_VOICE:
        return f"role-{chunk.role}"
    return requested_voice


def _timeline_for_chunk(
    chunk: NarrationChunk,
    start_time: float,
    duration: float,
    full_text: str,
) -> list[dict[str, Any]]:
    ranges = timing_ranges(chunk.text)
    if not ranges:
        ranges = [(0, len(chunk.text))]
    total_characters = max(1, sum(end - start for start, end in ranges))
    result: list[dict[str, Any]] = []
    cursor = start_time
    for index, (start, end) in enumerate(ranges):
        ratio = (end - start) / total_characters
        unit_duration = duration * ratio
        unit_end = start_time + duration if index == len(ranges) - 1 else cursor + unit_duration
        result.append(
            {
                "text": chunk.text[start:end],
                "role": chunk.role,
                "start_time": round(cursor, 3),
                "end_time": round(unit_end, 3),
                "start_offset": _utf16_offset(full_text, chunk.start_offset + start),
                "end_offset": _utf16_offset(full_text, chunk.start_offset + end),
            }
        )
        cursor = unit_end
    return result


def _utf16_offset(text: str, codepoint_offset: int) -> int:
    return len(text[:codepoint_offset].encode("utf-16-le")) // 2


class AudiobookHTTPServer(ThreadingHTTPServer):
    manager: JobManager
    pairing_token: str
    public_url: str


class RequestHandler(BaseHTTPRequestHandler):
    server: AudiobookHTTPServer

    def log_message(self, format_string: str, *args: Any) -> None:
        print(f"[{self.log_date_time_string()}] {format_string % args}")

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/":
            self._send_pairing_page()
            return
        if path == "/v1/pairing/qr":
            self._send_pairing_qr()
            return
        if path == "/v1/health":
            if not self._authorized():
                return
            self._send_json(
                HTTPStatus.OK,
                {
                    "protocol_version": PROTOCOL_VERSION,
                    "service": "墨阅听书生成器",
                    "server_version": SERVER_VERSION,
                    "status": "ready",
                    "engine": self.server.manager.backend.engine_id,
                    "engine_name": self.server.manager.backend.display_name,
                    "voices": self.server.manager.backend.voices(),
                    "queue": self.server.manager.queue_summary(),
                    "capabilities": [
                        "persistent-queue",
                        "readaloud-package-v1",
                        "batch-job-submit",
                    ],
                },
            )
            return
        if not self._authorized():
            return
        if path == "/v1/dashboard":
            payload = self.server.manager.dashboard_status()
            payload["public_url"] = self._current_public_url()
            self._send_json(HTTPStatus.OK, payload)
            return
        if path in {"/v1/books/status", "/v1/books/package"}:
            try:
                book_id, voice, speed = self._book_query(parsed.query)
                if path == "/v1/books/status":
                    self._send_json(
                        HTTPStatus.OK,
                        self.server.manager.book_status(book_id, voice, speed),
                    )
                else:
                    package_path = self.server.manager.create_package(book_id, voice, speed)
                    self._send_file(
                        package_path,
                        content_type="application/vnd.quietreader.readaloud+zip",
                        download_name="QuietReader.qraudio",
                    )
            except ProtocolError as error:
                self._send_error(HTTPStatus.CONFLICT, str(error))
            return
        if path.startswith("/v1/jobs/"):
            parts = [part for part in path.split("/") if part]
            if len(parts) not in (3, 4):
                self._send_error(HTTPStatus.NOT_FOUND, "请求地址不存在")
                return
            job = self.server.manager.get(parts[2])
            if job is None:
                self._send_error(HTTPStatus.NOT_FOUND, "找不到听书任务")
                return
            if len(parts) == 4 and parts[3] == "audio":
                self._send_audio(job)
                return
            self._send_json(HTTPStatus.OK, job.public_dict())
            return
        self._send_error(HTTPStatus.NOT_FOUND, "请求地址不存在")

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if not self._authorized():
            return
        if path == "/v1/control/stop":
            self._send_json(HTTPStatus.ACCEPTED, {"message": "生成器正在停止"})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if path not in {"/v1/jobs", "/v1/jobs/batch"}:
            self._send_error(HTTPStatus.NOT_FOUND, "请求地址不存在")
            return
        try:
            payload = self._read_json()
            if path == "/v1/jobs":
                request = JobRequest.from_dict(payload)
                self.server.manager.discard_superseded_pending(request)
                job = self.server.manager.submit(request)
                self._send_json(HTTPStatus.ACCEPTED, job.public_dict())
            else:
                self._submit_batch(payload)
        except ProtocolError as error:
            self._send_error(HTTPStatus.BAD_REQUEST, str(error))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send_error(HTTPStatus.BAD_REQUEST, "请求 JSON 无效")
        except ValueError as error:
            self._send_error(HTTPStatus.BAD_REQUEST, str(error))

    def do_DELETE(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if not self._authorized():
            return
        try:
            if path.startswith("/v1/jobs/"):
                parts = [part for part in path.split("/") if part]
                if len(parts) != 3:
                    raise ProtocolError("请求地址不存在")
                result = self.server.manager.delete_job(parts[2])
            elif path == "/v1/books/tasks":
                book_id, voice, speed = self._book_query(parsed.query)
                result = self.server.manager.delete_book(book_id, voice, speed)
            else:
                self._send_error(HTTPStatus.NOT_FOUND, "请求地址不存在")
                return
            self._send_json(HTTPStatus.OK, result)
        except ProtocolError as error:
            self._send_error(HTTPStatus.CONFLICT, str(error))
        except OSError as error:
            self._send_error(HTTPStatus.INTERNAL_SERVER_ERROR, f"删除文件失败：{error}")

    def _submit_batch(self, payload: dict[str, Any]) -> None:
        if payload.get("protocol_version") != PROTOCOL_VERSION:
            raise ProtocolError("协议版本不匹配")
        values = payload.get("jobs")
        if not isinstance(values, list) or not values:
            raise ProtocolError("批量任务不能为空")
        if len(values) > MAX_BATCH_JOBS:
            raise ProtocolError(f"单次最多提交 {MAX_BATCH_JOBS} 章")
        if not all(isinstance(value, dict) for value in values):
            raise ProtocolError("批量任务格式无效")
        requests = [JobRequest.from_dict(value) for value in values]
        discarded_count = sum(
            self.server.manager.discard_superseded_pending(request)
            for request in requests
        )
        jobs = [self.server.manager.submit(request) for request in requests]
        self._send_json(
            HTTPStatus.ACCEPTED,
            {
                "protocol_version": PROTOCOL_VERSION,
                "accepted_count": len(jobs),
                "discarded_count": discarded_count,
            },
        )

    def _authorized(self) -> bool:
        if self.headers.get("Authorization") == f"Bearer {self.server.pairing_token}":
            return True
        self._send_error(HTTPStatus.UNAUTHORIZED, "配对令牌无效")
        return False

    def _read_json(self) -> dict[str, Any]:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise ProtocolError("缺少请求长度")
        length = int(raw_length)
        if length <= 0 or length > MAX_REQUEST_BYTES:
            raise ProtocolError("请求大小超过限制")
        value = json.loads(self.rfile.read(length).decode("utf-8"))
        if not isinstance(value, dict):
            raise ProtocolError("请求内容必须是 JSON 对象")
        return value

    def _book_query(self, raw_query: str) -> tuple[str, str, float]:
        query = parse_qs(raw_query)
        book_id = query.get("book_id", [""])[0].strip()
        voice = query.get("voice", [""])[0].strip()
        try:
            speed = float(query.get("speed", ["1"])[0])
        except ValueError as error:
            raise ProtocolError("生成语速无效") from error
        if not book_id or len(book_id) > 512:
            raise ProtocolError("书籍标识无效")
        if not voice or len(voice) > 128:
            raise ProtocolError("音色标识无效")
        if not 0.5 <= speed <= 2.0:
            raise ProtocolError("生成语速必须在 0.5 到 2.0 之间")
        return book_id, voice, speed

    def _send_audio(self, job: JobState) -> None:
        if job.status != "completed" or job.audio_path is None or not job.audio_path.is_file():
            self._send_error(HTTPStatus.CONFLICT, "章节音频尚未生成完成")
            return
        self._send_file(
            job.audio_path,
            content_type="audio/mp4",
            download_name=f"{job.job_id}.m4a",
        )

    def _send_file(self, path: Path, content_type: str, download_name: str) -> None:
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(path.stat().st_size))
        self.send_header("Content-Disposition", f'attachment; filename="{download_name}"')
        self.end_headers()
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                self.wfile.write(chunk)

    def _send_pairing_page(self) -> None:
        public_url = self._current_public_url()
        pairing_uri = (
            "quietreader://audiobook-pair?url="
            f"{quote(public_url, safe='')}&token={quote(self.server.pairing_token, safe='')}"
        )
        qr_html = ""
        try:
            import qrcode

            image = qrcode.make(pairing_uri)
            buffer = io.BytesIO()
            image.save(buffer, format="PNG")
            encoded = base64.b64encode(buffer.getvalue()).decode("ascii")
            qr_html = f'<img id="pairing-qr" alt="配对二维码" src="data:image/png;base64,{encoded}" width="280" height="280">'
        except ImportError:
            qr_html = "<p>安装 requirements.txt 后可显示二维码。</p>"
        template_path = Path(__file__).resolve().with_name("dashboard.html")
        html = template_path.read_text(encoding="utf-8")
        html = html.replace("__QR_HTML__", qr_html)
        replacements = {
            "__PUBLIC_URL_JSON__": json.dumps(public_url, ensure_ascii=False),
            "__PAIRING_TOKEN_JSON__": json.dumps(self.server.pairing_token, ensure_ascii=False),
            "__PAIRING_URI_JSON__": json.dumps(pairing_uri, ensure_ascii=False),
            "__ENGINE_NAME_JSON__": json.dumps(
                self.server.manager.backend.display_name,
                ensure_ascii=False,
            ),
        }
        for marker, value in replacements.items():
            html = html.replace(marker, value.replace("</", "<\\/"))
        data = html.encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_pairing_qr(self) -> None:
        try:
            import qrcode

            public_url = self._current_public_url()
            pairing_uri = (
                "quietreader://audiobook-pair?url="
                f"{quote(public_url, safe='')}&token={quote(self.server.pairing_token, safe='')}"
            )
            image = qrcode.make(pairing_uri)
            buffer = io.BytesIO()
            image.save(buffer, format="PNG")
            data = buffer.getvalue()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "image/png")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except ImportError:
            self._send_error(HTTPStatus.SERVICE_UNAVAILABLE, "二维码组件尚未安装")

    def _current_public_url(self) -> str:
        return f"http://{local_ipv4()}:{self.server.server_port}"

    def _send_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_error(self, status: HTTPStatus, message: str) -> None:
        self._send_json(status, {"error": message, "status": int(status)})


def pairing_token(data_dir: Path) -> str:
    target = data_dir / "pairing-token.txt"
    if target.is_file():
        value = target.read_text(encoding="utf-8").strip()
        if len(value) >= 16:
            return value
    value = secrets.token_urlsafe(24)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(value, encoding="utf-8")
    return value


def parse_args() -> argparse.Namespace:
    base_dir = Path(__file__).resolve().parent
    runtime_dir = base_dir / ".runtime"
    parser = argparse.ArgumentParser(description="墨阅 Windows 本地听书生成器")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--data-dir", default=str(base_dir / "data"))
    parser.add_argument("--engine", choices=("sapi", "cosyvoice", "tone"), default="sapi")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--cosyvoice-home", default=str(runtime_dir / "CosyVoice"))
    parser.add_argument(
        "--cosyvoice-model",
        default=str(runtime_dir / "CosyVoice" / "pretrained_models" / "Fun-CosyVoice3-0.5B"),
    )
    parser.add_argument("--prompt-audio", default=os.environ.get("QUIETREADER_PROMPT_AUDIO", ""))
    parser.add_argument("--prompt-text", default=os.environ.get("QUIETREADER_PROMPT_TEXT", ""))
    parser.add_argument("--open-browser", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    base_dir = Path(__file__).resolve().parent
    data_dir = Path(args.data_dir).resolve()
    backend = create_backend(args, base_dir)
    manager = JobManager(backend, data_dir, args.ffmpeg)
    token = pairing_token(data_dir)
    host_ip = local_ipv4()
    public_url = f"http://{host_ip}:{args.port}"

    server = AudiobookHTTPServer((args.host, args.port), RequestHandler)
    server.manager = manager
    server.pairing_token = token
    server.public_url = public_url
    print("墨阅听书生成器已启动")
    print(f"语音引擎：{backend.display_name}")
    print(f"配对页面：{public_url}")
    print(f"连接检查：{public_url}/v1/health")
    print("关闭窗口或按 Ctrl+C 可停止服务")
    if args.open_browser:
        webbrowser.open(public_url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        manager.shutdown()


if __name__ == "__main__":
    main()
