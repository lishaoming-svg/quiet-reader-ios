@echo off
setlocal
cd /d "%~dp0"
title QuietReader Audiobook Server

set "browserArgument=-OpenBrowser"
if defined QUIETREADER_NO_BROWSER set "browserArgument="

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" -Engine cosyvoice -ReuseExisting %browserArgument%
set "exitCode=%errorlevel%"

if not "%exitCode%"=="0" (
    echo.
    echo Startup failed with exit code %exitCode%.
    echo Review the error above, then press any key to close this window.
    pause >nul
)

exit /b %exitCode%
