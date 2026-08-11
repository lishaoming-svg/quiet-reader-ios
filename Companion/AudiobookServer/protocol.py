from __future__ import annotations

from dataclasses import asdict, dataclass
from hashlib import sha256
from typing import Any


PROTOCOL_VERSION = 1
MAX_CHAPTER_CHARACTERS = 100_000
SENTENCE_ENDINGS = frozenset("。！？!?；;\n")
SOFT_ENDINGS = frozenset("，,、：:")


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

