@echo off
setlocal EnableExtensions

for %%I in ("%~dp0..") do set "BASE=%%~fI"
set "RUN_DIR=%BASE%\run"
set "LOCK_DIR=%RUN_DIR%\telegram-work-controller.lock"
set "STOP_FILE=%RUN_DIR%\telegram-work-controller.stop"
set "SCRIPT=%BASE%\scripts\telegram-work-controller.ps1"
set "INTERVAL_SECONDS=15"
set "IDLE_SECONDS=20"
set "TOOL_STALL_SECONDS=90"
set "REPEAT_COOLDOWN_SECONDS=75"

if not exist "%RUN_DIR%" mkdir "%RUN_DIR%" >nul 2>&1

set "MODE=%~1"
if not defined MODE set "MODE=run"

call :clear_stale_lock
if /I "%MODE%"=="start" goto :start
if /I "%MODE%"=="run" goto :run
if /I "%MODE%"=="once" goto :once
if /I "%MODE%"=="stop" goto :stop
if /I "%MODE%"=="status" goto :status

echo Unknown command: %MODE%
exit /b 1

:start
if exist "%LOCK_DIR%" exit /b 0
if exist "%STOP_FILE%" del "%STOP_FILE%" >nul 2>&1
start "Clawd Telegram Work Controller" /min cmd /d /c ""%~f0" run"
exit /b 0

:run
if exist "%LOCK_DIR%" exit /b 0
mkdir "%LOCK_DIR%" >nul 2>&1 || exit /b 1
if exist "%STOP_FILE%" del "%STOP_FILE%" >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -BasePath "%BASE%" -Mode run -IntervalSeconds %INTERVAL_SECONDS% -IdleSeconds %IDLE_SECONDS% -ToolStallSeconds %TOOL_STALL_SECONDS% -RepeatCooldownSeconds %REPEAT_COOLDOWN_SECONDS%
if exist "%STOP_FILE%" del "%STOP_FILE%" >nul 2>&1
if exist "%LOCK_DIR%" rmdir "%LOCK_DIR%" >nul 2>&1
exit /b %ERRORLEVEL%

:once
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -BasePath "%BASE%" -Mode once -IntervalSeconds %INTERVAL_SECONDS% -IdleSeconds %IDLE_SECONDS% -ToolStallSeconds %TOOL_STALL_SECONDS% -RepeatCooldownSeconds %REPEAT_COOLDOWN_SECONDS%
exit /b %ERRORLEVEL%

:stop
break> "%STOP_FILE%"
exit /b 0

:status
if exist "%LOCK_DIR%" (
  echo running
  exit /b 0
)
echo stopped
exit /b 0

:clear_stale_lock
if not exist "%LOCK_DIR%" exit /b 0
powershell.exe -NoProfile -Command "$running = @((Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $cmd = [string]$_.CommandLine; $cmd -like '*telegram-work-controller.ps1*' })).Count -gt 0; if ($running) { exit 0 } else { exit 1 }" >nul 2>nul
if errorlevel 1 (
  if exist "%STOP_FILE%" del "%STOP_FILE%" >nul 2>&1
  rmdir "%LOCK_DIR%" >nul 2>&1
)
exit /b 0