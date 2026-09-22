param(
  [string]$BasePath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  [ValidateSet("once", "run")]
  [string]$Mode = "once",
  [int]$IntervalSeconds = 45,
  [int]$IdleAfterUserSeconds = 20,
  [int]$IdleAfterAssistantSeconds = 45,
  [int]$RepeatCooldownSeconds = 180
)

$ErrorActionPreference = "Stop"

$BasePath = (Resolve-Path $BasePath).Path
$RunDir = Join-Path $BasePath "run"
$LogDir = Join-Path $BasePath "logs"
$WorkspaceDir = Join-Path $BasePath "workspace"
$StateDir = Join-Path $BasePath "state\.openclaw"
$StopFile = Join-Path $RunDir "agent-continuity-watchdog.stop"
$StateFile = Join-Path $RunDir "agent-continuity-watchdog-state.json"
$LogFile = Join-Path $LogDir "agent-continuity-watchdog.log"
$HeartbeatPath = Join-Path $WorkspaceDir "heartbeat-mode.json"
$TaskListPath = Join-Path $WorkspaceDir "task-list.json"
$ConfigPath = Join-Path $StateDir "openclaw.json"
$SessionsPath = Join-Path $StateDir "agents\main\sessions\sessions.json"

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
    [int]$Depth = 100
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

function Test-AssistantHasToolCall {
  param($Entry)

  if (-not $Entry -or $Entry.type -ne "message" -or -not $Entry.message -or $Entry.message.role -ne "assistant") {
    return $false
  }

  foreach ($part in @($Entry.message.content)) {
    if ($part.type -eq "toolCall") {
      return $true
    }
  }

  return $false
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

  return $false
}

function Normalize-Spaces {
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

  $clean = Normalize-Spaces $clean
  if (-not $clean) {
    $clean = Normalize-Spaces $text
  }

  return $clean
}

function Test-IsNudgeText {
  param([string]$Text)

  $normalized = (Normalize-Spaces $Text).ToLowerInvariant()
  if (-not $normalized) {
    return $true
  }

  if ($normalized -match '^(keep working|continue work|continue working|continue|keep going)[.! ]*$') {
    return $true
  }

  if ($normalized -match '^(status|what''?s the status|whats the status)[?! ]*$') {
    return $true
  }

  if ($normalized.Length -lt 120 -and $normalized -match '^return .+ when it.?s done[.! ]*$') {
    return $true
  }

  return $false
}

function Test-IsHeartbeatAssistantText {
  param([string]$Text)

  $normalized = Normalize-Spaces $Text
  if (-not $normalized) {
    return $false
  }

  if ($normalized -eq "HEARTBEAT_OK") {
    return $true
  }

  if ($normalized -match '^(Current Jobs|Working Now):') {
    return $true
  }

  return $false
}

function Get-PrimaryUserEntry {
  param([object[]]$Entries)

  $userEntries = @(
    $Entries |
      Where-Object {
        $_.type -eq "message" -and
        $_.message -and
        $_.message.role -eq "user" -and
        -not (Test-IsHookUserMessage $_)
      }
  )

  if ($userEntries.Count -eq 0) {
    return $null
  }

  for ($i = $userEntries.Count - 1; $i -ge 0; $i--) {
    $clean = Get-CleanUserText $userEntries[$i]
    if (-not (Test-IsNudgeText $clean)) {
      return $userEntries[$i]
    }
  }

  return $userEntries[-1]
}

function Get-ShortTitle {
  param([string]$Text)

  $clean = Normalize-Spaces $Text
  if ($clean.Length -le 100) {
    return $clean
  }

  return ($clean.Substring(0, 97) + "...")
}

function Test-TaskListHasActiveWork {
  param($TaskList)

  if (-not $TaskList) {
    return $false
  }

  if ($TaskList.currentJobId -and -not [string]::IsNullOrWhiteSpace([string]$TaskList.currentJobId)) {
    return $true
  }

  if ($TaskList.jobQueue -and @($TaskList.jobQueue).Count -gt 0) {
    return $true
  }

  return $false
}

function Ensure-TaskListFromTranscript {
  param(
    [string]$PrimaryText,
    [long]$PrimaryTimestampMs,
    [bool]$HasToolAfterPrimary
  )

  $taskList = Read-JsonFile $TaskListPath
  if (Test-TaskListHasActiveWork $taskList) {
    return $false
  }

  $jobId = "watchdog-" + $PrimaryTimestampMs
  $status = if ($HasToolAfterPrimary) { "doing" } else { "queued" }
  $taskListObject = [ordered]@{
    goal = $PrimaryText
    currentJobId = if ($HasToolAfterPrimary) { $jobId } else { $null }
    doingNow = @()
    jobQueue = @(
      [ordered]@{
        id = $jobId
        title = Get-ShortTitle $PrimaryText
        status = $status
        completionMode = "finite"
        notes = "Recovered from active Telegram transcript by continuity watchdog."
      }
    )
    done = @()
    blockedBy = @()
    updatedAt = (Get-Date).ToString("o")
  }

  Write-JsonFileNoBom -Path $TaskListPath -Value $taskListObject
  Write-Log ("Recovered task-list.json from transcript: " + (Get-ShortTitle $PrimaryText))
  return $true
}

function Ensure-TaskListFromHeartbeat {
  param(
    [string]$GoalText,
    [string]$Reason
  )

  $cleanGoal = Normalize-Spaces $GoalText
  if (-not $cleanGoal) {
    return $false
  }

  $taskList = Read-JsonFile $TaskListPath
  if (Test-TaskListHasActiveWork $taskList) {
    return $false
  }

  $jobId = "watchdog-heartbeat"
  $taskListObject = [ordered]@{
    goal = $cleanGoal
    currentJobId = $null
    doingNow = @()
    jobQueue = @(
      [ordered]@{
        id = $jobId
        title = Get-ShortTitle $cleanGoal
        status = "queued"
        completionMode = "indefinite"
        notes = $Reason
      }
    )
    done = @()
    blockedBy = @()
    updatedAt = (Get-Date).ToString("o")
  }

  Write-JsonFileNoBom -Path $TaskListPath -Value $taskListObject
  Write-Log ("Recovered task-list.json from heartbeat state: " + (Get-ShortTitle $cleanGoal))
  return $true
}

function Resolve-SessionTranscriptFile {
  param(
    [string]$SessionKey,
    $SessionEntry
  )

  if (-not $SessionEntry) {
    return $null
  }

  $explicitSessionFile = [string]$SessionEntry.sessionFile
  if (-not [string]::IsNullOrWhiteSpace($explicitSessionFile) -and (Test-Path $explicitSessionFile)) {
    return $explicitSessionFile
  }

  $sessionId = [string]$SessionEntry.sessionId
  if ([string]::IsNullOrWhiteSpace($sessionId)) {
    return $null
  }

  $sessionsDir = Join-Path $StateDir "agents\main\sessions"
  $candidatePaths = @(
    (Join-Path $sessionsDir ($sessionId + ".jsonl")),
    (Join-Path $sessionsDir ("transcript-" + $sessionId + ".jsonl")),
    (Join-Path $sessionsDir ("session-" + $sessionId + ".jsonl")),
    (Join-Path (Join-Path $sessionsDir "transcripts") ($sessionId + ".jsonl")),
    (Join-Path (Join-Path $sessionsDir "backups") ($sessionId + ".jsonl"))
  )

  foreach ($candidate in $candidatePaths) {
    if ($candidate -and (Test-Path $candidate)) {
      return $candidate
    }
  }

  $matches = @(
    Get-ChildItem -Path $sessionsDir -Recurse -File -Filter "*.jsonl" -ErrorAction SilentlyContinue |
      Where-Object { $_.BaseName -like ("*" + $sessionId + "*") } |
      Sort-Object LastWriteTime -Descending
  )

  if ($matches.Count -gt 0) {
    return $matches[0].FullName
  }

  Write-Log ("No transcript file found for " + $SessionKey + " (sessionId=" + $sessionId + ")")
  return $null
}

function Send-RecoveryHook {
  param(
    [string]$PrimaryText,
    [string]$Reason,
    [string]$SessionKey
  )

  $config = Read-JsonFile $ConfigPath
  if (-not $config -or -not $config.gateway -or -not $config.hooks) {
    throw "Missing gateway/hooks config."
  }

  $port = [int]$config.gateway.port
  $hookPath = [string]$config.hooks.path
  $hookToken = [string]$config.hooks.token
  if (-not $hookPath) {
    $hookPath = "/hooks"
  }

  $body = [ordered]@{
    name = "Continuity Watchdog"
    message = ("Watchdog detected idle assistant behavior on an unresolved Telegram job. Job: {0}. Reason: {1}. Your last turn did not contain a real action. Take one concrete task-advancing tool action immediately. Do not answer with status only. Do not use the message tool. Do not ask for a target. Do not write a local log or bookkeeping file as the main action. If blocked, state one blocker only." -f $PrimaryText, $Reason)
    agentId = "main"
    sessionKey = $SessionKey
    deliver = $false
    wakeMode = "now"
  } | ConvertTo-Json -Depth 10 -Compress

  $uri = "http://127.0.0.1:{0}{1}/agent" -f $port, $hookPath.TrimEnd("/")
  $response = Invoke-RestMethod -Method Post -Uri $uri -Headers @{ Authorization = "Bearer $hookToken" } -ContentType "application/json" -Body $body -TimeoutSec 30
  return $response
}

function Read-WatchdogState {
  $state = Read-JsonFile $StateFile
  if ($state) {
    return $state
  }

  return [pscustomobject]@{
    lastTriggeredMessageId = $null
    lastTriggeredAtMs = 0
    lastObservedMessageId = $null
    lastObservedAtMs = 0
  }
}

function Save-WatchdogState {
  param($State)
  Write-JsonFileNoBom -Path $StateFile -Value $State
}

function Invoke-WatchdogCycle {
  $heartbeat = Read-JsonFile $HeartbeatPath
  if (-not $heartbeat -or $heartbeat.enabled -ne $true) {
    Write-Log "Heartbeat mode disabled or missing; skipping cycle."
    return
  }

  $sessionKey = [string]$heartbeat.sessionKey
  if (-not $sessionKey) {
    Write-Log "heartbeat-mode.json has no sessionKey; skipping cycle."
    return
  }

  $sessionsStore = Read-JsonFile $SessionsPath
  if (-not $sessionsStore) {
    Write-Log "sessions.json missing or unreadable; skipping cycle."
    return
  }

  $sessionEntry = $sessionsStore.PSObject.Properties[$sessionKey].Value
  if (-not $sessionEntry) {
    Write-Log ("No session entry found for " + $sessionKey)
    return
  }

  $sessionFile = Resolve-SessionTranscriptFile -SessionKey $sessionKey -SessionEntry $sessionEntry
  if (-not $sessionFile) {
    $heartbeatGoal = ""
    if ($heartbeat.PSObject.Properties["goal"]) {
      $heartbeatGoal = [string]$heartbeat.goal
    }
    $null = Ensure-TaskListFromHeartbeat -GoalText $heartbeatGoal -Reason "Recovered from heartbeat state because the Telegram session transcript path was unavailable."
    return
  }

  $entries = @(Read-JsonLines $sessionFile)
  if ($entries.Count -eq 0) {
    Write-Log ("Session file is empty: " + $sessionFile)
    return
  }

  $messageEntries = @($entries | Where-Object { $_.type -eq "message" -and $_.message })
  if ($messageEntries.Count -eq 0) {
    Write-Log ("No message entries in session file: " + $sessionFile)
    return
  }

  $primaryEntry = Get-PrimaryUserEntry $messageEntries
  if (-not $primaryEntry) {
    Write-Log "No actionable Telegram user message found in transcript."
    return
  }

  $primaryText = Get-CleanUserText $primaryEntry
  $primaryTimestampMs = Get-EntryTimestampMs $primaryEntry

  $hasToolAfterPrimary = $false
  foreach ($entry in $messageEntries) {
    $entryMs = Get-EntryTimestampMs $entry
    if ($entryMs -lt $primaryTimestampMs) {
      continue
    }

    if (Test-AssistantHasToolCall $entry) {
      $hasToolAfterPrimary = $true
      break
    }

    if ($entry.message.role -eq "toolResult") {
      $hasToolAfterPrimary = $true
      break
    }
  }

  $null = Ensure-TaskListFromTranscript -PrimaryText $primaryText -PrimaryTimestampMs $primaryTimestampMs -HasToolAfterPrimary $hasToolAfterPrimary

  $lastMessage = $messageEntries[-1]
  $lastMessageId = [string]$lastMessage.id
  $lastRole = [string]$lastMessage.message.role
  $lastMessageHasToolCall = Test-AssistantHasToolCall $lastMessage
  $lastMessageText = Normalize-Spaces (Get-MessageText $lastMessage)
  $lastMessageAgeSeconds = [int][Math]::Floor((([DateTimeOffset]::UtcNow).ToUnixTimeMilliseconds() - (Get-EntryTimestampMs $lastMessage)) / 1000)

  $reason = $null
  if ($lastRole -eq "user" -and -not (Test-IsHookUserMessage $lastMessage) -and $lastMessageAgeSeconds -ge $IdleAfterUserSeconds) {
    $reason = "user-waiting-no-followup"
  } elseif ($lastRole -eq "assistant" -and -not $lastMessageHasToolCall -and -not (Test-IsHeartbeatAssistantText $lastMessageText) -and $lastMessageAgeSeconds -ge $IdleAfterAssistantSeconds) {
    $reason = "assistant-text-only-idle"
  }

  $state = Read-WatchdogState
  $nowMs = ([DateTimeOffset]::UtcNow).ToUnixTimeMilliseconds()
  $cooldownActive = $false
  if ($state.lastTriggeredMessageId -eq $lastMessageId -and ($nowMs - [long]$state.lastTriggeredAtMs) -lt ($RepeatCooldownSeconds * 1000L)) {
    $cooldownActive = $true
  }

  $state.lastObservedMessageId = $lastMessageId
  $state.lastObservedAtMs = $nowMs

  if (-not $reason) {
    Save-WatchdogState $state
    return
  }

  if ($cooldownActive) {
    Write-Log ("Idle detected but cooldown active for message " + $lastMessageId)
    Save-WatchdogState $state
    return
  }

  $response = Send-RecoveryHook -PrimaryText $primaryText -Reason $reason -SessionKey $sessionKey
  $state.lastTriggeredMessageId = $lastMessageId
  $state.lastTriggeredAtMs = $nowMs
  Save-WatchdogState $state

  $runId = if ($response -and $response.runId) { [string]$response.runId } else { "unknown" }
  Write-Log ("Recovery hook sent; reason={0}; runId={1}; lastRole={2}; lastText={3}" -f $reason, $runId, $lastRole, $lastMessageText)
}

if ($Mode -eq "once") {
  Invoke-WatchdogCycle
  exit 0
}

Write-Log "agent continuity watchdog loop started"
while (-not (Test-Path $StopFile)) {
  try {
    Invoke-WatchdogCycle
  } catch {
    Write-Log ("cycle failed: " + $_.Exception.Message)
  }
  Start-Sleep -Seconds $IntervalSeconds
}
Write-Log "agent continuity watchdog loop stopped"
exit 0
