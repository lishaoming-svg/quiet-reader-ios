param(
    [ValidateSet('sapi', 'cosyvoice', 'tone')][string]$Engine = 'sapi',
    [int]$Port = 8765,
    [string]$PromptAudio = $env:QUIETREADER_PROMPT_AUDIO,
    [string]$PromptText = $env:QUIETREADER_PROMPT_TEXT
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    throw '未找到 FFmpeg，请先安装并加入 PATH。'
}

if ($Engine -eq 'cosyvoice') {
    if (-not $PromptAudio -or -not (Test-Path -LiteralPath $PromptAudio)) {
        throw 'CosyVoice 需要 PromptAudio，请指定一段具有使用权的参考人声。'
    }
    if (-not $PromptText) {
        throw 'CosyVoice 需要 PromptText，内容必须与参考人声逐字一致。'
    }
    & conda run --no-capture-output -n quietreader-cosyvoice python server.py `
        --engine cosyvoice --port $Port --prompt-audio $PromptAudio --prompt-text $PromptText
} else {
    python server.py --engine $Engine --port $Port
}

