from __future__ import annotations

import argparse
from pathlib import Path

from modelscope import snapshot_download


def main() -> None:
    parser = argparse.ArgumentParser(description="下载墨阅使用的 CosyVoice 3 模型")
    parser.add_argument("target", type=Path)
    args = parser.parse_args()
    args.target.mkdir(parents=True, exist_ok=True)
    snapshot_download(
        "FunAudioLLM/Fun-CosyVoice3-0.5B-2512",
        local_dir=str(args.target.resolve()),
    )


if __name__ == "__main__":
    main()
