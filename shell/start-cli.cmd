@echo off
rem project-starter cmd shim: forwards to the PowerShell engine.
rem Target of the `start` doskey macro created by install-cmd.ps1.
rem Resolves PowerShell by absolute existence check - immune to broken PATH.
setlocal
set "SCRIPT_DIR=%~dp0"
set "PSEXE=C:\Program Files\PowerShell\7\pwsh.exe"
if not exist "%PSEXE%" set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%..\entry.ps1" %*
endlocal
