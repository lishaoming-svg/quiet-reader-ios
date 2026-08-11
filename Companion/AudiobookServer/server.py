from __future__ import annotations

import argparse
import base64
import io
import json
import os
import queue
import secrets
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import wave
from dataclasses import dataclass, field
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse

from protocol import (
    MULTI_ROLE_VOICE,
    JobRequest,
    NarrationChunk,
    ProtocolError,
    split_narration_chunks,
    timing_ranges,
)
from tts_backends import TTSBackend, create_backend


SERVER_VERSION = "0.2.0"
MAX_REQUEST_BYTES = 2 * 1024 * 1024
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
            "protocol_version": 1,
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
        self.jobs_dir.mkdir(parents=True, exist_ok=True)
        self.audio_dir.mkdir(parents=True, exist_ok=True)
        self.jobs: dict[str, JobState] = {}
        self.lock = threading.RLock()
        self.work_queue: queue.Queue[str | None] = queue.Queue()
        self.worker = threading.Thread(target=self._run_worker, name="audiobook-worker", daemon=True)
        self.worker.start()

    def submit(self, request: JobRequest) -> JobState:
        job_id = request.stable_job_id
        with self.lock:
            existing = self.jobs.get(job_id)
            if existing:
                if existing.status == "failed":
                    existing.status = "queued"
                    existing.progress = 0.0
                    existing.completed_segments = 0
                    existing.total_segments = 0
                    existing.error = None
                    existing.segments = []
                    existing.updated_at = utc_now()
                    self._persist(existing)
                    self.work_queue.put(job_id)
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

    def shutdown(self) -> None:
        self.work_queue.put(None)
        self.worker.join(timeout=5)

    def _persist(self, state: JobState) -> None:
        payload = state.public_dict() | {"request": state.request.public_dict()}
        target = self.jobs_dir / f"{state.job_id}.json"
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        temporary.replace(target)

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
            if state is None:
                continue
            try:
                self._generate(state)
            except Exception as error:
                self._update(state, status="failed", error=str(error), progress=0.0)

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
        path = urlparse(self.path).path
        if path == "/":
            self._send_pairing_page()
            return
        if path == "/v1/health":
            if not self._authorized():
                return
            self._send_json(
                HTTPStatus.OK,
                {
                    "protocol_version": 1,
                    "service": "墨阅听书生成器",
                    "server_version": SERVER_VERSION,
                    "status": "ready",
                    "engine": self.server.manager.backend.engine_id,
                    "engine_name": self.server.manager.backend.display_name,
                    "voices": self.server.manager.backend.voices(),
                },
            )
            return
        if not self._authorized():
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
        if path != "/v1/jobs":
            self._send_error(HTTPStatus.NOT_FOUND, "请求地址不存在")
            return
        try:
            payload = self._read_json()
            request = JobRequest.from_dict(payload)
            job = self.server.manager.submit(request)
            self._send_json(HTTPStatus.ACCEPTED, job.public_dict())
        except ProtocolError as error:
            self._send_error(HTTPStatus.BAD_REQUEST, str(error))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send_error(HTTPStatus.BAD_REQUEST, "请求 JSON 无效")
        except ValueError as error:
            self._send_error(HTTPStatus.BAD_REQUEST, str(error))

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

    def _send_audio(self, job: JobState) -> None:
        if job.status != "completed" or job.audio_path is None or not job.audio_path.is_file():
            self._send_error(HTTPStatus.CONFLICT, "章节音频尚未生成完成")
            return
        data = job.audio_path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "audio/mp4")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Disposition", f'attachment; filename="{job.job_id}.m4a"')
        self.end_headers()
        self.wfile.write(data)

    def _send_pairing_page(self) -> None:
        pairing_uri = (
            "quietreader://audiobook-pair?url="
            f"{quote(self.server.public_url, safe='')}&token={quote(self.server.pairing_token, safe='')}"
        )
        qr_html = ""
        try:
            import qrcode

            image = qrcode.make(pairing_uri)
            buffer = io.BytesIO()
            image.save(buffer, format="PNG")
            encoded = base64.b64encode(buffer.getvalue()).decode("ascii")
            qr_html = f'<img alt="配对二维码" src="data:image/png;base64,{encoded}" width="280" height="280">'
        except ImportError:
            qr_html = "<p>安装 requirements.txt 后可显示二维码。</p>"
        html = f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>墨阅听书生成器</title>
<style>body{{font-family:serif;background:#f7f0dc;color:#172833;max-width:680px;margin:40px auto;padding:24px}}main{{background:#fffdf5;padding:28px;border-radius:22px;box-shadow:0 12px 40px #5a3d2520}}code{{word-break:break-all}}img{{display:block;margin:20px auto}}</style></head>
<body><main><h1>墨阅听书生成器</h1><p>服务器已启动：{self.server.manager.backend.display_name}</p>
{qr_html}<p>在 iPhone 墨阅的听书面板中扫描二维码，或手工填写：</p>
<p>地址：<code>{self.server.public_url}</code></p><p>配对码：<code>{self.server.pairing_token}</code></p>
<p>手机与电脑需要连接同一个局域网。音频下载完成后可以关闭电脑。</p></main></body></html>"""
        data = html.encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

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
    print("关闭窗口或按 Ctrl+C 可停止服务")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        manager.shutdown()


if __name__ == "__main__":
    main()
