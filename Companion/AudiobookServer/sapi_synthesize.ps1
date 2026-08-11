param(
    [Parameter(Mandatory = $true)][string]$TextPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string]$Voice = 'Microsoft Huihui Desktop',
    [double]$Speed = 1.0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$text = [System.IO.File]::ReadAllText($TextPath, [System.Text.Encoding]::UTF8)
$speaker = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
    if ($Voice -and $Voice -ne 'default') {
        $speaker.SelectVoice($Voice)
    }
    $speaker.Rate = [Math]::Max(-5, [Math]::Min(5, [int][Math]::Round(($Speed - 1.0) * 5)))
    $speaker.SetOutputToWaveFile($OutputPath)
    $speaker.Speak($text)
} finally {
    $speaker.Dispose()
}
