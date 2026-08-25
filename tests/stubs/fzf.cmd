@echo off
rem Context-aware fzf stub: prefers "theta*" lines (project picker), else first line.
rem Resolves PowerShell by ABSOLUTE path - immune to broken inherited PATH.
setlocal
set "PSEXE=C:\Program Files\PowerShell\7\pwsh.exe"
if not exist "%PSEXE%" set "PSEXE=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0_fzf-stub.ps1"
endlocal
