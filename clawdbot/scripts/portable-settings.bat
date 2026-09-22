@echo off
setlocal

for %%I in ("%~dp0..") do set "BASE=%%~fI"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\sync-portable-keys.ps1" -BasePath "%BASE%" >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\require-unlock.ps1" -BasePath "%BASE%"
if errorlevel 1 (
  echo.
  echo Unlock failed.
  pause
  exit /b 1
)
set "PORTABLE_CLAWD_UNLOCK_OK=1"

:menu
cls
echo Portable Clawd settings
echo.
echo 1. Open config
echo 2. Open AI context folder
echo 3. Model mode: auto
echo 4. Model mode: smart-cost
echo 5. Model mode: online-first
echo 6. Model mode: offline-first
echo 7. Show current model selection
echo 8. Open keys folder
echo 9. Open workspace folder
echo A. Open logs folder
echo B. Lock now
echo C. Fresh start: clear bot data, keep setup
echo 0. Exit
echo.
choice /C 123456789ABC0 /N /M "Select: "

if errorlevel 13 exit /b 0
if errorlevel 12 call "%BASE%\scripts\portable-fresh-start.bat" & exit /b 0
if errorlevel 11 powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\require-unlock.ps1" -BasePath "%BASE%" -LockOnly & echo. & pause & exit /b 0
if errorlevel 10 start "" explorer.exe "%BASE%\logs" & goto menu
if errorlevel 9 start "" explorer.exe "%BASE%\workspace" & goto menu
if errorlevel 8 start "" explorer.exe "%BASE%\clawdkeys" & goto menu
if errorlevel 7 cls & powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\select-model.ps1" -BasePath "%BASE%" -Show & echo. & pause & goto menu
if errorlevel 6 powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\select-model.ps1" -BasePath "%BASE%" -SetMode offline-first >nul & goto menu
if errorlevel 5 powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\select-model.ps1" -BasePath "%BASE%" -SetMode online-first >nul & goto menu
if errorlevel 4 powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\select-model.ps1" -BasePath "%BASE%" -SetMode smart-cost >nul & goto menu
if errorlevel 3 powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\select-model.ps1" -BasePath "%BASE%" -SetMode auto >nul & goto menu
if errorlevel 2 powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\sync-ai-context.ps1" -BasePath "%BASE%" >nul & start "" explorer.exe "%BASE%\EDIT_AI_HERE" & goto menu
if errorlevel 1 start "" notepad.exe "%BASE%\state\.openclaw\openclaw.json" & goto menu
