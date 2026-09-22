param(
  [Parameter(Mandatory = $true)]
  [string]$BasePath
)

$ErrorActionPreference = "Stop"

$workspaceDir = Join-Path $BasePath "workspace"
$editableDir = Join-Path $BasePath "EDIT_AI_HERE"
$editableMemoryDir = Join-Path $editableDir "memory"
$workspaceMemoryDir = Join-Path $workspaceDir "memory"

$trackedFiles = @(
  "AGENTS.md",
  "SOUL.md",
  "TOOLS.md",
  "USER.md",
  "IDENTITY.md",
  "MEMORY.md",
  "HEARTBEAT.md"
)

$defaultFileContents = @{
  "MEMORY.md" = @"
# MEMORY.md

- Put durable facts here that Clawd should remember across sessions.
- Keep short-term scratch notes in memory\YYYY-MM-DD.md instead.
"@
}

function Sync-File {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination
  )

  if (-not (Test-Path $Source)) {
    return $false
  }

  New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
  Copy-Item -Path $Source -Destination $Destination -Force
  return $true
}

New-Item -ItemType Directory -Path $editableDir -Force | Out-Null
New-Item -ItemType Directory -Path $editableMemoryDir -Force | Out-Null
New-Item -ItemType Directory -Path $workspaceDir -Force | Out-Null
New-Item -ItemType Directory -Path $workspaceMemoryDir -Force | Out-Null

$readmePath = Join-Path $editableDir "README.txt"
$readmeText = @"
Edit these files to change how Clawd behaves.

Files in this folder are the easy-to-find source copies.
The launcher syncs them into the real workspace before OpenClaw starts.

What each file does:
- AGENTS.md: hard rules, workflow, startup behavior
- SOUL.md: personality, tone, vibe
- TOOLS.md: tool usage guidance
- USER.md: your preferences and standing requests
- IDENTITY.md: the AI's self-description, name, avatar, vibe
- MEMORY.md: long-term facts you want it to remember
- HEARTBEAT.md: only used when heartbeat mode is enabled
- memory\*.md: dated notes the agent can recall later

If you want to shape the assistant, start with SOUL.md, USER.md, and AGENTS.md.
"@
Set-Content -Path $readmePath -Value $readmeText -Encoding UTF8

foreach ($name in $trackedFiles) {
  $editablePath = Join-Path $editableDir $name
  $workspacePath = Join-Path $workspaceDir $name

  if (-not (Test-Path $editablePath) -and (Test-Path $workspacePath)) {
    Copy-Item -Path $workspacePath -Destination $editablePath -Force
    continue
  }

  if (-not (Test-Path $editablePath) -and $defaultFileContents.ContainsKey($name)) {
    Set-Content -Path $editablePath -Value $defaultFileContents[$name] -Encoding UTF8
  }
}

$editableMemoryNotes = @()
if (Test-Path $workspaceMemoryDir) {
  $editableMemoryNotes = @(Get-ChildItem -Path $editableMemoryDir -File -Filter *.md -ErrorAction SilentlyContinue)
  if ($editableMemoryNotes.Count -eq 0) {
    Get-ChildItem -Path $workspaceMemoryDir -File -Filter *.md -ErrorAction SilentlyContinue | ForEach-Object {
      Copy-Item -Path $_.FullName -Destination (Join-Path $editableMemoryDir $_.Name) -Force
    }
  }
}

foreach ($name in $trackedFiles) {
  $editablePath = Join-Path $editableDir $name
  $workspacePath = Join-Path $workspaceDir $name
  Sync-File -Source $editablePath -Destination $workspacePath | Out-Null
}

Get-ChildItem -Path $editableMemoryDir -File -Filter *.md -ErrorAction SilentlyContinue | ForEach-Object {
  Sync-File -Source $_.FullName -Destination (Join-Path $workspaceMemoryDir $_.Name) | Out-Null
}
