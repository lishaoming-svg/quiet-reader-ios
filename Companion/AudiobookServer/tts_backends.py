from __future__ import annotations

import math
import os
import subprocess
import sys
import threading
import wave
from abc import ABC, abstractmethod
from pathlib import Path

from voice_catalog import (
    default_voice_assignment,
    public_voice_options,
    resolve_audio_path,
    voice_profile,
)


def normalize_gpt_sovits_audio(audio, sample_rate: int, target_sample_rate: int = 32_000):
    numpy = __import__("numpy")
    source = numpy.asarray(audio).squeeze()
    if numpy.issubdtype(source.dtype, numpy.integer):
        limits = numpy.iinfo(source.dtype)
        scale = float(max(abs(limits.min), limits.max))
        normalized = source.astype(numpy.float32) / scale
    else:
        normalized = source.astype(numpy.float32)
    if normalized.ndim == 2:
        channel_axis = 0 if normalized.shape[0] <= normalized.shape[1] else 1
        normalized = normalized.mean(axis=channel_axis)
    if normalized.ndim != 1 or normalized.size == 0:
        raise RuntimeError("GPT-SoVITS 返回了无效的音频形状")
    if sample_rate != target_sample_rate:
        target_length = max(1, round(normalized.size * target_sample_rate / sample_rate))
        normalized = numpy.interp(
            numpy.linspace(0, normalized.size - 1, target_length),
            numpy.arange(normalized.size),
            normalized,
        ).astype(numpy.float32)
    return numpy.clip(normalized, -1.0, 1.0)


class TTSBackend(ABC):
    engine_id = "unknown"
    display_name = "未知引擎"

    @abstractmethod
    def synthesize(self, text: str, output_path: Path, voice: str, speed: float) -> None:
        raise NotImplementedError

    def voices(self) -> list[dict[str, str]]:
        return [{"id": "default", "name": "默认音色"}]

    def voice_assignment(self) -> dict[str, str] | None:
        return None


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


class GPTSoVITSBackend(TTSBackend):
    engine_id = "gpt-sovits-v2-proplus"
    display_name = "GPT-SoVITS v2 ProPlus 多角色声库"

    def __init__(self, home: Path) -> None:
        if not home.is_dir():
            raise RuntimeError(f"找不到 GPT-SoVITS 目录：{home}")
        package_dir = home / "GPT_SoVITS"
        if not package_dir.is_dir():
            raise RuntimeError(f"GPT-SoVITS 程序目录不完整：{package_dir}")
        self.home = home.resolve()
        self._inference_lock = threading.Lock()

        sys.path.insert(0, str(home))
        sys.path.insert(0, str(package_dir))
        sys.path.insert(0, str(package_dir / "eres2net"))
        original_directory = Path.cwd()
        try:
            os.chdir(home)
            from TTS_infer_pack.TTS import TTS, TTS_Config

            pretrained = package_dir / "pretrained_models"
            config = {
                "custom": {
                    "device": "cuda",
                    "is_half": True,
                    "version": "v2ProPlus",
                    "t2s_weights_path": str(pretrained / "s1v3.ckpt"),
                    "vits_weights_path": str(pretrained / "v2Pro" / "s2Gv2ProPlus.pth"),
                    "bert_base_path": str(pretrained / "chinese-roberta-wwm-ext-large"),
                    "cnhuhbert_base_path": str(pretrained / "chinese-hubert-base"),
                }
            }
            self.model = TTS(TTS_Config(config))
            # GPT-SoVITS lazily imports G2PW during the first Chinese request.
            # Preload it while repository-relative model paths are available.
            from text import chinese2 as _chinese2  # noqa: F401
        finally:
            os.chdir(original_directory)
        self._soundfile = __import__("soundfile")

    def synthesize(self, text: str, output_path: Path, voice: str, speed: float) -> None:
        profile = voice_profile(voice)
        engine = profile["engine"]
        reference = resolve_audio_path(engine["reference_audio"])
        with self._inference_lock:
            result = next(
                self.model.run(
                    {
                        "text": text,
                        "text_lang": "all_zh",
                        "ref_audio_path": str(reference),
                        "prompt_text": engine["reference_text"],
                        "prompt_lang": "all_zh",
                        "text_split_method": "cut1",
                        "batch_size": 4,
                        "batch_threshold": 0.75,
                        "split_bucket": True,
                        "speed_factor": speed,
                        "fragment_interval": 0.18,
                        "seed": 20260812,
                        "parallel_infer": True,
                        "repetition_penalty": 1.35,
                    }
                )
            )
        sample_rate, audio = result
        # Voice references can make GPT-SoVITS return different channel shapes or
        # sample rates. Normalize every segment before chapter-level WAV merging.
        target_sample_rate = 32_000
        normalized = normalize_gpt_sovits_audio(audio, sample_rate, target_sample_rate)
        self._soundfile.write(
            output_path,
            normalized,
            target_sample_rate,
            format="WAV",
            subtype="PCM_16",
        )

    def voices(self) -> list[dict[str, str]]:
        return public_voice_options()

    def voice_assignment(self) -> dict[str, str] | None:
        return default_voice_assignment()


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
    if args.engine == "gpt-sovits":
        return GPTSoVITSBackend(Path(args.gpt_sovits_home))
    if args.engine == "tone":
        return ToneTestBackend()
    raise RuntimeError(f"不支持的语音引擎：{args.engine}")
