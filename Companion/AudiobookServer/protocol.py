from __future__ import annotations

from dataclasses import asdict, dataclass
from hashlib import sha256
import re
from typing import Any


PROTOCOL_VERSION = 1
MAX_CHAPTER_CHARACTERS = 100_000
SENTENCE_ENDINGS = frozenset("。！？!?；;\n")
SOFT_ENDINGS = frozenset("，,、：:")
MULTI_ROLE_VOICE = "multi-role"
ROLE_NARRATOR = "narrator"
ROLE_PROTAGONIST = "protagonist"
ROLE_MALE = "male"
ROLE_FEMALE = "female"
SPEECH_VERBS = "说|问|喊|叫|答|道|回应|开口|低声说|轻声说|大声说|笑道|哭道"


class ProtocolError(ValueError):
    pass


def require_string(payload: dict[str, Any], key: str, maximum: int) -> str:
    value = payload.get(key)
    if not isinstance(value, str):
        raise ProtocolError(f"字段 {key} 必须是字符串")
    value = value.strip()
    if not value:
        raise ProtocolError(f"字段 {key} 不能为空")
    if len(value) > maximum:
        raise ProtocolError(f"字段 {key} 超过长度限制")
    return value


def normalize_narration_text(text: str) -> str:
    lines = [line.strip() for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    return "\n".join(line for line in lines if line)


def split_narration_text(text: str, maximum: int = 240, minimum: int = 45) -> list[str]:
    if maximum < 20 or minimum < 1 or minimum >= maximum:
        raise ValueError("分段长度设置无效")
    if not text:
        return []

    chunks: list[str] = []
    start = 0
    last_soft_break: int | None = None
    for index, character in enumerate(text):
        length = index - start + 1
        if character in SOFT_ENDINGS:
            last_soft_break = index + 1
        if character in SENTENCE_ENDINGS and length >= minimum:
            chunks.append(text[start : index + 1])
            start = index + 1
            last_soft_break = None
            continue
        if length >= maximum:
            end = last_soft_break if last_soft_break and last_soft_break > start else index + 1
            chunks.append(text[start:end])
            start = end
            last_soft_break = None

    if start < len(text):
        chunks.append(text[start:])
    return [chunk for chunk in chunks if chunk]


@dataclass(frozen=True)
class NarrationChunk:
    text: str
    start_offset: int
    end_offset: int
    role: str = ROLE_NARRATOR


def split_narration_chunks(
    text: str,
    voice: str,
    maximum: int = 240,
    minimum: int = 45,
) -> list[NarrationChunk]:
    dialogue_ranges = _dialogue_ranges(text)
    source_spans = _source_spans(text, dialogue_ranges) if voice == MULTI_ROLE_VOICE else [(0, len(text), False)]
    raw_chunks: list[tuple[str, int, int, bool]] = []
    for span_start, span_end, is_dialogue in source_spans:
        span_text = text[span_start:span_end]
        local_offset = 0
        span_chunks = (
            [span_text]
            if is_dialogue and len(span_text) <= maximum
            else split_narration_text(span_text, maximum=maximum, minimum=minimum)
        )
        for value in span_chunks:
            start = span_start + local_offset
            end = start + len(value)
            raw_chunks.append((value, start, end, is_dialogue))
            local_offset += len(value)
    if not raw_chunks:
        return []

    protagonist: str | None = None
    known_roles: dict[str, str] = {}
    unknown_dialogue_count = 0
    result: list[NarrationChunk] = []
    for chunk, start, end, is_dialogue in raw_chunks:
        role = ROLE_NARRATOR
        if voice == MULTI_ROLE_VOICE and is_dialogue:
            context_start = max(0, start - 40)
            context_end = min(len(text), end + 40)
            context = text[context_start:context_end]
            speaker = _speaker_name(context, start - context_start)
            gender = _speaker_gender(speaker, context)

            if speaker and speaker not in {"他", "她", "它", "我", "你", "您"}:
                if protagonist is None:
                    protagonist = speaker
                    known_roles[speaker] = ROLE_PROTAGONIST
                role = known_roles.get(speaker, gender or ROLE_MALE)
                known_roles.setdefault(speaker, role)
            elif protagonist is None:
                protagonist = speaker or "__first_dialogue__"
                role = ROLE_PROTAGONIST
            elif gender:
                role = gender
            else:
                role = ROLE_MALE if unknown_dialogue_count % 2 == 0 else ROLE_FEMALE
                unknown_dialogue_count += 1

        result.append(NarrationChunk(chunk, start, end, role))

    return result


def timing_ranges(text: str, maximum: int = 52, minimum: int = 10) -> list[tuple[int, int]]:
    chunks = split_narration_text(text, maximum=maximum, minimum=minimum)
    result: list[tuple[int, int]] = []
    offset = 0
    for chunk in chunks:
        end = offset + len(chunk)
        result.append((offset, end))
        offset = end
    return result


def _dialogue_ranges(text: str) -> list[tuple[int, int]]:
    pairs = {"“": "”", "‘": "’", '"': '"'}
    ranges: list[tuple[int, int]] = []
    opening: str | None = None
    start = 0
    for index, character in enumerate(text):
        if opening is None and character in pairs:
            opening = character
            start = index
        elif opening is not None and character == pairs[opening]:
            ranges.append((start, index + 1))
            opening = None
    if opening is not None:
        ranges.append((start, len(text)))
    return ranges


def _overlaps_dialogue(start: int, end: int, ranges: list[tuple[int, int]]) -> bool:
    return any(max(start, left) < min(end, right) for left, right in ranges)


def _source_spans(text: str, dialogue_ranges: list[tuple[int, int]]) -> list[tuple[int, int, bool]]:
    result: list[tuple[int, int, bool]] = []
    cursor = 0
    for start, end in dialogue_ranges:
        if cursor < start:
            result.append((cursor, start, False))
        result.append((start, end, True))
        cursor = end
    if cursor < len(text):
        result.append((cursor, len(text), False))
    return result


def _speaker_name(context: str, anchor: int) -> str | None:
    before_matches = list(re.finditer(
        rf"([\u4e00-\u9fff]{{1,6}}?)(?:{SPEECH_VERBS})[，,:：\s]*[“‘\"]",
        context,
    ))
    if before_matches:
        closest = min(before_matches, key=lambda match: abs(match.end() - 1 - anchor))
        return closest.group(1)[-4:]
    after = re.search(
        rf"[”’\"][，,。！？!?\s]*([\u4e00-\u9fff]{{1,6}}?)(?:{SPEECH_VERBS})",
        context,
    )
    if after:
        return after.group(1)[-4:]
    pronoun = re.search(r"(?:^|[^\u4e00-\u9fff])(她|他)(?:[^\u4e00-\u9fff]|$)", context)
    return pronoun.group(1) if pronoun else None


def _speaker_gender(speaker: str | None, context: str) -> str | None:
    if speaker == "她" or any(marker in context for marker in ("女孩", "女人", "姑娘", "小姐", "母亲")):
        return ROLE_FEMALE
    if speaker == "他" or any(marker in context for marker in ("男孩", "男人", "少年", "先生", "父亲")):
        return ROLE_MALE
    return None


@dataclass(frozen=True)
class JobRequest:
    book_id: str
    book_title: str
    author: str
    chapter_id: str
    chapter_index: int
    chapter_title: str
    text: str
    text_sha256: str
    voice: str
    speed: float

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "JobRequest":
        if payload.get("protocol_version") != PROTOCOL_VERSION:
            raise ProtocolError("客户端与生成器协议版本不一致")

        text = normalize_narration_text(require_string(payload, "text", MAX_CHAPTER_CHARACTERS))
        supplied_hash = require_string(payload, "text_sha256", 64).lower()
        actual_hash = sha256(text.encode("utf-8")).hexdigest()
        if supplied_hash != actual_hash:
            raise ProtocolError("正文校验失败，请重新提交本章")

        chapter_index = payload.get("chapter_index")
        if not isinstance(chapter_index, int) or chapter_index < 0:
            raise ProtocolError("章节序号无效")
        speed = payload.get("speed", 1.0)
        if not isinstance(speed, (int, float)) or not 0.5 <= float(speed) <= 2.0:
            raise ProtocolError("生成语速必须在 0.5 到 2.0 之间")

        return cls(
            book_id=require_string(payload, "book_id", 512),
            book_title=require_string(payload, "book_title", 256),
            author=str(payload.get("author", "")).strip()[:128],
            chapter_id=require_string(payload, "chapter_id", 128),
            chapter_index=chapter_index,
            chapter_title=require_string(payload, "chapter_title", 256),
            text=text,
            text_sha256=actual_hash,
            voice=str(payload.get("voice", "default")).strip()[:128] or "default",
            speed=float(speed),
        )

    @property
    def stable_job_id(self) -> str:
        fingerprint = "\n".join(
            [self.book_id, self.chapter_id, self.text_sha256, self.voice, f"{self.speed:.2f}"]
        )
        return sha256(fingerprint.encode("utf-8")).hexdigest()[:32]

    def public_dict(self) -> dict[str, Any]:
        value = asdict(self)
        value.pop("text")
        return value
