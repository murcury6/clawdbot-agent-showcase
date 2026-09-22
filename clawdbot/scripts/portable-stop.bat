@echo off
setlocal

for %%I in ("%~dp0..") do set "BASE=%%~fI"
if not exist "%BASE%\run" mkdir "%BASE%\run"
type nul > "%BASE%\run\watchdog.pause"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\stop-stack.ps1" -BasePath "%BASE%"
exit /b 0
