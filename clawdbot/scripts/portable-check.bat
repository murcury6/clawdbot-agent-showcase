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

echo Portable backend ports:
powershell -NoProfile -Command "$ports = 11500,18789; foreach ($p in $ports) { $client = New-Object System.Net.Sockets.TcpClient; try { $a = $client.BeginConnect('127.0.0.1',$p,$null,$null); $ok = $a.AsyncWaitHandle.WaitOne(400); if ($ok -and $client.Connected) { $client.EndConnect($a) | Out-Null; Write-Host ($p.ToString() + ': up') } else { Write-Host ($p.ToString() + ': down') } } catch { Write-Host ($p.ToString() + ': down') } finally { $client.Close() } }"
echo.
call "%BASE%\scripts\openclaw-portable.bat" status --json
exit /b %ERRORLEVEL%
