param(
  [string]$BasePath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  [ValidateSet("once", "run")]
  [string]$Mode = "once",
  [int]$IntervalSeconds = 8
)

$ErrorActionPreference = "Stop"

$BasePath = (Resolve-Path $BasePath).Path
$RunDir = Join-Path $BasePath "run"
$LogDir = Join-Path $BasePath "logs"
$StateDir = Join-Path $BasePath "state\.openclaw"
$StopFile = Join-Path $RunDir "telegram-auto-continue.stop"
$StateFile = Join-Path $RunDir "telegram-auto-continue-state.json"
$LogFile = Join-Path $LogDir "telegram-auto-continue.log"
$ConfigPath = Join-Path $StateDir "openclaw.json"
$SessionsPath = Join-Path $StateDir "agents\main\sessions\sessions.json"
$NudgeText = "A Telegram update was just sent, but unfinished work still exists. Immediately take one real task-advancing action on the active or queued job now. Do not send another status-only reply as your next step. Do not stop after reading queue files. Use a real tool, command, file edit, process action, browser step, or other concrete work step. If the current path is stuck, switch approach and keep pushing."

New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

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
    [int]$Depth = 50
  )

  $json = $Value | ConvertTo-Json -Depth $Depth
  Write-Utf8NoBom -Path $Path -Content ($json + [Environment]::NewLine)
}

function Write-Log {
  param([string]$Message)

  $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Add-Content -Path $LogFile -Value ("[{0}] {1}" -f $stamp, $Message) -Encoding UTF8
}

function Read-JsonFile {
  param([string]$Path)

  if (-not (Test-Path $Path)) {
    return $null
  }

  $raw = Get-Content $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $null
  }

  return ($raw | ConvertFrom-Json)
}

function Read-JsonLines {
  param([string]$Path)

  $items = @()
  if (-not (Test-Path $Path)) {
    return $items
  }

  foreach ($line in (Get-Content $Path)) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    try {
      $items += ($line | ConvertFrom-Json)
    } catch {
    }
  }

  return $items
}

function Get-EntryTimestampMs {
  param($Entry)

  if (-not $Entry -or -not $Entry.timestamp) {
    return 0L
  }

  try {
    return ([DateTimeOffset]::Parse([string]$Entry.timestamp).ToUnixTimeMilliseconds())
  } catch {
    return 0L
  }
}

function Get-MessageText {
  param($Entry)

  if (-not $Entry -or $Entry.type -ne "message" -or -not $Entry.message -or -not $Entry.message.content) {
    return ""
  }

  $parts = @()
  foreach ($part in @($Entry.message.content)) {
    if ($part.type -eq "text" -and $null -ne $part.text) {
      $parts += [string]$part.text
    }
  }

  return ($parts -join "`n").Trim()
}

function Normalize-Text {
  param([string]$Text)

  if (-not $Text) {
    return ""
  }

  return (($Text -replace '\s+', ' ').Trim())
}

function Get-CleanUserText {
  param($Entry)

  $text = Get-MessageText $Entry
  if (-not $text) {
    return ""
  }

  $clean = [regex]::Replace(
    $text,
    '(?s)^Conversation info \(untrusted metadata\):.*?Sender \(untrusted metadata\):\s*```json.*?```\s*',
    ''
  )

  $clean = Normalize-Text $clean
  if (-not $clean) {
    $clean = Normalize-Text $text
  }

  return $clean
}

function Test-IsHookUserMessage {
  param($Entry)

  if (-not $Entry -or $Entry.type -ne "message" -or -not $Entry.message -or $Entry.message.role -ne "user") {
    return $false
  }

  $text = Get-MessageText $Entry
  if ($text -match '^\[cron:[^\]]+\s+Hook\]') {
    return $true
  }

  if ($text -match '^Read HEARTBEAT\.md if it exists \(workspace context\)\.') {
    return $true
  }

  if ($text -match '^Pre-compaction memory flush\.') {
    return $true
  }

  if ($text -eq $NudgeText) {
    return $true
  }

  return $false
}

function Get-LatestUserControl {
  param([object[]]$Entries)

  for ($i = $Entries.Count - 1; $i -ge 0; $i--) {
    $entry = $Entries[$i]
    if ($entry.type -ne "message" -or -not $entry.message -or $entry.message.role -ne "user") {
      continue
    }
    if (Test-IsHookUserMessage $entry) {
      continue
    }

    $text = (Get-CleanUserText $entry).ToLowerInvariant()
    if ($text -in @("pause", "stop", "resume", "go", "continue")) {
      return [pscustomobject]@{
        text = $text
        timestampMs = Get-EntryTimestampMs $entry
      }
    }
  }

  return $null
}

function Get-LatestAssistantReply {
  param([object[]]$Entries)

  for ($i = $Entries.Count - 1; $i -ge 0; $i--) {
    $entry = $Entries[$i]
    if ($entry.type -ne "message" -or -not $entry.message -or $entry.message.role -ne "assistant") {
      continue
    }

    $text = Get-MessageText $entry
    if ([string]::IsNullOrWhiteSpace($text)) {
      continue
    }

    return [pscustomobject]@{
      text = $text
      timestampMs = Get-EntryTimestampMs $entry
    }
  }

  return $null
}

function Get-LatestGatewayLogPath {
  $tempDir = Join-Path $env:TEMP "openclaw"
  if (-not (Test-Path $tempDir)) {
    return $null
  }

  $file = Get-ChildItem $tempDir -File -Filter "openclaw-*.log" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if (-not $file) {
    return $null
  }

  return $file.FullName
}

function Get-LatestTelegramSendSuccessMs {
  param([string]$ChatId)

  $logPath = Get-LatestGatewayLogPath
  if (-not $logPath) {
    return 0L
  }

  $latest = 0L
  foreach ($line in (Get-Content $logPath -Tail 400)) {
    if ($line -notmatch 'sendMessage ok chat=') {
      continue
    }
    if ($ChatId -and $line -notmatch ("chat=" + [regex]::Escape($ChatId))) {
      continue
    }
    if ($line -match '"time":"([^"]+)"') {
      try {
        $ts = [DateTimeOffset]::Parse($matches[1]).ToUnixTimeMilliseconds()
        if ($ts -gt $latest) {
          $latest = $ts
        }
      } catch {
      }
    }
  }

  return $latest
}

function Send-HiddenNudge {
  param(
    [string]$HooksToken,
    [string]$SessionKey
  )

  $uri = "http://127.0.0.1:18789/hooks/agent"
  $body = @{
    message = $NudgeText
    agentId = "main"
    sessionKey = $SessionKey
    wakeMode = "now"
    deliver = $false
  } | ConvertTo-Json -Depth 10

  Invoke-RestMethod -Method Post -Uri $uri -Headers @{
    Authorization = "Bearer $HooksToken"
    "Content-Type" = "application/json"
  } -Body $body | Out-Null
}

function Get-OrCreateState {
  $state = Read-JsonFile $StateFile
  if ($state) {
    return $state
  }

  return [pscustomobject]@{
    paused = $false
    lastNudgedAssistantTimestampMs = 0
  }
}

function Invoke-Cycle {
  $config = Read-JsonFile $ConfigPath
  $sessions = Read-JsonFile $SessionsPath
  if (-not $config -or -not $sessions) {
    return
  }

  $sessionKey = [string]$config.agents.defaults.heartbeat.session
  if ([string]::IsNullOrWhiteSpace($sessionKey)) {
    return
  }

  $sessionEntry = $sessions.PSObject.Properties[$sessionKey]
  if (-not $sessionEntry -or -not $sessionEntry.Value -or -not $sessionEntry.Value.sessionFile) {
    return
  }

  $sessionFile = [string]$sessionEntry.Value.sessionFile
  $entries = @(Read-JsonLines $sessionFile)
  if ($entries.Count -eq 0) {
    return
  }

  $state = Get-OrCreateState
  $control = Get-LatestUserControl $entries
  if ($control) {
    if ($control.text -in @("pause", "stop")) {
      if (-not $state.paused) {
        $state.paused = $true
        Write-Log ("Paused by user command: " + $control.text)
      }
      Write-JsonFileNoBom -Path $StateFile -Value $state
      return
    }
    if ($control.text -in @("resume", "go", "continue")) {
      if ($state.paused) {
        $state.paused = $false
        Write-Log ("Resumed by user command: " + $control.text)
      }
    }
  }

  if ($state.paused) {
    Write-JsonFileNoBom -Path $StateFile -Value $state
    return
  }

  $assistant = Get-LatestAssistantReply $entries
  if (-not $assistant) {
    return
  }

  if ([int64]$assistant.timestampMs -le [int64]$state.lastNudgedAssistantTimestampMs) {
    return
  }

  $chatId = ""
  if ($config.channels -and $config.channels.telegram -and $config.channels.telegram.allowFrom) {
    $chatId = [string](@($config.channels.telegram.allowFrom | Select-Object -First 1)[0])
  }
  $sendSuccessMs = Get-LatestTelegramSendSuccessMs -ChatId $chatId
  if ($sendSuccessMs -lt [int64]$assistant.timestampMs) {
    return
  }

  $hooksToken = [string]$config.hooks.token
  if ([string]::IsNullOrWhiteSpace($hooksToken)) {
    return
  }

  Send-HiddenNudge -HooksToken $hooksToken -SessionKey $sessionKey
  $state.lastNudgedAssistantTimestampMs = [int64]$assistant.timestampMs
  Write-JsonFileNoBom -Path $StateFile -Value $state
  Write-Log ("Queued keep-working nudge after Telegram send for assistant timestamp " + $assistant.timestampMs)
}

if ($Mode -eq "once") {
  Invoke-Cycle
  exit 0
}

Write-Log "telegram auto-continue loop started"
while ($true) {
  if (Test-Path $StopFile) {
    Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
    Write-Log "telegram auto-continue loop stopped"
    exit 0
  }

  try {
    Invoke-Cycle
  } catch {
    Write-Log ("cycle error: " + $_.Exception.Message)
  }

  Start-Sleep -Seconds $IntervalSeconds
}
