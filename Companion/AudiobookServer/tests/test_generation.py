import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
import types
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from protocol import JobRequest
from server import JobManager, _utf16_offset
from tts_backends import CosyVoiceBackend, ToneTestBackend, WindowsSAPIBackend


class GenerationTests(unittest.TestCase):
    def test_timeline_offsets_use_ios_utf16_units(self):
        self.assertEqual(_utf16_offset("甲😀乙", 2), 3)

    def test_failed_job_can_be_retried_with_same_identifier(self):
        class FailsOnceBackend(ToneTestBackend):
            def __init__(self):
                self.attempts = 0

            def synthesize(self, text, output_path, voice, speed):
                self.attempts += 1
                if self.attempts == 1:
                    raise RuntimeError("首次生成失败")
                super().synthesize(text, output_path, voice, speed)

        text = "失败后使用同一个任务标识重试。"
        request = JobRequest(
            book_id="retry-book",
            book_title="重试测试",
            author="作者",
            chapter_id="retry-chapter",
            chapter_url="https://example.test/retry/1",
            chapter_index=0,
            chapter_title="第一章",
            text=text,
            text_sha256=hashlib.sha256(text.encode("utf-8")).hexdigest(),
            voice="default",
            speed=1.0,
        )
        with tempfile.TemporaryDirectory() as directory:
            backend = FailsOnceBackend()
            manager = JobManager(backend, Path(directory))
            try:
                first = manager.submit(request)
                deadline = time.time() + 5
                while first.status in ("queued", "running") and time.time() < deadline:
                    time.sleep(0.05)
                self.assertEqual(first.status, "failed")

                retried = manager.submit(request)
                deadline = time.time() + 10
                while retried.status in ("queued", "running") and time.time() < deadline:
                    time.sleep(0.05)
                self.assertEqual(retried.job_id, first.job_id)
                self.assertEqual(backend.attempts, 2)
                if shutil.which("ffmpeg"):
                    self.assertEqual(retried.status, "completed", retried.error)
                else:
                    self.assertEqual(retried.status, "failed")
                    self.assertIn("ffmpeg", retried.error)
            finally:
                manager.shutdown()

    def test_cosyvoice_writes_standard_pcm_wave(self):
        class FakeAudio:
            def cpu(self):
                return self

        class FakeModel:
            sample_rate = 24_000

            def inference_zero_shot(self, *args, **kwargs):
                return iter([{"tts_speech": FakeAudio()}])

        calls = []

        class FakeTorchaudio:
            @staticmethod
            def save(*args, **kwargs):
                calls.append((args, kwargs))

        fake_torch = types.ModuleType("torch")
        fake_torch.cat = lambda tensors, dim: tensors[0]
        backend = object.__new__(CosyVoiceBackend)
        backend.model = FakeModel()
        backend.prompt_audio = Path("prompt.wav")
        backend.prompt_text = "参考文字"
        backend._torchaudio = FakeTorchaudio()

        with patch.dict(sys.modules, {"torch": fake_torch}):
            backend.synthesize("正文", Path("output.wav"), "reference", 1.0)

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1]["encoding"], "PCM_S")
        self.assertEqual(calls[0][1]["bits_per_sample"], 16)

    @unittest.skipUnless(shutil.which("ffmpeg"), "需要 FFmpeg 验证 M4A 编码")
    def test_job_generates_playable_m4a(self):
        text = "第一段。第二段也应该完整生成。"
        request = JobRequest(
            book_id="book",
            book_title="测试书",
            author="作者",
            chapter_id="chapter",
            chapter_url="https://example.test/chapter/1",
            chapter_index=0,
            chapter_title="第一章",
            text=text,
            text_sha256=hashlib.sha256(text.encode("utf-8")).hexdigest(),
            voice="default",
            speed=1.0,
        )
        with tempfile.TemporaryDirectory() as directory:
            manager = JobManager(ToneTestBackend(), Path(directory))
            try:
                job = manager.submit(request)
                deadline = time.time() + 15
                while job.status in ("queued", "running") and time.time() < deadline:
                    time.sleep(0.05)
                self.assertEqual(job.status, "completed", job.error)
                self.assertIsNotNone(job.audio_path)
                self.assertGreater(job.file_size, 512)
                self.assertEqual(job.completed_segments, job.total_segments)
                self.assertGreater(len(job.segments), 0)
                self.assertEqual(job.segments[0]["start_offset"], 0)
                self.assertEqual(job.segments[-1]["end_offset"], len(text))
            finally:
                manager.shutdown()

    @unittest.skipUnless(shutil.which("ffmpeg"), "需要 FFmpeg 验证多角色时间轴")
    def test_multi_role_job_exposes_distinct_roles_and_continuous_offsets(self):
        text = "夜色很深。林舟说：“我们走。”女孩问：“现在吗？”风吹过长街。"
        request = JobRequest(
            book_id="roles-book",
            book_title="角色测试",
            author="作者",
            chapter_id="roles-chapter",
            chapter_url="https://example.test/roles/1",
            chapter_index=0,
            chapter_title="第一章",
            text=text,
            text_sha256=hashlib.sha256(text.encode("utf-8")).hexdigest(),
            voice="multi-role",
            speed=1.0,
        )
        with tempfile.TemporaryDirectory() as directory:
            manager = JobManager(ToneTestBackend(), Path(directory))
            try:
                job = manager.submit(request)
                deadline = time.time() + 15
                while job.status in ("queued", "running") and time.time() < deadline:
                    time.sleep(0.05)
                self.assertEqual(job.status, "completed", job.error)
                self.assertEqual("".join(segment["text"] for segment in job.segments), text)
                self.assertGreater(len({segment["role"] for segment in job.segments}), 1)
            finally:
                manager.shutdown()

    @unittest.skipUnless(shutil.which("ffmpeg"), "需要 FFmpeg 验证伴读包")
    def test_completed_job_restores_and_exports_readaloud_package(self):
        text = "第一段。第二段也会进入逐句时间轴。"
        request = JobRequest(
            book_id="package-book",
            book_title="伴读包测试",
            author="作者",
            chapter_id="package-chapter",
            chapter_url="https://example.test/package/1",
            chapter_index=0,
            chapter_title="第一章",
            text=text,
            text_sha256=hashlib.sha256(text.encode("utf-8")).hexdigest(),
            voice="default",
            speed=1.0,
        )
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            manager = JobManager(ToneTestBackend(), data_dir)
            job = manager.submit(request)
            deadline = time.time() + 15
            while job.status in ("queued", "running") and time.time() < deadline:
                time.sleep(0.05)
            self.assertEqual(job.status, "completed", job.error)
            manager.shutdown()

            restored = JobManager(ToneTestBackend(), data_dir)
            try:
                restored_job = restored.get(job.job_id)
                self.assertIsNotNone(restored_job)
                self.assertEqual(restored_job.status, "completed")
                self.assertEqual(restored_job.request.text, text)
                package = restored.create_package("package-book", "default", 1.0)
                with zipfile.ZipFile(package) as archive:
                    manifest = json.loads(archive.read("manifest.json").decode("utf-8"))
                    self.assertEqual(manifest["format"], "quietreader-readaloud")
                    self.assertEqual(manifest["chapter_count"], 1)
                    chapter = manifest["chapters"][0]
                    self.assertEqual(chapter["chapter_url"], request.chapter_url)
                    self.assertEqual("".join(item["text"] for item in chapter["segments"]), text)
                    self.assertGreater(len(archive.read(chapter["file_name"])), 512)
            finally:
                restored.shutdown()

    @unittest.skipUnless(os.name == "nt", "仅在 Windows 验证系统语音")
    def test_windows_sapi_generates_real_voice_wave(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "speech.wav"
            backend = WindowsSAPIBackend(ROOT / "sapi_synthesize.ps1")
            backend.synthesize("这是一段墨阅听书测试语音。", target, "Microsoft Huihui Desktop", 1.0)
            self.assertTrue(target.is_file())
            self.assertGreater(target.stat().st_size, 1_024)


if __name__ == "__main__":
    unittest.main()
