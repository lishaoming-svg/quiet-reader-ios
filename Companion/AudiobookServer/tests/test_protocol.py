import hashlib
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from protocol import JobRequest, ProtocolError, normalize_narration_text, split_narration_text


class ProtocolTests(unittest.TestCase):
    def test_split_preserves_every_character(self):
        text = "第一段很短。" + "这是用于验证长句切分完整性的正文，" * 40 + "最后一句结束！\n下一段。"
        chunks = split_narration_text(text, maximum=80, minimum=12)
        self.assertGreater(len(chunks), 3)
        self.assertEqual("".join(chunks), text)
        self.assertTrue(all(0 < len(chunk) <= 80 for chunk in chunks))

    def test_request_validates_normalized_text_hash(self):
        text = normalize_narration_text(" 第一段。 \r\n\r\n 第二段。 ")
        payload = {
            "protocol_version": 1,
            "book_id": "book",
            "book_title": "测试书",
            "author": "作者",
            "chapter_id": "chapter-1",
            "chapter_index": 0,
            "chapter_title": "第一章",
            "text": " 第一段。 \r\n\r\n 第二段。 ",
            "text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "voice": "default",
            "speed": 1.0,
        }
        request = JobRequest.from_dict(payload)
        self.assertEqual(request.text, "第一段。\n第二段。")
        self.assertEqual(request.stable_job_id, JobRequest.from_dict(payload).stable_job_id)

    def test_request_rejects_hash_mismatch(self):
        with self.assertRaises(ProtocolError):
            JobRequest.from_dict(
                {
                    "protocol_version": 1,
                    "book_id": "book",
                    "book_title": "测试书",
                    "chapter_id": "chapter",
                    "chapter_index": 0,
                    "chapter_title": "第一章",
                    "text": "正文",
                    "text_sha256": "0" * 64,
                }
            )


if __name__ == "__main__":
    unittest.main()

