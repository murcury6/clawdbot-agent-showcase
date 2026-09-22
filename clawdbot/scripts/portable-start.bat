@echo off
setlocal EnableExtensions

for %%I in ("%~dp0..") do set "BASE=%%~fI"
set "LOGDIR=%BASE%\logs"
set "STARTLOG=%LOGDIR%\portable-start.log"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

title Portable Clawd Start
cls
echo [%date% %time%] Portable start requested.>> "%STARTLOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\sync-portable-keys.ps1" -BasePath "%BASE%" >nul
if /I not "%PORTABLE_CLAWD_UNLOCK_OK%"=="1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\require-unlock.ps1" -BasePath "%BASE%"
  if errorlevel 1 (
    echo.
    echo Unlock failed.
    echo [%date% %time%] Unlock failed.>> "%STARTLOG%"
    pause
    exit /b 1
  )
  set "PORTABLE_CLAWD_UNLOCK_OK=1"
)

if not exist "%BASE%\run" mkdir "%BASE%\run"
if exist "%BASE%\run\watchdog.pause" del /f /q "%BASE%\run\watchdog.pause" >nul 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\install-watchdog.ps1" -BasePath "%BASE%" >nul

echo Starting portable Clawd...
start "Clawd Portable Bootstrap" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\portable-start-background.ps1" -BasePath "%BASE%"

call :wait_for_port 11500 35
set "OLLAMA_READY=%ERRORLEVEL%"
call :wait_for_port 18789 45
set "GATEWAY_READY=%ERRORLEVEL%"

echo.
if "%OLLAMA_READY%"=="0" (
  echo   11500 : up
) else (
  echo   11500 : starting
)
if "%GATEWAY_READY%"=="0" (
  echo   18789 : up
) else (
  echo   18789 : starting
)

echo.
if "%GATEWAY_READY%"=="0" (
  echo Portable Clawd is running.
) else (
  echo Portable Clawd is still warming up.
  echo If it needs a little longer, check "%STARTLOG%" and "%BASE%\logs".
)

echo.
echo Chat: "%~dp0portable-chat.bat"
echo Logs: "%BASE%\logs"
echo Startup log: "%STARTLOG%"
echo.
echo This window is only a launcher status window.
echo The bot stays running after you close it.
pause
exit /b 0

:wait_for_port
setlocal
set "PORT=%~1"
set /a "TRIES=%~2"
:wait_loop
powershell -NoProfile -Command "$client = New-Object System.Net.Sockets.TcpClient; try { $a = $client.BeginConnect('127.0.0.1', %PORT%, $null, $null); $ok = $a.AsyncWaitHandle.WaitOne(400); if ($ok -and $client.Connected) { $client.EndConnect($a) | Out-Null; exit 0 } else { exit 1 } } catch { exit 1 } finally { $client.Close() }" >nul 2>nul
if not errorlevel 1 (
  endlocal & exit /b 0
)
set /a "TRIES-=1"
if %TRIES% LEQ 0 (
  endlocal & exit /b 1
)
timeout /t 1 /nobreak >nul
goto wait_loop
