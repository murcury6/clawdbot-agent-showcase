@echo off
setlocal EnableDelayedExpansion

for %%I in ("%~dp0..") do set "BASE=%%~fI"
set "POST_REPLY_NUDGE=1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\sync-portable-keys.ps1" -BasePath "%BASE%" >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\require-unlock.ps1" -BasePath "%BASE%"
if errorlevel 1 (
  echo.
  echo Unlock failed.
  pause
  exit /b 1
)
set "PORTABLE_CLAWD_UNLOCK_OK=1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\start-stack.ps1" -BasePath "%BASE%" -SkipGateway >nul
if errorlevel 1 (
  echo.
  echo Start failed.
  pause
  exit /b 1
)

echo Portable Clawd chat
echo Type an instruction and press Enter.
echo Type exit to close.
echo.

:loop
set "MSG="
set /p MSG="You: "
if /I "!MSG!"=="exit" exit /b 0
if "!MSG!"=="" goto loop

echo.
call "%BASE%\scripts\openclaw-portable.bat" agent --local --agent main --thinking medium --message "!MSG!"
if "%POST_REPLY_NUDGE%"=="1" (
  start "Clawd Post Reply Nudge" /min cmd /d /c ""%BASE%\scripts\post-reply-nudge.cmd""
)
echo.
goto loop
