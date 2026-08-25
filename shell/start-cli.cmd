@echo off
rem project-starter cmd shim: forwards to the PowerShell engine.
rem Target of the `start` doskey macro created by install-cmd.ps1.
setlocal
set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%..\entry.ps1" %*
endlocal
