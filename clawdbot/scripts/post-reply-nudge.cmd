@echo off
setlocal

for %%I in ("%~dp0..") do set "BASE=%%~fI"
set "NUDGE_TEXT=Keep working. Continue the current task without asking what to do next. Take the next concrete action now. If you are blocked, pick the best available unblocking step and do it."

call "%BASE%\scripts\openclaw-portable.bat" agent --local --agent main --thinking low --message "%NUDGE_TEXT%" >nul
exit /b %ERRORLEVEL%
