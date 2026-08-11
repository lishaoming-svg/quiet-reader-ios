param(
    [string]$EnvironmentName = 'quietreader-cosyvoice'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$runtime = Join-Path $root '.runtime'
$cosyvoice = Join-Path $runtime 'CosyVoice'
New-Item -ItemType Directory -Force -Path $runtime | Out-Null

if (-not (Get-Command conda -ErrorAction SilentlyContinue)) {
    throw '未找到 Conda。请先安装 Miniconda。'
}
if (-not (Test-Path -LiteralPath $cosyvoice)) {
    git clone --recursive https://github.com/QwenAudio/CosyVoice.git $cosyvoice
}

conda create -n $EnvironmentName -y python=3.10
conda run -n $EnvironmentName python -m pip install -r (Join-Path $cosyvoice 'requirements.txt') `
    -i https://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com
conda run -n $EnvironmentName python -m pip install modelscope

$downloadScript = Join-Path $runtime 'download_cosyvoice.py'
@'
from modelscope import snapshot_download
from pathlib import Path

target = Path(__file__).resolve().parent / 'CosyVoice' / 'pretrained_models' / 'Fun-CosyVoice3-0.5B'
snapshot_download('FunAudioLLM/Fun-CosyVoice3-0.5B-2512', local_dir=str(target))
'@ | Set-Content -LiteralPath $downloadScript -Encoding UTF8
conda run --no-capture-output -n $EnvironmentName python $downloadScript

Write-Host 'CosyVoice 3 安装完成。启动时需要提供参考音频和对应文字。'

