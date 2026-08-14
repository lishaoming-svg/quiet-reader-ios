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
            "protocol_version": 5,
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
                    "protocol_version": 5,
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
        dialogue = [chunk for chunk in chunks if chunk.role != ROLE_NARRATOR]
        self.assertTrue(any(chunk.speaker for chunk in dialogue))
        self.assertTrue(any(chunk.gender == ROLE_FEMALE for chunk in dialogue))

    def test_compound_speech_verb_keeps_clean_speaker_and_chapter_gender(self):
        text = "何雁是一位年轻女士。过了一会儿，何雁轻声问：“真的准备好了吗？”"
        chunks = split_narration_chunks(text, "multi-role", maximum=30, minimum=5)
        dialogue = next(chunk for chunk in chunks if chunk.speaker)

        self.assertEqual(dialogue.speaker, "何雁")
        self.assertEqual(dialogue.gender, ROLE_FEMALE)

    def test_pronoun_dialogue_resolves_to_nearest_explicit_person(self):
        text = "林舟说：“先等等。”年轻女士何雁站在门边，她轻声问：“怎么了？”"
        chunks = split_narration_chunks(text, "multi-role", maximum=30, minimum=5)
        dialogue = [chunk for chunk in chunks if chunk.speaker]

        self.assertEqual(dialogue[0].speaker, "林舟")
        self.assertIsNone(dialogue[0].gender)
        self.assertEqual(dialogue[1].speaker, "何雁")
        self.assertEqual(dialogue[1].gender, ROLE_FEMALE)

    def test_post_dialogue_gender_context_resolves_named_female_speaker(self):
        text = (
            "任静看了看欧雪雁的房间，说道：“你先回去吧。”"
            "润暗也不禁感叹这个女人的坚强。"
        )
        chunks = split_narration_chunks(text, "multi-role", maximum=30, minimum=5)
        dialogue = [chunk for chunk in chunks if chunk.role != ROLE_NARRATOR]

        self.assertTrue(dialogue)
        self.assertEqual(dialogue[0].speaker, "任静")
        self.assertEqual(dialogue[0].gender, ROLE_FEMALE)
        self.assertNotIn(dialogue[0].speaker, {"说", "说道", "回答", "回答道", "耐心地"})

    def test_action_phrases_do_not_become_speaker_names(self):
        cases = (
            ("任静把地图摊开在她面前，耐心地说：“往这里走。”", "任静"),
            ("润暗疑惑地问：“你确定吗？”", "润暗"),
            ("听任静那么说，欧雪雁立即向她点头致谢，还哭着说：“谢谢。”", "欧雪雁"),
            ("临走以前，润丽还郑重其事地说：“等我回来。”", "润丽"),
        )

        for text, expected_speaker in cases:
            with self.subTest(text=text):
                chunks = split_narration_chunks(text, "multi-role", maximum=40, minimum=5)
                dialogue = next(chunk for chunk in chunks if chunk.role != ROLE_NARRATOR)
                self.assertEqual(dialogue.speaker, expected_speaker)

    def test_narrative_actions_are_never_registered_as_speakers(self):
        cases = (
            "女孩抬起头，见是润暗，立即说道：“恶魔，你是恶魔。”",
            "阿静不忍拒绝他的好意，于是点了点头，说：“那好吧。”",
            "阿静看着外祖父，说到这里，突然问：“你母亲提过吗？”",
            "阿静此刻又出现了落寞的眼神，说道：“我明白。”",
        )
        invalid = {"立即", "点了点头", "说到这里", "突然", "阿静此刻"}

        for text in cases:
            with self.subTest(text=text):
                chunks = split_narration_chunks(text, "multi-role", maximum=50, minimum=5)
                speakers = {chunk.speaker for chunk in chunks if chunk.speaker}
                self.assertTrue(speakers.isdisjoint(invalid), speakers)

    def test_pronoun_antecedent_rejects_action_phrase(self):
        text = "这位小姐点头回答道：“嗯，是的。”她摇摇头，说：“没有啊。”"
        chunks = split_narration_chunks(text, "multi-role", maximum=40, minimum=5)
        speakers = {chunk.speaker for chunk in chunks if chunk.speaker}

        self.assertNotIn("点头回答", speakers)

    def test_common_narration_fragments_do_not_become_speakers(self):
        cases = (
            ("他的眼神突然变得冰冷，说道：“离开这里。”", "他"),
            ("岳洁会心一笑，说：“我知道了。”", "岳洁"),
            ("阿静其实早有准备，说道：“开始吧。”", "阿静"),
            ("门被打开，接着说道：“里面有人吗？”", None),
        )

        for text, expected in cases:
            with self.subTest(text=text):
                chunks = split_narration_chunks(text, "multi-role", maximum=40, minimum=5)
                dialogue = next(chunk for chunk in chunks if chunk.role != ROLE_NARRATOR)
                self.assertEqual(dialogue.speaker, expected)


if __name__ == "__main__":
    unittest.main()
