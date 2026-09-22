param(
  [string]$BasePath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $BasePath)) {
  throw "Base path does not exist: $BasePath"
}

$BasePath = (Resolve-Path $BasePath).Path
$runDir = Join-Path $BasePath "run"
$logsDir = Join-Path $BasePath "logs"
$workspaceDir = Join-Path $BasePath "workspace"
$editableDir = Join-Path $BasePath "EDIT_AI_HERE"
$stateDir = Join-Path $BasePath "state\.openclaw"
$sessionsDir = Join-Path $stateDir "agents\main\sessions"
$backupsDir = Join-Path $sessionsDir "backups"
$workspaceMemoryDir = Join-Path $workspaceDir "memory"
$editableMemoryDir = Join-Path $editableDir "memory"
$deliveryFailedDir = Join-Path $stateDir "delivery-queue\failed"
$telegramDir = Join-Path $stateDir "telegram"
$pausePath = Join-Path $runDir "watchdog.pause"
$taskListPath = Join-Path $workspaceDir "task-list.json"
$progressStatusPath = Join-Path $workspaceDir "progress-status.md"
$sessionsPath = Join-Path $sessionsDir "sessions.json"

function Write-Utf8NoBom {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Content
  )

  $parent = Split-Path -Parent $Path
  if ($parent) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-JsonFileNoBom {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [object]$Value,
    [int]$Depth = 100
  )

  $json = $Value | ConvertTo-Json -Depth $Depth
  Write-Utf8NoBom -Path $Path -Content ($json + [Environment]::NewLine)
}

function Remove-PathIfPresent {
  param([string]$Path)

  if (Test-Path $Path) {
    Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Clear-DirectoryContents {
  param([string]$Path)

  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
  }
}

New-Item -ItemType Directory -Path $runDir -Force | Out-Null
New-Item -ItemType File -Path $pausePath -Force | Out-Null

& (Join-Path $BasePath "scripts\stop-stack.ps1") -BasePath $BasePath | Out-Null

Clear-DirectoryContents -Path $backupsDir

@(
  (Join-Path $sessionsDir "*.jsonl"),
  (Join-Path $sessionsDir "*.lock"),
  $sessionsPath
) | ForEach-Object {
  Get-ChildItem -Path $_ -Force -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
  }
}

Clear-DirectoryContents -Path $workspaceMemoryDir
Clear-DirectoryContents -Path $editableMemoryDir
Clear-DirectoryContents -Path $deliveryFailedDir

@(
  (Join-Path $stateDir "memory\main.sqlite"),
  (Join-Path $stateDir "access-session.json"),
  (Join-Path $runDir "utf8nobom-test.json"),
  (Join-Path $workspaceDir "telegram-controller-test.txt")
) | ForEach-Object {
  Remove-PathIfPresent -Path $_
}

Get-ChildItem -Path $telegramDir -Filter "command-hash-*.txt" -File -ErrorAction SilentlyContinue | ForEach-Object {
  Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
}

Get-ChildItem -Path $logsDir -Filter "*.log" -File -ErrorAction SilentlyContinue | ForEach-Object {
  Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
}

$taskList = [pscustomobject]@{
  goal = "Run Jordyn's ordered Telegram job queue autonomously and report real progress."
  currentJobId = $null
  doingNow = @()
  jobQueue = @()
  done = @()
  blockedBy = @()
  updatedAt = (Get-Date).ToString("o")
}

Write-JsonFileNoBom -Path $taskListPath -Value $taskList
Write-Utf8NoBom -Path $progressStatusPath -Content ("No active jobs." + [Environment]::NewLine)
Write-Utf8NoBom -Path $sessionsPath -Content ("{}" + [Environment]::NewLine)

& (Join-Path $BasePath "scripts\sync-ai-context.ps1") -BasePath $BasePath | Out-Null
& (Join-Path $BasePath "scripts\select-model.ps1") -BasePath $BasePath | Out-Null

Write-Output "stack=stopped"
Write-Output "watchdog=paused"
Write-Output "sessions=cleared"
Write-Output "memory=cleared"
Write-Output "queue=reset"
Write-Output "logs=cleared"
Write-Output "setup=preserved"
