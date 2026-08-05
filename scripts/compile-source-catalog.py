#!/usr/bin/env python3
"""Compile large Legado source collections into a sharded built-in catalog."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.parse
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator


SHARD_COUNT = 64
MAX_ARCHIVE_ENTRY_BYTES = 64 * 1024 * 1024
RULE_FIELDS = {
    "ruleSearch": [
        "bookList", "name", "author", "intro", "kind", "lastChapter",
        "updateTime", "bookUrl", "coverUrl", "wordCount",
    ],
    "ruleBookInfo": [
        "init", "name", "author", "intro", "kind", "lastChapter",
        "updateTime", "coverUrl", "tocUrl", "wordCount",
    ],
    "ruleToc": [
        "chapterList", "chapterName", "chapterUrl", "isVolume", "isVip",
        "updateTime", "nextTocUrl",
    ],
    "ruleContent": [
        "content", "title", "nextContentUrl", "sourceRegex", "replaceRegex",
    ],
}


@dataclass
class Candidate:
    source: dict[str, Any]
    origin: str
    sequence: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path, help="Directory containing source collections")
    parser.add_argument("output", type=Path, help="Generated resource directory")
    return parser.parse_args()


def decode_text(data: bytes) -> str:
    for encoding in ("utf-8-sig", "utf-8", "gb18030"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    raise ValueError("unsupported text encoding")


def sanitized_json_text(text: str) -> str:
    return re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", text)


def decode_many(text: str) -> list[Any]:
    decoder = json.JSONDecoder()
    values: list[Any] = []
    index = 0
    while index < len(text):
        while index < len(text) and (text[index].isspace() or text[index] in ",;"):
            index += 1
        if index >= len(text):
            break
        value, end = decoder.raw_decode(text, index)
        values.append(value)
        index = end
    return values


def balanced_objects(text: str) -> Iterator[str]:
    depth = 0
    start: int | None = None
    in_string = False
    escaped = False
    for index, character in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character == "{":
            if depth == 0:
                start = index
            depth += 1
        elif character == "}" and depth:
            depth -= 1
            if depth == 0 and start is not None:
                yield text[start:index + 1]
                start = None


def parse_documents(data: bytes) -> tuple[list[Any], str | None]:
    text = sanitized_json_text(decode_text(data)).strip()
    if not text:
        return [], None
    if "bookSourceUrl" not in text and not text.startswith(("[", "{")):
        return [], None
    first_error_message = "unknown JSON error"
    try:
        return [json.loads(text)], None
    except json.JSONDecodeError as error:
        first_error_message = str(error)

    typographic_json = text.translate(str.maketrans({"“": '"', "”": '"', "：": ":", "，": ","}))
    if typographic_json != text:
        try:
            return [json.loads(typographic_json)], "normalized full-width JSON punctuation"
        except json.JSONDecodeError:
            pass
    try:
        values = decode_many(text)
        if values:
            return values, "decoded concatenated JSON values"
    except json.JSONDecodeError:
        pass

    recovered: list[Any] = []
    for raw_object in balanced_objects(text):
        if "bookSourceUrl" not in raw_object or "bookSourceName" not in raw_object:
            continue
        try:
            recovered.append(json.loads(raw_object))
        except json.JSONDecodeError:
            continue
    if recovered:
        return recovered, f"recovered {len(recovered)} balanced source objects"
    return [], f"unrecoverable JSON: {first_error_message}"


def input_payloads(root: Path) -> Iterator[tuple[str, bytes]]:
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        suffix = path.suffix.lower()
        relative = str(path.relative_to(root))
        if suffix in {".json", ".txt"}:
            yield relative, path.read_bytes()
        elif suffix == ".zip":
            try:
                with zipfile.ZipFile(path) as archive:
                    for info in archive.infolist():
                        if info.is_dir() or Path(info.filename).suffix.lower() not in {".json", ".txt"}:
                            continue
                        if info.file_size > MAX_ARCHIVE_ENTRY_BYTES:
                            continue
                        yield f"{relative}!{info.filename}", archive.read(info)
            except zipfile.BadZipFile:
                continue


def source_objects(value: Any) -> Iterator[dict[str, Any]]:
    if isinstance(value, list):
        for item in value:
            yield from source_objects(item)
    elif isinstance(value, dict):
        if "bookSourceUrl" in value and "bookSourceName" in value:
            yield value
        elif isinstance(value.get("sources"), list):
            yield from source_objects(value["sources"])


def string_value(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        return value.strip("\ufeff\x00\x16 \t\r\n")
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return str(value)


def bool_value(value: Any, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    return str(value).strip().lower() in {"1", "true", "yes", "是", "启用"} if value is not None else default


def int_value(value: Any, default: int = 0) -> int:
    if isinstance(value, bool):
        return int(value)
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def source_type(value: Any) -> int:
    if isinstance(value, (int, float)):
        return int(value)
    normalized = str(value or "").strip().lower()
    mapping = {"": 0, "text": 0, "小说": 0, "audio": 1, "听书": 1, "漫画": 2, "video": 3, "视频": 3}
    return mapping.get(normalized, int_value(value, 0))


def normalized_rule(value: Any, allowed_fields: list[str]) -> dict[str, str] | None:
    if isinstance(value, str):
        try:
            decoded = json.loads(value)
            value = decoded if isinstance(decoded, dict) else None
        except json.JSONDecodeError:
            value = None
    if not isinstance(value, dict):
        return None
    result: dict[str, str] = {}
    for key in allowed_fields:
        normalized = string_value(value.get(key))
        if normalized:
            result[key] = normalized
    return result or None


def stable_source_id(url: str, name: str) -> str:
    digest = hashlib.sha256(f"{url}\n{name}".encode("utf-8")).hexdigest()[:24]
    return f"archive.{digest}"


def normalize_source(source: dict[str, Any]) -> tuple[dict[str, Any] | None, list[str]]:
    name = string_value(source.get("bookSourceName")) or ""
    url = (string_value(source.get("bookSourceUrl")) or "").rstrip("/")
    if not name or not url:
        return None, ["missingIdentity"]

    result: dict[str, Any] = {
        "sourceId": stable_source_id(url, name),
        "bookSourceUrl": url,
        "bookSourceName": name,
        "bookSourceGroup": string_value(source.get("bookSourceGroup")) or "全网合集",
        "bookSourceType": source_type(source.get("bookSourceType")),
        "enabled": False,
        "enabledExplore": bool_value(source.get("enabledExplore")),
        "lastUpdateTime": int_value(source.get("lastUpdateTime")),
    }
    for key in ("header", "loginUrl", "searchUrl", "exploreUrl"):
        value = string_value(source.get(key))
        if value:
            result[key] = value
    for key, allowed_fields in RULE_FIELDS.items():
        rule = normalized_rule(source.get(key), allowed_fields)
        if rule:
            result[key] = rule

    raw = json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")).lower()
    issues: list[str] = []
    try:
        parsed_url = urllib.parse.urlparse(url)
        valid_url = parsed_url.scheme in {"http", "https"} and bool(parsed_url.netloc)
    except ValueError:
        valid_url = False
    if not valid_url:
        issues.append("invalidUrl")
    if not result.get("searchUrl") or not result.get("ruleSearch"):
        issues.append("missingSearch")
    if result["bookSourceType"] != 0:
        issues.append("nonText")
    if any(marker in raw for marker in ("<js>", "@js:", "java.", "javascript:")):
        issues.append("javascript")
    if re.search(r'"(?:booklist|chapterlist|content|name)":"(?:@xpath:)?//', raw):
        issues.append("xpath")
    if re.search(r"method.{0,12}post", raw):
        issues.append("post")
    if result.get("loginUrl"):
        issues.append("login")
    return result, issues


def quality(candidate: Candidate) -> tuple[int, int, int]:
    source = candidate.source
    populated_rules = sum(bool(source.get(key)) for key in RULE_FIELDS)
    return int_value(source.get("lastUpdateTime")), populated_rules, candidate.sequence


def compressed_json(value: Any) -> bytes:
    raw = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return zlib.compress(raw, level=9)


def main() -> int:
    args = parse_args()
    root = args.input.resolve()
    output = args.output.resolve()
    if not root.is_dir():
        raise SystemExit(f"input directory does not exist: {root}")
    output.mkdir(parents=True, exist_ok=True)

    selected: dict[tuple[str, str], Candidate] = {}
    parse_notes: list[dict[str, str]] = []
    sequence = 0
    raw_source_count = 0
    for origin, payload in input_payloads(root):
        try:
            documents, note = parse_documents(payload)
        except Exception as error:
            parse_notes.append({"origin": origin, "note": str(error)[:240]})
            continue
        if note:
            parse_notes.append({"origin": origin, "note": note})
        for document in documents:
            for source in source_objects(document):
                raw_source_count += 1
                normalized, _ = normalize_source(source)
                if normalized is None:
                    continue
                sequence += 1
                key = (normalized["bookSourceUrl"], normalized["bookSourceName"])
                candidate = Candidate(normalized, origin, sequence)
                current = selected.get(key)
                if current is None or quality(candidate) >= quality(current):
                    selected[key] = candidate

    entries: list[dict[str, Any]] = []
    shards: list[list[dict[str, Any]]] = [[] for _ in range(SHARD_COUNT)]
    status_counts = {"compatible": 0, "partial": 0, "unsupported": 0}
    issue_counts: dict[str, int] = {}
    definition_bytes = 0

    for candidate in selected.values():
        source, issues = normalize_source(candidate.source)
        if source is None:
            continue
        blockers = {"invalidUrl", "missingSearch", "nonText"}
        partial = {"javascript", "xpath", "post"}
        status = "unsupported" if blockers.intersection(issues) else (
            "partial" if partial.intersection(issues) else "compatible"
        )
        status_counts[status] += 1
        for issue in set(issues):
            issue_counts[issue] = issue_counts.get(issue, 0) + 1
        digest = hashlib.sha256(source["sourceId"].encode("utf-8")).digest()
        shard = int.from_bytes(digest[:2], "big") % SHARD_COUNT
        shards[shard].append(source)
        try:
            host = urllib.parse.urlparse(source["bookSourceUrl"]).hostname or ""
        except ValueError:
            host = ""
        entries.append({
            "id": source["sourceId"],
            "name": source["bookSourceName"],
            "group": source["bookSourceGroup"],
            "url": source["bookSourceUrl"],
            "host": host,
            "sourceType": source["bookSourceType"],
            "status": status,
            "issues": sorted(set(issues)),
            "shard": shard,
            "lastUpdateTime": source["lastUpdateTime"],
            "origin": candidate.origin,
        })
        definition_bytes += len(json.dumps(source, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))

    entries.sort(key=lambda item: (item["name"].casefold(), item["url"]))
    for shard in shards:
        shard.sort(key=lambda item: item["sourceId"])

    index = {"version": 1, "sourceCount": len(entries), "shardCount": SHARD_COUNT, "entries": entries}
    index_data = compressed_json(index)
    (output / "source-catalog-index.zlib").write_bytes(index_data)

    shard_manifest: list[dict[str, Any]] = []
    for number, shard in enumerate(shards):
        data = compressed_json(shard)
        filename = f"source-catalog-{number:02d}.zlib"
        (output / filename).write_bytes(data)
        shard_manifest.append({
            "file": filename,
            "sourceCount": len(shard),
            "compressedBytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        })

    manifest = {
        "version": 1,
        "input": root.name,
        "rawSourceCount": raw_source_count,
        "uniqueSourceCount": len(entries),
        "statusCounts": status_counts,
        "issueCounts": dict(sorted(issue_counts.items())),
        "uncompressedDefinitionBytes": definition_bytes,
        "indexCompressedBytes": len(index_data),
        "parseNotes": parse_notes,
        "shards": shard_manifest,
    }
    (output / "source-catalog-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
