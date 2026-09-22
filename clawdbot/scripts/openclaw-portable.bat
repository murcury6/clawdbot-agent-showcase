@echo off
setlocal

for %%I in ("%~dp0..") do set "BASE=%%~fI"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\scripts\invoke-openclaw-portable.ps1" -BasePath "%BASE%" %*
exit /b %ERRORLEVEL%
