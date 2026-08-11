import hashlib
import json
import multiprocessing
import shutil
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from server import (
    AudiobookHTTPServer,
    HealthHTTPServer,
    HealthRequestHandler,
    JobManager,
    RequestHandler,
    serve_health_sidecar,
)
from tts_backends import ToneTestBackend


@unittest.skipUnless(shutil.which("ffmpeg"), "需要 FFmpeg 验证完整 HTTP 链路")
class HTTPServerTests(unittest.TestCase):
    def test_spawned_health_sidecar_responds_independently(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        payload = {
            "protocol_version": 4,
            "service": "墨阅听书生成器",
            "server_version": "0.4.2",
            "status": "ready",
            "engine": "cosyvoice3",
            "engine_name": "CosyVoice 3",
            "voices": [],
        }
        process = multiprocessing.get_context("spawn").Process(
            target=serve_health_sidecar,
            args=("127.0.0.1", port, "spawned-sidecar-token", payload),
        )
        process.start()
        deadline = time.time() + 10
        try:
            while True:
                try:
                    value = self._json_request(
                        f"http://127.0.0.1:{port}/v1/health",
                        token="spawned-sidecar-token",
                    )
                    break
                except urllib.error.URLError:
                    if time.time() >= deadline:
                        raise
                    time.sleep(0.05)
            self.assertEqual(value["server_version"], "0.4.2")
            self.assertTrue(process.is_alive())
        finally:
            process.terminate()
            process.join(timeout=3)

    def test_health_sidecar_responds_without_job_manager(self):
        server = HealthHTTPServer(("127.0.0.1", 0), HealthRequestHandler)
        server.pairing_token = "sidecar-pairing-token"
        server.health_payload = {
            "protocol_version": 4,
            "service": "墨阅听书生成器",
            "server_version": "0.4.2",
            "status": "ready",
            "engine": "cosyvoice3",
            "engine_name": "CosyVoice 3",
            "voices": [],
        }
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            value = self._json_request(
                f"http://127.0.0.1:{server.server_port}/v1/health",
                token="sidecar-pairing-token",
            )
            self.assertEqual(value["protocol_version"], 4)
            self.assertEqual(value["engine"], "cosyvoice3")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

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
                self.assertEqual(health["queue"]["running_count"], 0)
                self.assertEqual(health["queue"]["queued_count"], 0)

                text = "第一段。第二段完整生成。"
                payload = {
                    "protocol_version": 4,
                    "book_id": "book",
                    "book_title": "测试书",
                    "author": "作者",
                    "chapter_id": "chapter",
                    "chapter_url": "https://example.test/chapter/1",
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
                batch = self._json_request(
                    f"{base_url}/v1/jobs/batch",
                    data=json.dumps(
                        {"protocol_version": 4, "jobs": [payload]},
                        ensure_ascii=False,
                    ).encode("utf-8"),
                )
                self.assertEqual(batch["accepted_count"], 1)
                self.assertEqual(batch["discarded_count"], 0)
                deadline = time.time() + 10
                status = submitted
                while status["status"] in ("queued", "running") and time.time() < deadline:
                    time.sleep(0.05)
                    status = self._json_request(f"{base_url}/v1/jobs/{submitted['job_id']}")
                self.assertEqual(status["status"], "completed", status.get("error"))

                query = urllib.parse.urlencode(
                    {"book_id": "book", "voice": "default", "speed": "1.00"}
                )
                book_status = self._json_request(f"{base_url}/v1/books/status?{query}")
                self.assertEqual(book_status["completed_count"], 1)
                package_request = urllib.request.Request(
                    f"{base_url}/v1/books/package?{query}",
                    headers={"Authorization": "Bearer test-pairing-token-123456"},
                )
                with urllib.request.urlopen(package_request, timeout=5) as response:
                    package = response.read()
                    self.assertEqual(
                        response.headers.get_content_type(),
                        "application/vnd.quietreader.readaloud+zip",
                    )
                self.assertGreater(len(package), 512)

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

    def _json_request(
        self,
        url: str,
        data: bytes | None = None,
        token: str = "test-pairing-token-123456",
    ):
        request = urllib.request.Request(
            url,
            data=data,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json; charset=utf-8",
            },
            method="POST" if data is not None else "GET",
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.loads(response.read().decode("utf-8"))


if __name__ == "__main__":
    unittest.main()
