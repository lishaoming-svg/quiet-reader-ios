param(
    [ValidateSet('sapi', 'cosyvoice', 'tone')][string]$Engine = 'sapi',
    [int]$Port = 8765,
    [string]$PromptAudio = $env:QUIETREADER_PROMPT_AUDIO,
    [string]$PromptText = $env:QUIETREADER_PROMPT_TEXT,
    [switch]$OpenBrowser,
    [switch]$ReuseExisting
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

function ConvertFrom-UTF8Base64([string]$Value) {
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

if ($ReuseExisting) {
    try {
        $localURL = "http://127.0.0.1:$Port/"
        $response = Invoke-WebRequest -UseBasicParsing -Uri $localURL -TimeoutSec 2
        $serviceMarker = ConvertFrom-UTF8Base64 '5aKo6ZiF5ZCs5Lmm55Sf5oiQ5Zmo'
        if ($response.Content.Contains($serviceMarker)) {
            if ($OpenBrowser) {
                Start-Process $localURL
            }
            Write-Host (ConvertFrom-UTF8Base64 '5aKo6ZiF5ZCs5Lmm5pyN5Yqh5bey57uP6L+Q6KGM77yM6YWN5a+56aG16Z2i5bey5omT5byA44CC')
            exit 0
        }
    } catch {
        # No compatible local service is running, so continue with startup.
    }
}

if ($Engine -eq 'cosyvoice') {
    if (-not $PromptAudio) {
        $PromptAudio = Join-Path $root '.runtime\CosyVoice\asset\zero_shot_prompt.wav'
    }
    if (-not $PromptText) {
        $PromptText = ConvertFrom-UTF8Base64 '5biM5pyb5L2g5Lul5ZCO6IO95aSf5YGa55qE5q+U5oiR6L+Y5aW95ZGm44CC'
    }
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    throw (ConvertFrom-UTF8Base64 '5pyq5om+5YiwIEZGbXBlZ++8jOivt+WFiOWuieijheW5tuWKoOWFpSBQQVRI44CC')
}

Write-Host (ConvertFrom-UTF8Base64 '5q2j5Zyo5ZCv5Yqo5aKo6ZiF5ZCs5Lmm5pyN5Yqh77yM6aaW5qyh5Yqg6L295qih5Z6L5Y+v6IO96ZyA6KaB5LiA5Lqb5pe26Ze044CC')

if ($Engine -eq 'cosyvoice') {
    if (-not $PromptAudio -or -not (Test-Path -LiteralPath $PromptAudio)) {
        throw (ConvertFrom-UTF8Base64 'Q29zeVZvaWNlIOmcgOimgSBQcm9tcHRBdWRpb++8jOivt+aMh+WumuS4gOauteWFt+acieS9v+eUqOadg+eahOWPguiAg+S6uuWjsOOAgg==')
    }
    if (-not $PromptText) {
        throw (ConvertFrom-UTF8Base64 'Q29zeVZvaWNlIOmcgOimgSBQcm9tcHRUZXh077yM5YaF5a655b+F6aG75LiO5Y+C6ICD5Lq65aOw6YCQ5a2X5LiA6Ie044CC')
    }
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    $env:QUIETREADER_PROMPT_AUDIO = (Resolve-Path -LiteralPath $PromptAudio).Path
    $env:QUIETREADER_PROMPT_TEXT = $PromptText
    $condaCommand = Get-Command conda -ErrorAction SilentlyContinue
    if ($condaCommand) {
        $condaPath = $condaCommand.Source
    } else {
        $fallbackConda = Join-Path $env:USERPROFILE 'miniconda3\Scripts\conda.exe'
        if (Test-Path -LiteralPath $fallbackConda) {
            $condaPath = $fallbackConda
        } else {
            throw (ConvertFrom-UTF8Base64 '5pyq5om+5YiwIENvbmRh77yM6K+35YWI6L+Q6KGMIGluc3RhbGwtY29zeXZvaWNlLnBzMSDlronoo4XlkKzkuabnjq/looPjgII=')
        }
    }
    $serverArguments = @(
        'run', '--no-capture-output', '-n', 'quietreader-cosyvoice',
        'python', 'server.py', '--engine', 'cosyvoice', '--port', $Port
    )
    if ($OpenBrowser) {
        $serverArguments += '--open-browser'
    }
    & $condaPath @serverArguments
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
} else {
    $serverArguments = @('server.py', '--engine', $Engine, '--port', $Port)
    if ($OpenBrowser) {
        $serverArguments += '--open-browser'
    }
    python @serverArguments
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
