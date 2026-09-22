@echo off
setlocal EnableExtensions EnableDelayedExpansion

for %%I in ("%~dp0..") do set "BASE=%%~fI"
set "RUN_DIR=%BASE%\run"
set "LOG_DIR=%BASE%\logs"
set "LOCK_DIR=%RUN_DIR%\keep-working-nudge.lock"
set "STOP_FILE=%RUN_DIR%\keep-working-nudge.stop"
set "BODY_FILE=%RUN_DIR%\keep-working-nudge-body.json"
set "RESP_FILE=%RUN_DIR%\keep-working-nudge-response.json"
set "CODE_FILE=%RUN_DIR%\keep-working-nudge-http.txt"
set "LOG_FILE=%LOG_DIR%\keep-working-nudge.log"
set "INTERVAL_SECONDS=30"
set "NUDGE_MESSAGE=Monitor detected unfinished queued work. Immediately take one real task-advancing action on the current active or queued job. Do not send only a status update. Do not stop after reading queue files or reporting status. Use a real tool, command, file edit, process action, browser step, or other concrete task step right now. If the current path is stuck, switch approach and keep pushing."

if not exist "%RUN_DIR%" mkdir "%RUN_DIR%" >nul 2>&1
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1

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
  echo Keep-working nudger is already running.
  exit /b 0
)
if exist "%STOP_FILE%" del "%STOP_FILE%" >nul 2>&1
start "Clawd Keep Working Nudge" /min cmd /d /c ""%~f0" run"
echo Keep-working nudger started.
exit /b 0

:run
if exist "%LOCK_DIR%" (
  echo Keep-working nudger is already running.
  exit /b 1
)
mkdir "%LOCK_DIR%" >nul 2>&1 || (
  echo Unable to create keep-working nudger lock.
  exit /b 1
)
if exist "%STOP_FILE%" del "%STOP_FILE%" >nul 2>&1
call :log keep-working nudger loop started

:loop
if exist "%STOP_FILE%" goto :cleanup
call :resolve_session_key
if errorlevel 1 (
  call :log unable to resolve session key from workspace\heartbeat-mode.json
  timeout /t %INTERVAL_SECONDS% /nobreak >nul
  goto :loop
)
call :resolve_hooks_token
if errorlevel 1 (
  call :log unable to resolve hooks token from state\.openclaw\openclaw.json
  timeout /t %INTERVAL_SECONDS% /nobreak >nul
  goto :loop
)
call :send_nudge
timeout /t %INTERVAL_SECONDS% /nobreak >nul
goto :loop

:once
call :resolve_session_key
if errorlevel 1 (
  echo Unable to resolve session key from workspace\heartbeat-mode.json
  exit /b 1
)
call :resolve_hooks_token
if errorlevel 1 (
  echo Unable to resolve hooks token from state\.openclaw\openclaw.json
  exit /b 1
)
call :send_nudge
exit /b %ERRORLEVEL%

:stop
break> "%STOP_FILE%"
echo Stop marker written. The nudger will exit within about %INTERVAL_SECONDS% seconds.
exit /b 0

:status
if exist "%LOCK_DIR%" (
  echo Keep-working nudger is running.
  if exist "%STOP_FILE%" echo Stop marker is present and shutdown is pending.
  exit /b 0
)
echo Keep-working nudger is not running.
exit /b 0

:help
echo keep-working-nudge.cmd [start^|run^|once^|stop^|status]
echo.
echo start  - launch the minute nudger in a minimized cmd window
echo run    - run the nudger loop in the current cmd window
echo once   - send one keep-working nudge immediately
echo stop   - ask the running nudger to stop
echo status - show whether the nudger loop is running
exit /b 0

:clear_stale_lock
if not exist "%LOCK_DIR%" exit /b 0
powershell.exe -NoProfile -Command "$running = @((Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $cmd = [string]$_.CommandLine; $cmd -like '*keep-working-nudge.cmd run*' })).Count -gt 0; if ($running) { exit 0 } else { exit 1 }" >nul 2>nul
if errorlevel 1 (
  if exist "%STOP_FILE%" del "%STOP_FILE%" >nul 2>&1
  rmdir "%LOCK_DIR%" >nul 2>&1
)
exit /b 0

:resolve_session_key
set "SESSION_KEY="
set "SESSION_LINE="
set "SESSION_VALUE="
for /f "usebackq delims=" %%L in (`findstr /i /c:"\"sessionKey\"" "%BASE%\workspace\heartbeat-mode.json"`) do (
  if not defined SESSION_LINE set "SESSION_LINE=%%L"
)
if not defined SESSION_LINE exit /b 1
for /f "tokens=1,* delims=:" %%A in ("!SESSION_LINE!") do (
  if not defined SESSION_VALUE set "SESSION_VALUE=%%B"
)
if not defined SESSION_VALUE exit /b 1
set "SESSION_KEY=!SESSION_VALUE:"=!"
set "SESSION_KEY=!SESSION_KEY:,=!"
set "SESSION_KEY=!SESSION_KEY: =!"
if not defined SESSION_KEY exit /b 1
exit /b 0

:resolve_hooks_token
set "HOOKS_TOKEN="
set "HOOKS_LINE="
set "TOKEN_LINE="
set "TOKEN_VALUE="
for /f "tokens=1,* delims=:" %%A in ('findstr /n /i /c:"\"hooks\"" "%BASE%\state\.openclaw\openclaw.json"') do (
  if not defined HOOKS_LINE set "HOOKS_LINE=%%A"
)
if not defined HOOKS_LINE exit /b 1
for /f "tokens=1,* delims=:" %%A in ('findstr /n /i /c:"\"token\"" "%BASE%\state\.openclaw\openclaw.json"') do (
  if %%A gtr !HOOKS_LINE! if not defined TOKEN_LINE set "TOKEN_LINE=%%B"
)
if not defined TOKEN_LINE exit /b 1
for /f "tokens=1,* delims=:" %%A in ("!TOKEN_LINE!") do (
  if not defined TOKEN_VALUE set "TOKEN_VALUE=%%B"
)
if not defined TOKEN_VALUE exit /b 1
set "HOOKS_TOKEN=!TOKEN_VALUE:"=!"
set "HOOKS_TOKEN=!HOOKS_TOKEN:,=!"
set "HOOKS_TOKEN=!HOOKS_TOKEN: =!"
if not defined HOOKS_TOKEN exit /b 1
exit /b 0

:send_nudge
call :write_body
curl.exe -sS --max-time 90 ^
  -X POST "http://127.0.0.1:18789/hooks/agent" ^
  -H "Authorization: Bearer !HOOKS_TOKEN!" ^
  -H "Content-Type: application/json" ^
  --data-binary "@%BODY_FILE%" ^
  -o "%RESP_FILE%" ^
  -w "%%{http_code}" > "%CODE_FILE%"
set "CURL_EXIT=%ERRORLEVEL%"
set "HTTP_CODE="
set /p HTTP_CODE=<"%CODE_FILE%"
if not "%CURL_EXIT%"=="0" (
  call :log curl transport failure exit=%CURL_EXIT%
  exit /b %CURL_EXIT%
)
if /I "!HTTP_CODE!"=="200" (
  call :log nudge accepted for !SESSION_KEY!
  exit /b 0
)
call :log nudge failed http=!HTTP_CODE!
exit /b 1

:write_body
> "%BODY_FILE%" echo {
>> "%BODY_FILE%" echo   "message": "%NUDGE_MESSAGE%",
>> "%BODY_FILE%" echo   "agentId": "main",
>> "%BODY_FILE%" echo   "sessionKey": "!SESSION_KEY!",
>> "%BODY_FILE%" echo   "wakeMode": "now",
>> "%BODY_FILE%" echo   "deliver": false
>> "%BODY_FILE%" echo }
exit /b 0

:log
set "STAMP=%date% %time%"
>> "%LOG_FILE%" echo [%STAMP%] %*
exit /b 0

:cleanup
call :log keep-working nudger loop stopped
if exist "%STOP_FILE%" del "%STOP_FILE%" >nul 2>&1
if exist "%LOCK_DIR%" rmdir "%LOCK_DIR%" >nul 2>&1
exit /b 0
