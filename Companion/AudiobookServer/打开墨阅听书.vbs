Option Explicit

Dim shell, scriptDirectory, command
Set shell = CreateObject("WScript.Shell")
scriptDirectory = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
command = "powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ _
    & scriptDirectory & "start.ps1"" -Engine gpt-sovits -ReuseExisting -OpenBrowser"
shell.Run command, 0, False
