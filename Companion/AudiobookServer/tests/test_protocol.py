import hashlib
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from protocol import (
    ROLE_FEMALE,
    ROLE_MALE,
    ROLE_NARRATOR,
    ROLE_PROTAGONIST,
    JobRequest,
    ProtocolError,
    normalize_narration_text,
    split_narration_chunks,
    split_narration_text,
)


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
            "protocol_version": 4,
            "book_id": "book",
            "book_title": "测试书",
            "author": "作者",
            "chapter_id": "chapter-1",
            "chapter_url": "https://example.test/chapter/1",
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
                    "protocol_version": 4,
                    "book_id": "book",
                    "book_title": "测试书",
                    "chapter_id": "chapter",
                    "chapter_url": "https://example.test/chapter/1",
                    "chapter_index": 0,
                    "chapter_title": "第一章",
                    "text": "正文",
                    "text_sha256": "0" * 64,
                }
            )

    def test_multi_role_chunks_preserve_text_and_assign_dialogue_roles(self):
        text = "雨声越来越大。林舟说：“我们现在出发。”女孩问：“我也一起去吗？”窗外雷声滚过。"
        chunks = split_narration_chunks(text, "multi-role", maximum=20, minimum=5)
        self.assertEqual("".join(chunk.text for chunk in chunks), text)
        roles = {chunk.role for chunk in chunks}
        self.assertIn(ROLE_NARRATOR, roles)
        self.assertIn(ROLE_PROTAGONIST, roles)
        self.assertTrue(roles.intersection({ROLE_MALE, ROLE_FEMALE}))
        self.assertEqual(chunks[0].start_offset, 0)
        self.assertEqual(chunks[-1].end_offset, len(text))


if __name__ == "__main__":
    unittest.main()
