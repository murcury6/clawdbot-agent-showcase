param(
  [Parameter(Mandatory = $true)]
  [string]$BasePath
)

$ErrorActionPreference = "Stop"

$stateDir = Join-Path $BasePath "state\.openclaw"
$configPath = Join-Path $stateDir "openclaw.json"
$workspacePath = Join-Path $BasePath "workspace"
$modelsPath = Join-Path $stateDir "agents\main\agent\models.json"
$sessionsPath = Join-Path $stateDir "agents\main\sessions\sessions.json"
$jobsPath = Join-Path $stateDir "cron\jobs.json"
$ollamaBaseUrl = "http://127.0.0.1:11500"

function New-HexToken {
  param([int]$ByteCount = 24)

  $bytes = New-Object byte[] $ByteCount
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  return ([System.BitConverter]::ToString($bytes)).Replace("-", "").ToLowerInvariant()
}

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

function ConvertTo-PortableJsonObject {
  param($Value)

  if ($null -eq $Value) {
    return [pscustomobject]@{}
  }

  if ($Value -is [string] -or $Value -is [System.ValueType] -or $Value -is [System.Array]) {
    return [pscustomobject]@{}
  }

  return $Value
}

if (-not (Test-Path $configPath)) {
  throw "Missing portable config: $configPath"
}

$config = ConvertTo-PortableJsonObject (Get-Content $configPath -Raw | ConvertFrom-Json)

if (-not $config.env) {
  $config | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{})
}
$config.env.OLLAMA_API_KEY = "ollama-local"

if (-not $config.models) {
  $config | Add-Member -NotePropertyName models -NotePropertyValue ([pscustomobject]@{})
}
if (-not $config.models.providers) {
  $config.models | Add-Member -NotePropertyName providers -NotePropertyValue ([pscustomobject]@{})
}
if (-not $config.models.providers.ollama) {
  $config.models.providers | Add-Member -NotePropertyName ollama -NotePropertyValue ([pscustomobject]@{})
}
$config.models.providers.ollama.baseUrl = $ollamaBaseUrl
$config.models.providers.ollama.apiKey = "ollama-local"

if (-not $config.agents) {
  $config | Add-Member -NotePropertyName agents -NotePropertyValue ([pscustomobject]@{})
}
if (-not $config.agents.defaults) {
  $config.agents | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{})
}
$config.agents.defaults.workspace = $workspacePath

if (-not $config.gateway) {
  $config | Add-Member -NotePropertyName gateway -NotePropertyValue ([pscustomobject]@{})
}
$config.gateway.mode = "local"
if (-not $config.gateway.auth) {
  $config.gateway | Add-Member -NotePropertyName auth -NotePropertyValue ([pscustomobject]@{})
}

$gatewayToken = [string]$config.gateway.auth.token
if ([string]::IsNullOrWhiteSpace($gatewayToken)) {
  $gatewayToken = New-HexToken
  $config.gateway.auth.token = $gatewayToken
}

if (-not $config.hooks) {
  $config | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}

$config.hooks.enabled = $true
if ([string]::IsNullOrWhiteSpace([string]$config.hooks.path)) {
  $config.hooks.path = "/hooks"
}

$hooksToken = [string]$config.hooks.token
if ([string]::IsNullOrWhiteSpace($hooksToken) -or $hooksToken -eq $gatewayToken) {
  do {
    $hooksToken = New-HexToken
  } while ($hooksToken -eq $gatewayToken)

  $config.hooks.token = $hooksToken
}

$config.hooks.allowedAgentIds = @("main")
$config.hooks.allowRequestSessionKey = $true
$config.hooks.allowedSessionKeyPrefixes = @("agent:main:", "hook:")

Write-JsonFileNoBom -Path $configPath -Value $config

if (Test-Path $modelsPath) {
  $models = Get-Content $modelsPath -Raw | ConvertFrom-Json
  if ($models.providers -and $models.providers.ollama) {
    $models.providers.ollama.baseUrl = $ollamaBaseUrl
    if (-not $models.providers.ollama.apiKey) {
      $models.providers.ollama | Add-Member -NotePropertyName apiKey -NotePropertyValue "OLLAMA_API_KEY"
    }
    Write-JsonFileNoBom -Path $modelsPath -Value $models
  }
}

if (-not (Test-Path $sessionsPath)) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $sessionsPath) -Force | Out-Null
  Write-Utf8NoBom -Path $sessionsPath -Content ("{}" + [Environment]::NewLine)
}

if (-not (Test-Path $jobsPath)) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $jobsPath) -Force | Out-Null
  Write-Utf8NoBom -Path $jobsPath -Content ('{"version":1,"jobs":[]}' + [Environment]::NewLine)
}
