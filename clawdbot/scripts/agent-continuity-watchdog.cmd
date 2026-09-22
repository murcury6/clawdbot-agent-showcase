@echo off
setlocal EnableExtensions

for %%I in ("%~dp0..") do set "BASE=%%~fI"
set "RUN_DIR=%BASE%\run"
set "LOCK_DIR=%RUN_DIR%\agent-continuity-watchdog.lock"
set "STOP_FILE=%RUN_DIR%\agent-continuity-watchdog.stop"
set "SCRIPT=%BASE%\scripts\agent-continuity-watchdog.ps1"
set "INTERVAL_SECONDS=15"
set "IDLE_AFTER_USER_SECONDS=20"
set "IDLE_AFTER_ASSISTANT_SECONDS=20"
set "REPEAT_COOLDOWN_SECONDS=90"

if not exist "%RUN_DIR%" mkdir "%RUN_DIR%" >nul 2>&1

set "MODE=%~1"
if not defined MODE set "MODE=run"

call :clear_stale_lock
if /I "%MODE%"=="start" goto :start
if /I "%MODE%"=="run" goto :run
if /I "%MODE%"=="once" goto :once
if /I "%MODE%"=="stop" goto :stop
if /I "%MODE%"=="status" goto :status
if /I "%MODE%"=="help" goto :help

echo Unknown command: %MODE%
echo.
goto :help

:start
if exist "%LOCK_DIR%" (
  echo Agent continuity watchdog is already running.
  exit /b 0
)
if exist "%STOP_FILE%" del "%STOP_FILE%" >nul 2>&1
start "Clawd Continuity Watchdog" /min cmd /d /c ""%~f0" run"
echo Agent continuity watchdog started.
exit /b 0

:run
if exist "%LOCK_DIR%" (
  echo Agent continuity watchdog is already running.
  exit /b 1
)
mkdir "%LOCK_DIR%" >nul 2>&1 || (
  echo Unable to create continuity watchdog lock.
  exit /b 1
)
if exist "%STOP_FILE%" del "%STOP_FILE%" >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -BasePath "%BASE%" -Mode run -IntervalSeconds %INTERVAL_SECONDS% -IdleAfterUserSeconds %IDLE_AFTER_USER_SECONDS% -IdleAfterAssistantSeconds %IDLE_AFTER_ASSISTANT_SECONDS% -RepeatCooldownSeconds %REPEAT_COOLDOWN_SECONDS%
if exist "%STOP_FILE%" del "%STOP_FILE%" >nul 2>&1
if exist "%LOCK_DIR%" rmdir "%LOCK_DIR%" >nul 2>&1
exit /b %ERRORLEVEL%

:once
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -BasePath "%BASE%" -Mode once -IntervalSeconds %INTERVAL_SECONDS% -IdleAfterUserSeconds %IDLE_AFTER_USER_SECONDS% -IdleAfterAssistantSeconds %IDLE_AFTER_ASSISTANT_SECONDS% -RepeatCooldownSeconds %REPEAT_COOLDOWN_SECONDS%
exit /b %ERRORLEVEL%

:stop
break> "%STOP_FILE%"
echo Stop marker written. The watchdog will exit shortly.
exit /b 0

:status
if exist "%LOCK_DIR%" (
  echo Agent continuity watchdog is running.
  if exist "%STOP_FILE%" echo Stop marker is present and shutdown is pending.
  exit /b 0
)
echo Agent continuity watchdog is not running.
exit /b 0

:help
echo agent-continuity-watchdog.cmd [start^|run^|once^|stop^|status]
echo.
echo start  - launch the watchdog in a minimized cmd window
echo run    - run the watchdog loop in the current cmd window
echo once   - run one transcript check immediately
echo stop   - ask the running watchdog to stop
echo status - show whether the watchdog loop is running
exit /b 0

:clear_stale_lock
if not exist "%LOCK_DIR%" exit /b 0
powershell.exe -NoProfile -Command "$running = @((Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $cmd = [string]$_.CommandLine; $cmd -like '*agent-continuity-watchdog.ps1*' })).Count -gt 0; if ($running) { exit 0 } else { exit 1 }" >nul 2>nul
if errorlevel 1 (
  if exist "%STOP_FILE%" del "%STOP_FILE%" >nul 2>&1
  rmdir "%LOCK_DIR%" >nul 2>&1
)
exit /b 0