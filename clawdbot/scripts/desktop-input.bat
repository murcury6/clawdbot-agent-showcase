@echo off
setlocal
powershell -Sta -NoProfile -ExecutionPolicy Bypass -File "%~dp0desktop-input.ps1" %*
exit /b %ERRORLEVEL%
