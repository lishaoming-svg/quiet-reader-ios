from __future__ import annotations

import math
import os
import subprocess
import sys
import wave
from abc import ABC, abstractmethod
from pathlib import Path


class TTSBackend(ABC):
    engine_id = "unknown"
    display_name = "未知引擎"

    @abstractmethod
    def synthesize(self, text: str, output_path: Path, voice: str, speed: float) -> None:
        raise NotImplementedError

    def voices(self) -> list[dict[str, str]]:
        return [{"id": "default", "name": "默认音色"}]


class WindowsSAPIBackend(TTSBackend):
    engine_id = "windows-sapi"
    display_name = "Windows 中文语音"

    def __init__(self, script_path: Path) -> None:
        self.script_path = script_path

    def synthesize(self, text: str, output_path: Path, voice: str, speed: float) -> None:
        text_path = output_path.with_suffix(".txt")
        text_path.write_text(text, encoding="utf-8")
        subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(self.script_path),
                str(text_path),
                str(output_path),
                voice,
                f"{speed:.2f}",
            ],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )

    def voices(self) -> list[dict[str, str]]:
        return [{"id": "Microsoft Huihui Desktop", "name": "微软慧慧"}]


class CosyVoiceBackend(TTSBackend):
    engine_id = "cosyvoice3"
    display_name = "CosyVoice 3"

    def __init__(self, home: Path, model_dir: Path, prompt_audio: Path, prompt_text: str) -> None:
        if not home.is_dir():
            raise RuntimeError(f"找不到 CosyVoice 目录：{home}")
        if not model_dir.is_dir():
            raise RuntimeError(f"找不到 CosyVoice 模型：{model_dir}")
        if not prompt_audio.is_file() or not prompt_text.strip():
            raise RuntimeError("CosyVoice 需要参考音频及其准确文字")

        sys.path.insert(0, str(home))
        sys.path.insert(0, str(home / "third_party" / "Matcha-TTS"))
        from cosyvoice.cli.cosyvoice import AutoModel

        self._torchaudio = __import__("torchaudio")
        self.model = AutoModel(model_dir=str(model_dir))
        self.prompt_audio = prompt_audio
        bundled_narrator = home / "asset" / "cross_lingual_prompt.wav"
        self.narrator_audio = bundled_narrator if bundled_narrator.is_file() else prompt_audio
        cleaned_prompt = prompt_text.strip()
        if "<|endofprompt|>" not in cleaned_prompt:
            cleaned_prompt = f"You are a helpful assistant.<|endofprompt|>{cleaned_prompt}"
        self.prompt_text = cleaned_prompt

    def synthesize(self, text: str, output_path: Path, voice: str, speed: float) -> None:
        if voice in {"narrator", "role-narrator"}:
            prepared = text
            if "<|endofprompt|>" not in prepared:
                prepared = f"You are a helpful assistant.<|endofprompt|>{prepared}"
            outputs = list(
                self.model.inference_cross_lingual(
                    prepared,
                    str(self.narrator_audio),
                    stream=False,
                    speed=speed,
                )
            )
        elif voice.startswith("role-"):
            instructions = {
                "role-protagonist": "请用清晰、有情绪起伏的青年主角语气朗读。",
                "role-male": "请用沉稳自然的成年男性角色语气朗读。",
                "role-female": "请用自然清晰的女性角色语气朗读。",
            }
            instruction = (
                "You are a helpful assistant. "
                f"{instructions.get(voice, '请用自然的有声书角色语气朗读。')}"
                "<|endofprompt|>"
            )
            role_audio = self.narrator_audio if voice == "role-male" else self.prompt_audio
            outputs = list(
                self.model.inference_instruct2(
                    text,
                    instruction,
                    str(role_audio),
                    stream=False,
                    speed=speed,
                )
            )
        else:
            outputs = list(
                self.model.inference_zero_shot(
                    text,
                    self.prompt_text,
                    str(self.prompt_audio),
                    stream=False,
                    speed=speed,
                )
            )
        if not outputs:
            raise RuntimeError("CosyVoice 没有返回音频")
        tensors = [item["tts_speech"] for item in outputs]
        torch = __import__("torch")
        audio = torch.cat(tensors, dim=1) if len(tensors) > 1 else tensors[0]
        self._torchaudio.save(
            str(output_path),
            audio.cpu(),
            self.model.sample_rate,
            encoding="PCM_S",
            bits_per_sample=16,
        )

    def voices(self) -> list[dict[str, str]]:
        return [
            {"id": "reference", "name": "自然女声"},
            {"id": "narrator", "name": "沉稳旁白"},
            {"id": "multi-role", "name": "多角色对话（旁白/主角/男/女）"},
        ]


class ToneTestBackend(TTSBackend):
    engine_id = "tone-test"
    display_name = "协议测试音"

    def synthesize(self, text: str, output_path: Path, voice: str, speed: float) -> None:
        sample_rate = 24_000
        duration = max(0.12, min(0.6, len(text) * 0.015))
        frames = int(sample_rate * duration)
        with wave.open(str(output_path), "wb") as target:
            target.setnchannels(1)
            target.setsampwidth(2)
            target.setframerate(sample_rate)
            payload = bytearray()
            for index in range(frames):
                value = int(5_000 * math.sin(2 * math.pi * 440 * index / sample_rate))
                payload.extend(value.to_bytes(2, "little", signed=True))
            target.writeframes(payload)


def create_backend(args, base_dir: Path) -> TTSBackend:
    if args.engine == "sapi":
        if os.name != "nt":
            raise RuntimeError("Windows 系统语音只能在 Windows 上运行")
        return WindowsSAPIBackend(base_dir / "sapi_synthesize.ps1")
    if args.engine == "cosyvoice":
        return CosyVoiceBackend(
            Path(args.cosyvoice_home),
            Path(args.cosyvoice_model),
            Path(args.prompt_audio),
            args.prompt_text,
        )
    if args.engine == "tone":
        return ToneTestBackend()
    raise RuntimeError(f"不支持的语音引擎：{args.engine}")
