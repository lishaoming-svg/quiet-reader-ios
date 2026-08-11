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

$environmentExists = conda env list --json `
    | ConvertFrom-Json `
    | Select-Object -ExpandProperty envs `
    | Where-Object { (Split-Path -Leaf $_) -eq $EnvironmentName }
if (-not $environmentExists) {
    conda create -n $EnvironmentName -y python=3.10
}

$requirements = Join-Path $cosyvoice 'requirements.txt'
conda run -n $EnvironmentName python -m pip install -r $requirements `
    -i https://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com
conda run -n $EnvironmentName python -m pip install modelscope

$modelDirectory = Join-Path $cosyvoice 'pretrained_models\Fun-CosyVoice3-0.5B'
$downloadScript = Join-Path $root 'download_cosyvoice.py'
conda run --no-capture-output -n $EnvironmentName python $downloadScript $modelDirectory

Write-Host 'CosyVoice 3 安装完成。启动时需要提供参考音频和对应文字。'
