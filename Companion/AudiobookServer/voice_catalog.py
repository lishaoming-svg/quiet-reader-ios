from __future__ import annotations

import json
from functools import lru_cache
from hashlib import sha256
from pathlib import Path
from typing import Any


CATALOG_PATH = Path(__file__).with_name("voice_catalog.json")
VALID_GROUPS = {"narrator", "male", "female"}
VALID_ENGINES = {
    "gpt-sovits-v2-proplus",
}
MULTI_ROLE_OPTION = {
    "id": "multi-role",
    "name": "多角色自动分配",
    "group": "automatic",
    "description": "根据人物名称和性别稳定分配旁白、男声与女声。",
    "role_tags": ["整书推荐", "自动角色", "逐句伴读"],
}


class VoiceCatalogError(ValueError):
    pass


def load_voice_catalog(
    path: Path | None = None,
    *,
    verify_audio: bool = True,
) -> dict[str, Any]:
    catalog_path = (path or CATALOG_PATH).resolve()
    return _load_voice_catalog_cached(str(catalog_path), verify_audio)


@lru_cache(maxsize=4)
def _load_voice_catalog_cached(
    catalog_path_value: str,
    verify_audio: bool,
) -> dict[str, Any]:
    catalog_path = Path(catalog_path_value)
    with catalog_path.open("r", encoding="utf-8") as source:
        catalog = json.load(source)
    _validate_catalog(catalog, catalog_path.parent, verify_audio=verify_audio)
    return catalog


def approved_voices(group: str | None = None) -> list[dict[str, Any]]:
    catalog = load_voice_catalog()
    voices = catalog["voices"]
    if group is None:
        return voices
    if group not in VALID_GROUPS:
        raise VoiceCatalogError(f"未知音色分组：{group}")
    return [voice for voice in voices if voice["group"] == group]


def public_voice_options() -> list[dict[str, Any]]:
    catalog = load_voice_catalog()
    result = [dict(MULTI_ROLE_OPTION)]
    for voice in catalog["voices"]:
        result.append(
            {
                "id": voice["id"],
                "name": voice["name"],
                "group": voice["group"],
                "description": "、".join(voice["role_tags"]),
                "role_tags": voice["role_tags"],
            }
        )
    return result


def default_voice_assignment() -> dict[str, str]:
    return dict(load_voice_catalog()["default_assignment"])


def voice_profile(identifier: str) -> dict[str, Any]:
    for voice in load_voice_catalog()["voices"]:
        if voice["id"] == identifier:
            return voice
    raise VoiceCatalogError(f"未知音色：{identifier}")


def stable_character_voice(
    speaker: str | None,
    group: str,
    role: str,
) -> str:
    catalog = load_voice_catalog()
    assignments = catalog["default_assignment"]
    if group == "narrator":
        return assignments["narrator"]
    if not speaker:
        if role == "protagonist":
            key = "protagonist_female" if group == "female" else "protagonist_male"
        else:
            key = "female_supporting" if group == "female" else "male_supporting"
        return assignments[key]

    candidates = [voice["id"] for voice in catalog["voices"] if voice["group"] == group]
    digest = sha256(speaker.encode("utf-8")).digest()
    return candidates[int.from_bytes(digest[:4], "big") % len(candidates)]


def resolve_audio_path(relative_path: str, base_dir: Path | None = None) -> Path:
    root = (base_dir or CATALOG_PATH.parent).resolve()
    resolved = (root / relative_path).resolve()
    if root not in resolved.parents:
        raise VoiceCatalogError(f"音频路径越出声库目录：{relative_path}")
    return resolved


def _validate_catalog(
    catalog: dict[str, Any],
    base_dir: Path,
    *,
    verify_audio: bool,
) -> None:
    if catalog.get("schema_version") != 1:
        raise VoiceCatalogError("声库配置版本无效")

    voices = catalog.get("voices")
    if not isinstance(voices, list) or not voices:
        raise VoiceCatalogError("声库没有正式音色")

    identifiers: set[str] = set()
    for voice in voices:
        identifier = voice.get("id", "")
        if not identifier or identifier in identifiers:
            raise VoiceCatalogError(f"音色标识为空或重复：{identifier}")
        identifiers.add(identifier)

        if voice.get("group") not in VALID_GROUPS:
            raise VoiceCatalogError(f"音色分组无效：{identifier}")
        engine = voice.get("engine", {})
        if engine.get("id") not in VALID_ENGINES:
            raise VoiceCatalogError(f"音色引擎无效：{identifier}")
        if engine.get("mode") == "voice-clone":
            if not engine.get("reference_text", "").strip():
                raise VoiceCatalogError(f"克隆音色缺少参考文字：{identifier}")
            _check_audio(engine.get("reference_audio"), base_dir, identifier, verify_audio)
        elif engine.get("mode") == "preset":
            if not engine.get("speaker", "").strip():
                raise VoiceCatalogError(f"预设音色缺少 speaker：{identifier}")
        else:
            raise VoiceCatalogError(f"音色生成模式无效：{identifier}")
        _check_audio(voice.get("preview_audio"), base_dir, identifier, verify_audio)

    assignments = catalog.get("default_assignment", {})
    missing = set(assignments.values()) - identifiers
    if missing:
        raise VoiceCatalogError(f"默认角色引用未知音色：{sorted(missing)}")


def _check_audio(
    relative_path: Any,
    base_dir: Path,
    identifier: str,
    verify_audio: bool,
) -> None:
    if not isinstance(relative_path, str) or not relative_path.strip():
        raise VoiceCatalogError(f"音色缺少音频路径：{identifier}")
    if verify_audio and not resolve_audio_path(relative_path, base_dir).is_file():
        raise VoiceCatalogError(f"音色文件不存在：{identifier} -> {relative_path}")
