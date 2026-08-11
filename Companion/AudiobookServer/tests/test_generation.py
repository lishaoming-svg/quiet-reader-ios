import hashlib
import os
import shutil
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from protocol import JobRequest
from server import JobManager
from tts_backends import CosyVoiceBackend, ToneTestBackend, WindowsSAPIBackend


class GenerationTests(unittest.TestCase):
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
                self.assertEqual(retried.status, "completed", retried.error)
                self.assertEqual(retried.job_id, first.job_id)
                self.assertEqual(backend.attempts, 2)
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
            finally:
                manager.shutdown()

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
