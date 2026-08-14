import hashlib
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import types
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from protocol import JobRequest, NarrationChunk, split_narration_chunks
from server import CharacterVoiceRegistry, JobManager, _book_speaker_gender, _synthesis_voice, _utf16_offset
from tts_backends import (
    CosyVoiceBackend,
    ToneTestBackend,
    WindowsSAPIBackend,
    normalize_gpt_sovits_audio,
)
from voice_catalog import approved_voices


class GenerationTests(unittest.TestCase):
    def test_gpt_sovits_int16_audio_is_scaled_before_wav_write(self):
        import numpy

        audio = numpy.array([-32768, -16384, 0, 16384, 32767], dtype=numpy.int16)
        normalized = normalize_gpt_sovits_audio(audio, 32_000)

        self.assertEqual(normalized.dtype, numpy.float32)
        self.assertAlmostEqual(float(normalized[0]), -1.0, places=6)
        self.assertAlmostEqual(float(normalized[1]), -0.5, places=6)
        self.assertAlmostEqual(float(normalized[3]), 0.5, places=6)
        self.assertLessEqual(float(abs(normalized).max()), 1.0)

    def test_timeline_offsets_use_ios_utf16_units(self):
        self.assertEqual(_utf16_offset("甲😀乙", 2), 3)

    def test_multi_role_resolves_named_speaker_to_catalog_voice(self):
        chunk = NarrationChunk(
            text="“现在出发。”",
            start_offset=0,
            end_offset=7,
            role="female",
            speaker="何雁",
            gender="female",
        )

        voice = _synthesis_voice("multi-role", chunk)

        self.assertIn(voice, {item["id"] for item in approved_voices("female")})
        self.assertEqual(voice, _synthesis_voice("multi-role", chunk))

    def test_character_voice_registry_uses_batch_gender_and_survives_restart(self):
        first_text = "夜色很深。何雁轻声问：“现在出发吗？”"
        evidence_text = "年轻女士何雁站在门边，她正在等待回答。"
        common = {
            "book_id": "character-book",
            "book_title": "人物声线测试",
            "author": "作者",
            "voice": "multi-role",
            "speed": 1.0,
        }
        requests = [
            JobRequest(
                chapter_id="chapter-1",
                chapter_url="https://example.test/character/1",
                chapter_index=0,
                chapter_title="第一章",
                text=first_text,
                text_sha256=hashlib.sha256(first_text.encode("utf-8")).hexdigest(),
                **common,
            ),
            JobRequest(
                chapter_id="chapter-2",
                chapter_url="https://example.test/character/2",
                chapter_index=1,
                chapter_title="第二章",
                text=evidence_text,
                text_sha256=hashlib.sha256(evidence_text.encode("utf-8")).hexdigest(),
                **common,
            ),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "character-voices.json"
            registry = CharacterVoiceRegistry(path)
            registry.observe(requests)
            dialogue = next(
                chunk
                for chunk in split_narration_chunks(first_text, "multi-role")
                if chunk.speaker == "何雁"
            )
            first_voice = registry.resolve("character-book", dialogue)
            registry.observe([requests[0]])
            repeated_voice = registry.resolve("character-book", dialogue)
            restored = CharacterVoiceRegistry(path)

            self.assertIn(
                first_voice,
                {item["id"] for item in approved_voices("female")},
            )
            self.assertEqual(repeated_voice, first_voice)
            self.assertEqual(restored.resolve("character-book", dialogue), first_voice)

    def test_character_voice_registry_resolves_ren_jing_as_female(self):
        dialogue_text = "任静看了看欧雪雁的房间，说道：“你先回去吧。”"
        evidence_text = "深槐认出了任静小姐。深夜，阿静她仍然留在书房。"
        common = {
            "book_id": "yi-song",
            "book_title": "异悚",
            "author": "黑色火种",
            "voice": "multi-role",
            "speed": 1.0,
        }
        requests = [
            JobRequest(
                chapter_id="chapter-9",
                chapter_url="https://example.test/yi-song/9",
                chapter_index=8,
                chapter_title="第九章",
                text=dialogue_text,
                text_sha256=hashlib.sha256(dialogue_text.encode("utf-8")).hexdigest(),
                **common,
            ),
            JobRequest(
                chapter_id="chapter-evidence",
                chapter_url="https://example.test/yi-song/evidence",
                chapter_index=9,
                chapter_title="人物证据",
                text=evidence_text,
                text_sha256=hashlib.sha256(evidence_text.encode("utf-8")).hexdigest(),
                **common,
            ),
        ]

        with tempfile.TemporaryDirectory() as directory:
            registry = CharacterVoiceRegistry(Path(directory) / "character-voices.json")
            registry.observe(requests)
            dialogue = next(
                chunk
                for chunk in split_narration_chunks(dialogue_text, "multi-role")
                if chunk.speaker == "任静"
            )

            voice = registry.resolve("yi-song", dialogue)

            conflicting_text = "一个男人，任静随后说道：“继续行动。”"
            conflicting_request = JobRequest(
                chapter_id="chapter-conflict",
                chapter_url="https://example.test/yi-song/conflict",
                chapter_index=10,
                chapter_title="局部歧义",
                text=conflicting_text,
                text_sha256=hashlib.sha256(conflicting_text.encode("utf-8")).hexdigest(),
                **common,
            )
            registry.observe([conflicting_request])

            self.assertEqual(registry.books["yi-song"]["任静"]["gender"], "female")
            self.assertIn(voice, {item["id"] for item in approved_voices("female")})

    def test_character_voice_registry_ignores_legacy_polluted_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "character-voices.json"
            path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "books": {
                            "yi-song": {
                                "说": {"gender": "male", "voice_id": "legacy"},
                                "阿静": {"gender": "male", "voice_id": "legacy"},
                            }
                        },
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            registry = CharacterVoiceRegistry(path)

            self.assertEqual(registry.books, {})

    def test_explicit_title_outweighs_unrelated_following_pronouns(self):
        text = "任静小姐走进房间。任静，他们随后才想起这个名字。任静他们没有继续追问。"

        self.assertEqual(_book_speaker_gender("任静", text), "female")

    def test_repeated_same_sentence_pronouns_infer_character_gender(self):
        text = "岳洁走进房间，她放下了提包。岳洁点点头，她同意这个安排。"

        self.assertEqual(_book_speaker_gender("岳洁", text), "female")

    def test_identity_description_infers_character_gender(self):
        text = "储藏室中央倒着一个男人，他是林言臣。这部电影的男主演陈楚安来到现场。"

        self.assertEqual(_book_speaker_gender("林言臣", text), "male")
        self.assertEqual(_book_speaker_gender("陈楚安", text), "male")

    def test_clause_subject_pronoun_infers_character_gender(self):
        text = "孙组长发现大家疲惫，其实他自己也很累。张胜磊看重这场戏，他力求完美。"

        self.assertEqual(_book_speaker_gender("孙组长", text), "male")
        self.assertEqual(_book_speaker_gender("张胜磊", text), "male")

    def test_direct_name_pronoun_outweighs_nearby_other_characters(self):
        text = (
            "阿静她仍然留在书房。阿静看向润暗，他没有回答。"
            "阿静提到深槐，他随后离开。阿静问起慕镜，他也保持沉默。"
        )

        self.assertEqual(_book_speaker_gender("阿静", text), "female")

    def test_delete_book_removes_queued_jobs_and_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            manager = JobManager(ToneTestBackend(), Path(directory))
            manager.shutdown()
            for index in range(2):
                text = f"第{index + 1}章正文。"
                manager.submit(
                    JobRequest(
                        book_id="delete-book",
                        book_title="删除测试",
                        author="作者",
                        chapter_id=f"chapter-{index}",
                        chapter_url=f"https://example.test/delete/{index}",
                        chapter_index=index,
                        chapter_title=f"第{index + 1}章",
                        text=text,
                        text_sha256=hashlib.sha256(text.encode("utf-8")).hexdigest(),
                        voice="multi-role",
                        speed=1.0,
                    )
                )

            result = manager.delete_book("delete-book", "multi-role", 1.0)

            self.assertEqual(result["deleted_count"], 2)
            self.assertEqual(manager.jobs, {})
            self.assertEqual(list(manager.jobs_dir.glob("*.json")), [])

    def test_new_voice_discards_same_chapter_old_pending_job(self):
        text = "同一章节只保留最新音色的未完成任务。"
        common = {
            "book_id": "dedupe-book",
            "book_title": "去重测试",
            "author": "作者",
            "chapter_id": "same-chapter",
            "chapter_url": "https://example.test/dedupe/1",
            "chapter_index": 0,
            "chapter_title": "第一章",
            "text": text,
            "text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "speed": 1.0,
        }
        old_request = JobRequest(voice="reference", **common)
        new_request = JobRequest(voice="multi-role", **common)

        with tempfile.TemporaryDirectory() as directory:
            manager = JobManager(ToneTestBackend(), Path(directory))
            manager.shutdown()
            old_job = manager.submit(old_request)
            old_file = manager.jobs_dir / f"{old_job.job_id}.json"
            self.assertTrue(old_file.is_file())

            discarded = manager.discard_superseded_pending(new_request)

            self.assertEqual(discarded, 1)
            self.assertIsNone(manager.get(old_job.job_id))
            self.assertEqual(old_job.status, "superseded")
            self.assertFalse(old_file.exists())

    def test_restored_queue_keeps_original_submission_order(self):
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            manager = JobManager(ToneTestBackend(), data_dir)
            manager.shutdown()
            persisted_files = []
            for index in range(3):
                text = f"第{index + 1}章正文。"
                request = JobRequest(
                    book_id="ordered-book",
                    book_title="顺序测试",
                    author="作者",
                    chapter_id=f"chapter-{index}",
                    chapter_url=f"https://example.test/ordered/{index}",
                    chapter_index=index,
                    chapter_title=f"第{index + 1}章",
                    text=text,
                    text_sha256=hashlib.sha256(text.encode("utf-8")).hexdigest(),
                    voice="multi-role",
                    speed=1.0,
                )
                job = manager.submit(request)
                target = manager.jobs_dir / f"{job.job_id}.json"
                payload = json.loads(target.read_text(encoding="utf-8"))
                payload["created_at"] = f"2026-08-11T00:00:0{index}+00:00"
                target.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
                persisted_files.append(target)

            for order, target in enumerate(reversed(persisted_files)):
                target.rename(manager.jobs_dir / f"restore-{order}.json")

            restored = object.__new__(JobManager)
            restored.jobs_dir = manager.jobs_dir
            restored.audio_dir = manager.audio_dir
            restored.jobs = {}
            restored.lock = threading.RLock()
            pending = restored._restore_jobs()

            self.assertEqual(
                [restored.jobs[job_id].request.chapter_index for job_id in pending],
                [0, 1, 2],
            )

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
