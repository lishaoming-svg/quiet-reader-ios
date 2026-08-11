import hashlib
import json
import shutil
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from server import AudiobookHTTPServer, JobManager, RequestHandler
from tts_backends import ToneTestBackend


@unittest.skipUnless(shutil.which("ffmpeg"), "需要 FFmpeg 验证完整 HTTP 链路")
class HTTPServerTests(unittest.TestCase):
    def test_authorized_job_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            manager = JobManager(ToneTestBackend(), Path(directory))
            server = AudiobookHTTPServer(("127.0.0.1", 0), RequestHandler)
            server.manager = manager
            server.pairing_token = "test-pairing-token-123456"
            server.public_url = f"http://127.0.0.1:{server.server_port}"
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base_url = server.public_url
            try:
                with self.assertRaises(urllib.error.HTTPError) as unauthorized:
                    urllib.request.urlopen(f"{base_url}/v1/health", timeout=2)
                self.assertEqual(unauthorized.exception.code, 401)

                health = self._json_request(f"{base_url}/v1/health")
                self.assertEqual(health["engine"], "tone-test")

                text = "第一段。第二段完整生成。"
                payload = {
                    "protocol_version": 1,
                    "book_id": "book",
                    "book_title": "测试书",
                    "author": "作者",
                    "chapter_id": "chapter",
                    "chapter_index": 0,
                    "chapter_title": "第一章",
                    "text": text,
                    "text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
                    "voice": "default",
                    "speed": 1.0,
                }
                submitted = self._json_request(
                    f"{base_url}/v1/jobs",
                    data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                )
                deadline = time.time() + 10
                status = submitted
                while status["status"] in ("queued", "running") and time.time() < deadline:
                    time.sleep(0.05)
                    status = self._json_request(f"{base_url}/v1/jobs/{submitted['job_id']}")
                self.assertEqual(status["status"], "completed", status.get("error"))

                request = urllib.request.Request(
                    f"{base_url}/v1/jobs/{submitted['job_id']}/audio",
                    headers={"Authorization": "Bearer test-pairing-token-123456"},
                )
                with urllib.request.urlopen(request, timeout=5) as response:
                    audio = response.read()
                    self.assertEqual(response.headers.get_content_type(), "audio/mp4")
                self.assertGreater(len(audio), 512)
            finally:
                server.shutdown()
                server.server_close()
                manager.shutdown()
                thread.join(timeout=5)

    def _json_request(self, url: str, data: bytes | None = None):
        request = urllib.request.Request(
            url,
            data=data,
            headers={
                "Authorization": "Bearer test-pairing-token-123456",
                "Content-Type": "application/json; charset=utf-8",
            },
            method="POST" if data is not None else "GET",
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.loads(response.read().decode("utf-8"))


if __name__ == "__main__":
    unittest.main()
