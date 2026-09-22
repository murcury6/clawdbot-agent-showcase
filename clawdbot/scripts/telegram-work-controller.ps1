param(
  [string]$BasePath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  [ValidateSet("once", "run")]
  [string]$Mode = "once",
  [int]$IntervalSeconds = 15,
  [int]$IdleSeconds = 20,
  [int]$NoTaskActionSeconds = 45,
  [int]$ToolStallSeconds = 90,
  [int]$RepeatCooldownSeconds = 75
)

$ErrorActionPreference = "Stop"

$BasePath = (Resolve-Path $BasePath).Path
$RunDir = Join-Path $BasePath "run"
$LogDir = Join-Path $BasePath "logs"
$WorkspaceDir = Join-Path $BasePath "workspace"
$StateDir = Join-Path $BasePath "state\.openclaw"
$StopFile = Join-Path $RunDir "telegram-work-controller.stop"
$StateFile = Join-Path $RunDir "telegram-work-controller-state.json"
$LogFile = Join-Path $LogDir "telegram-work-controller.log"
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

  if ($text -match '^Keep working\. Continue the current task without asking what to do next\.') {
    return $true
  }

  return $false
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

function Test-IsHeartbeatAssistantText {
  param($Entry)

  if (-not $Entry -or $Entry.type -ne "message" -or -not $Entry.message -or $Entry.message.role -ne "assistant") {
    return $false
  }

  $text = Normalize-Text (Get-MessageText $Entry)
  if (-not $text) {
    return $false
  }

  if ($text -eq "HEARTBEAT_OK") {
    return $true
  }

  if ($text -match '^(Current Jobs|Working Now):') {
    return $true
  }

  return $false
}

function Get-LatestRealUserControl {
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

function Test-TaskListHasActiveWork {
  param($TaskList)

  if (-not $TaskList) {
    return $false
  }

  if ($TaskList.currentJobId -and -not [string]::IsNullOrWhiteSpace([string]$TaskList.currentJobId)) {
    return $true
  }

  if ($TaskList.doingNow -and @($TaskList.doingNow).Count -gt 0) {
    return $true
  }

  if ($TaskList.jobQueue -and @($TaskList.jobQueue).Count -gt 0) {
    return $true
  }

  return $false
}

function Get-TaskListUpdatedAtMs {
  param($TaskList)

  if (-not $TaskList -or -not $TaskList.updatedAt) {
    return 0L
  }

  try {
    return ([DateTimeOffset]::Parse([string]$TaskList.updatedAt).ToUnixTimeMilliseconds())
  } catch {
    return 0L
  }
}

function Get-QueueCandidateJob {
  param($TaskList)

  if (-not $TaskList -or -not $TaskList.jobQueue) {
    return $null
  }

  $queue = @(
    $TaskList.jobQueue |
      Where-Object {
        $id = [string]$_.id
        -not [string]::IsNullOrWhiteSpace($id)
      }
  )
  if ($queue.Count -eq 0) {
    return $null
  }

  $doing = @($queue | Where-Object { [string]$_.status -eq "doing" })
  if ($doing.Count -gt 0) {
    return $doing[0]
  }

  return $queue[0]
}

function Repair-TaskListAssignment {
  param($TaskList)

  if (-not (Test-TaskListHasActiveWork $TaskList)) {
    return $null
  }

  $candidate = Get-QueueCandidateJob -TaskList $TaskList
  if (-not $candidate) {
    return $null
  }

  $candidateId = [string]$candidate.id
  $currentJobId = [string]$TaskList.currentJobId
  $queueIds = @($TaskList.jobQueue | ForEach-Object { [string]$_.id })

  $needsRepair = [string]::IsNullOrWhiteSpace($currentJobId) -or ($queueIds -notcontains $currentJobId)
  if (-not $needsRepair) {
    return $null
  }

  $TaskList.currentJobId = $candidateId
  $TaskList.updatedAt = (Get-Date).ToString("o")
  return ("Repaired currentJobId to " + $candidateId + " so the queue stays assigned.")
}

function Get-LatestConcreteActionInfo {
  param([object[]]$Entries)

  for ($i = $Entries.Count - 1; $i -ge 0; $i--) {
    $entry = $Entries[$i]
    $timestampMs = [int64](Get-EntryTimestampMs $entry)
    if ($timestampMs -le 0) {
      continue
    }

    if ($entry.type -eq "message" -and $entry.message) {
      $role = [string]$entry.message.role
      if ($role -eq "assistant" -and (Test-AssistantHasToolCall $entry)) {
        return [pscustomobject]@{
          timestampMs = $timestampMs
          kind = "assistant-tool-call"
        }
      }

      if ($role -eq "toolResult") {
        return [pscustomobject]@{
          timestampMs = $timestampMs
          kind = "tool-result"
        }
      }
    }
  }

  return [pscustomobject]@{
    timestampMs = 0L
    kind = "none"
  }
}

function Get-OrCreateState {
  $state = Read-JsonFile $StateFile
  if (-not $state) {
    $state = [pscustomobject]@{
      paused = $false
      lastDispatchAtMs = 0
      lastDispatchForEntryTimestampMs = 0
      lastDispatchKey = ""
    }
  }

  if (-not $state.PSObject.Properties["paused"]) {
    $state | Add-Member -NotePropertyName paused -NotePropertyValue $false
  }
  if (-not $state.PSObject.Properties["lastDispatchAtMs"]) {
    $state | Add-Member -NotePropertyName lastDispatchAtMs -NotePropertyValue 0
  }
  if (-not $state.PSObject.Properties["lastDispatchForEntryTimestampMs"]) {
    $state | Add-Member -NotePropertyName lastDispatchForEntryTimestampMs -NotePropertyValue 0
  }
  if (-not $state.PSObject.Properties["lastDispatchKey"]) {
    $state | Add-Member -NotePropertyName lastDispatchKey -NotePropertyValue ""
  }

  return $state
}

function Get-HeartbeatPrompt {
  $localNow = Get-Date
  $utcNow = [DateTime]::UtcNow
  $localStamp = $localNow.ToString("dddd, MMMM d, yyyy '-' h:mm tt")
  $utcStamp = $utcNow.ToString("yyyy-MM-dd HH:mm")
  $timeZoneId = [System.TimeZoneInfo]::Local.Id
  $heartbeatFilePath = ((Join-Path $WorkspaceDir "HEARTBEAT.md") -replace '\\', '/')

  return @"
Read HEARTBEAT.md if it exists (workspace context). Follow it strictly. Do not infer or repeat old tasks from prior chats. If nothing needs attention, reply HEARTBEAT_OK.
When reading HEARTBEAT.md, use workspace file $heartbeatFilePath (exact case). Do not read docs/heartbeat.md.
Current time: $localStamp ($timeZoneId) / $utcStamp UTC
"@.Trim()
}

function Send-HiddenHeartbeat {
  param(
    [string]$HooksToken,
    [string]$SessionKey,
    [string]$PromptText = ""
  )

  $uri = "http://127.0.0.1:18789/hooks/agent"
  $body = @{
    message = if ([string]::IsNullOrWhiteSpace($PromptText)) { Get-HeartbeatPrompt } else { $PromptText }
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

function Get-MonitorPrompt {
  param(
    [string]$Reason,
    [string]$JobTitle,
    [double]$StallSeconds
  )

  $basePrompt = Get-HeartbeatPrompt
  $safeTitle = if ([string]::IsNullOrWhiteSpace($JobTitle)) { "Unassigned queued work" } else { $JobTitle }
  $stallText = [math]::Round($StallSeconds, 1)

  return @"
$basePrompt
Monitor alert: unfinished queue work exists but no verified task-advancing action has been observed for about $stallText seconds.
Reason: $Reason
Current job: $safeTitle
If currentJobId is missing or stale, repair it from task-list.json.
Then take one concrete task-advancing tool action immediately.
Do not answer with status only.
Do not spend this turn only rewriting bookkeeping files unless that directly unblocks the active job.
"@.Trim()
}

function Invoke-Cycle {
  $heartbeat = Read-JsonFile $HeartbeatPath
  $taskList = Read-JsonFile $TaskListPath
  $config = Read-JsonFile $ConfigPath
  $sessions = Read-JsonFile $SessionsPath
  if (-not $heartbeat -or -not $config -or -not $sessions) {
    return
  }

  $state = Get-OrCreateState

  $sessionKey = [string]$heartbeat.sessionKey
  if ([string]::IsNullOrWhiteSpace($sessionKey) -and $config.agents -and $config.agents.defaults -and $config.agents.defaults.heartbeat) {
    $sessionKey = [string]$config.agents.defaults.heartbeat.session
  }
  if ([string]::IsNullOrWhiteSpace($sessionKey)) {
    return
  }

  $sessionEntry = $sessions.PSObject.Properties[$sessionKey]
  if (-not $sessionEntry -or -not $sessionEntry.Value -or -not $sessionEntry.Value.sessionFile) {
    return
  }

  $entries = @(Read-JsonLines ([string]$sessionEntry.Value.sessionFile))
  if ($entries.Count -eq 0) {
    return
  }

  $control = Get-LatestRealUserControl $entries
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

  if (-not $heartbeat.enabled) {
    return
  }

  if (-not (Test-TaskListHasActiveWork $taskList)) {
    return
  }

  $assignmentRepairMessage = Repair-TaskListAssignment -TaskList $taskList
  if ($assignmentRepairMessage) {
    Write-JsonFileNoBom -Path $TaskListPath -Value $taskList
    Write-Log $assignmentRepairMessage
  }

  $latestEntry = $entries[-1]
  $latestEntryMs = [int64](Get-EntryTimestampMs $latestEntry)
  if ($latestEntryMs -le 0) {
    return
  }

  $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $idleMs = $nowMs - $latestEntryMs
  $latestConcreteAction = Get-LatestConcreteActionInfo -Entries $entries
  $latestConcreteActionMs = [int64]$latestConcreteAction.timestampMs
  $taskListUpdatedMs = Get-TaskListUpdatedAtMs -TaskList $taskList
  $stallAnchorMs = if ($latestConcreteActionMs -gt 0) {
    $latestConcreteActionMs
  } elseif ($taskListUpdatedMs -gt 0) {
    $taskListUpdatedMs
  } else {
    $latestEntryMs
  }
  $stallMs = $nowMs - $stallAnchorMs

  $queueCandidate = Get-QueueCandidateJob -TaskList $taskList
  $queueCandidateTitle = if ($queueCandidate -and $queueCandidate.title) { [string]$queueCandidate.title } else { [string]$taskList.goal }

  $dispatchReason = ""
  if ([string]::IsNullOrWhiteSpace([string]$taskList.currentJobId) -and $queueCandidate) {
    $dispatchReason = "queue-unassigned"
  } elseif ((Test-IsHeartbeatAssistantText $latestEntry) -and $stallMs -ge ([int64]$NoTaskActionSeconds * 1000L)) {
    $dispatchReason = "status-only-stall"
  } elseif ($stallMs -ge ([int64]$NoTaskActionSeconds * 1000L)) {
    $dispatchReason = "task-action-stalled"
  } else {
    if ($idleMs -lt ([int64]$IdleSeconds * 1000L)) {
      return
    }

    if ((Test-AssistantHasToolCall $latestEntry) -and $idleMs -lt ([int64]$ToolStallSeconds * 1000L)) {
      return
    }

    $dispatchReason = "transcript-idle"
  }

  $sinceDispatchMs = $nowMs - [int64]$state.lastDispatchAtMs
  $dispatchKey = ($dispatchReason + "|" + [string]$latestEntryMs + "|" + [string]$stallAnchorMs + "|" + [string]$taskList.currentJobId)
  if (
    $state.lastDispatchKey -eq $dispatchKey -and
    $sinceDispatchMs -lt ([int64]$RepeatCooldownSeconds * 1000L)
  ) {
    return
  }

  $hooksToken = [string]$config.hooks.token
  if ([string]::IsNullOrWhiteSpace($hooksToken)) {
    return
  }

  $promptText = if ($dispatchReason -eq "transcript-idle") {
    ""
  } else {
    Get-MonitorPrompt -Reason $dispatchReason -JobTitle $queueCandidateTitle -StallSeconds ($stallMs / 1000.0)
  }

  Send-HiddenHeartbeat -HooksToken $hooksToken -SessionKey $sessionKey -PromptText $promptText
  $state.lastDispatchAtMs = $nowMs
  $state.lastDispatchForEntryTimestampMs = $latestEntryMs
  $state.lastDispatchKey = $dispatchKey
  Write-JsonFileNoBom -Path $StateFile -Value $state

  $idleSecondsRounded = [math]::Round(($idleMs / 1000.0), 1)
  $stallSecondsRounded = [math]::Round(($stallMs / 1000.0), 1)
  Write-Log ("Queued work-controller prompt for " + $sessionKey + "; reason=" + $dispatchReason + "; transcriptIdle=" + $idleSecondsRounded + "s; actionStall=" + $stallSecondsRounded + "s; wakeMode=now")
}

if ($Mode -eq "once") {
  Invoke-Cycle
  exit 0
}

Write-Log "telegram work controller loop started"
while ($true) {
  if (Test-Path $StopFile) {
    Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
    Write-Log "telegram work controller loop stopped"
    exit 0
  }

  try {
    Invoke-Cycle
  } catch {
    Write-Log ("cycle error: " + $_.Exception.Message)
  }

  Start-Sleep -Seconds $IntervalSeconds
}
