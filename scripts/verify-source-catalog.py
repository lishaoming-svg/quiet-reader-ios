#!/usr/bin/env python3
"""Verify generated built-in source catalog consistency."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import zlib
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("catalog", type=Path)
    return parser.parse_args()


def load_zlib_json(path: Path):
    return json.loads(zlib.decompress(path.read_bytes(), wbits=-zlib.MAX_WBITS).decode("utf-8"))


def main() -> int:
    root = parse_args().catalog.resolve()
    manifest = json.loads((root / "source-catalog-manifest.json").read_text(encoding="utf-8"))
    assert manifest["compression"] == "deflate-raw-rfc1951"
    index = load_zlib_json(root / "source-catalog-index.zlib")
    assert manifest["uniqueSourceCount"] == index["sourceCount"] == len(index["entries"])
    assert index["shardCount"] == len(manifest["shards"]) == 64
    assert index["sourceCount"] >= 25_000
    assert manifest["statusCounts"]["compatible"] >= 6_000

    entry_ids = {entry["id"] for entry in index["entries"]}
    assert len(entry_ids) == len(index["entries"])
    entry_shards = {entry["id"]: entry["shard"] for entry in index["entries"]}
    definition_ids: set[str] = set()
    definition_count = 0
    for number, shard_info in enumerate(manifest["shards"]):
        path = root / shard_info["file"]
        compressed = path.read_bytes()
        assert hashlib.sha256(compressed).hexdigest() == shard_info["sha256"]
        definitions = json.loads(
            zlib.decompress(compressed, wbits=-zlib.MAX_WBITS).decode("utf-8")
        )
        assert len(definitions) == shard_info["sourceCount"]
        shard_ids = {item["sourceId"] for item in definitions}
        assert all(entry_shards[source_id] == number for source_id in shard_ids)
        definition_count += len(definitions)
        definition_ids.update(shard_ids)

    assert definition_count == index["sourceCount"]
    assert definition_ids == entry_ids
    print(
        f"CATALOG_OK sources={definition_count} "
        f"compatible={manifest['statusCounts']['compatible']} shards={index['shardCount']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
