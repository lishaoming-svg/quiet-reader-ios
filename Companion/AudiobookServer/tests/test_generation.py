import hashlib
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from protocol import JobRequest
from server import JobManager
from tts_backends import ToneTestBackend, WindowsSAPIBackend


class GenerationTests(unittest.TestCase):
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
