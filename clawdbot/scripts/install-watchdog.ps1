param(
  [string]$BasePath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $BasePath)) {
  throw "Base path does not exist: $BasePath"
}

$BasePath = (Resolve-Path $BasePath).Path
$scriptPath = Join-Path $BasePath "scripts\watchdog-start.ps1"

if (-not (Test-Path $scriptPath)) {
  throw "Missing watchdog script: $scriptPath"
}

$taskName = "Portable Clawd Watchdog 1m"
$action = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -BasePath "{1}"' -f $scriptPath, $BasePath

& schtasks.exe /Create /TN $taskName /SC MINUTE /MO 1 /TR $action /F | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Output "watchdog_task=skipped"
  return
}

$startupDir = [Environment]::GetFolderPath("Startup")
if (-not $startupDir) {
  Write-Output "watchdog_startup=skipped"
  return
}

$startupLauncherPath = Join-Path $startupDir "Portable Clawd Watchdog.cmd"
$startupLauncher = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$scriptPath" -BasePath "$BasePath"
"@

Set-Content -Path $startupLauncherPath -Value $startupLauncher -Encoding ASCII

Write-Output ("task=" + $taskName)
Write-Output ("startup=" + $startupLauncherPath)
