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
    if ($LASTEXITCODE -ne 0) {
        throw "CosyVoice 源码下载失败，退出码：$LASTEXITCODE"
    }
}

$environmentExists = conda env list --json `
    | ConvertFrom-Json `
    | Select-Object -ExpandProperty envs `
    | Where-Object { (Split-Path -Leaf $_) -eq $EnvironmentName }
if (-not $environmentExists) {
    conda create -n $EnvironmentName -y python=3.10
    if ($LASTEXITCODE -ne 0) {
        throw "Conda 环境创建失败，退出码：$LASTEXITCODE"
    }
}

$requirements = Join-Path $cosyvoice 'requirements.txt'
conda run --no-capture-output -n $EnvironmentName python -m pip install 'setuptools<81'
if ($LASTEXITCODE -ne 0) {
    throw "Setuptools 兼容版本安装失败，退出码：$LASTEXITCODE"
}
conda run -n $EnvironmentName python -m pip install -r $requirements `
    --no-build-isolation `
    -i https://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com
if ($LASTEXITCODE -ne 0) {
    throw "CosyVoice Python 依赖安装失败，退出码：$LASTEXITCODE"
}
$serverRequirements = Join-Path $root 'requirements.txt'
conda run --no-capture-output -n $EnvironmentName python -m pip install -r $serverRequirements
if ($LASTEXITCODE -ne 0) {
    throw "听书服务依赖安装失败，退出码：$LASTEXITCODE"
}

$modelDirectory = Join-Path $cosyvoice 'pretrained_models\Fun-CosyVoice3-0.5B'
$downloadScript = Join-Path $root 'download_cosyvoice.py'
$requiredModelFiles = @(
    'cosyvoice3.yaml',
    'llm.pt',
    'flow.pt',
    'hift.pt',
    'campplus.onnx',
    'speech_tokenizer_v3.onnx',
    'CosyVoice-BlankEN\model.safetensors'
)
$missingModelFiles = @($requiredModelFiles | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $modelDirectory $_) -PathType Leaf)
})
if ($missingModelFiles.Count -gt 0) {
    conda run --no-capture-output -n $EnvironmentName python $downloadScript $modelDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "CosyVoice 3 模型下载失败，退出码：$LASTEXITCODE"
    }
}

Push-Location $cosyvoice
try {
    conda run --no-capture-output -n $EnvironmentName python -c "import torch, torchaudio; from cosyvoice.cli.cosyvoice import AutoModel; print('CosyVoice 运行环境验证通过，CUDA=' + str(torch.cuda.is_available()))"
    if ($LASTEXITCODE -ne 0) {
        throw "CosyVoice 运行环境验证失败，退出码：$LASTEXITCODE"
    }
} finally {
    Pop-Location
}

Write-Host 'CosyVoice 3 安装完成。启动时需要提供参考音频和对应文字。'
