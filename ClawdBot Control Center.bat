@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0clawdbot\scripts\clawdbot-control-center.ps1" -BasePath "%~dp0clawdbot"
