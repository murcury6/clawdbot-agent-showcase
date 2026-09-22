@echo off
setlocal

for %%I in ("%~dp0..") do set "BASE=%%~fI"
set "ASSUME_YES="
if /I "%~1"=="/Y" set "ASSUME_YES=1"
title Portable Clawd Fresh Start
cls

if not defined ASSUME_YES (
  echo This will stop the bot and clear its runtime data.
  echo.
  echo It keeps:
  echo   - keys and secrets
  echo   - Telegram setup
  echo   - model/config settings
  echo   - workspace rules and personality files
  echo.
  echo It clears:
  echo   - chat sessions and queue state
  echo   - bot memory and scratch notes
  echo   - unlock session state
  echo   - old logs and failed deliveries
  echo.
  choice /C YN /N /M "Continue with fresh start? [Y/N]: "
  if errorlevel 2 exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\reset-portable-data.ps1" -BasePath "%BASE%"
if errorlevel 1 (
  echo.
  echo Fresh start failed.
  pause
  exit /b 1
)

echo.
echo Fresh start complete.
echo The bot is stopped and the watchdog is paused.
echo Run "%BASE%\scripts\portable-start.bat" when you want to start it again.
if not defined ASSUME_YES pause
exit /b 0
