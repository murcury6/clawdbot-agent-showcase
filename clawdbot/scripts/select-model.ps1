param(
  [Parameter(Mandatory = $true)]
  [string]$BasePath,
  [ValidateSet("auto", "online-first", "offline-first", "smart-cost")]
  [string]$SetMode,
  [switch]$Show
)

$ErrorActionPreference = "Stop"

$portableSecretsScript = Join-Path $PSScriptRoot "portable-secrets.ps1"
. $portableSecretsScript

$stateDir = Join-Path $BasePath "state\.openclaw"
$configPath = Join-Path $stateDir "openclaw.json"
$modePath = Join-Path $stateDir "model-mode.txt"
$selectionPath = Join-Path $stateDir "model-selection.json"
$onlineModel = "openai-codex/gpt-5.4"
$apiStrongModel = "openai/gpt-5.4"
$apiFallbackModel = "openai/gpt-5-mini"
$telegramDirectModel = $apiFallbackModel

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

function Split-ModelRef {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModelRef
  )

  $parts = $ModelRef.Split("/", 2)
  if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
    throw "Invalid model ref: $ModelRef"
  }

  [pscustomobject]@{
    provider = $parts[0].Trim()
    model = $parts[1].Trim()
  }
}

function Get-OllamaProbeModelId {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModelRef
  )

  $parts = Split-ModelRef -ModelRef $ModelRef
  if ($parts.provider -eq "ollama") {
    return $parts.model
  }

  return $ModelRef
}

function Remove-ObjectProperty {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Object,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if ($null -eq $Object) {
    return $false
  }

  $property = $Object.PSObject.Properties[$Name]
  if (-not $property) {
    return $false
  }

  $Object.PSObject.Properties.Remove($Name)
  return $true
}

function Clear-SessionRuntimeModelState {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Entry
  )

  $updated = $false
  foreach ($name in @(
      "modelProvider",
      "model",
      "contextTokens",
      "fallbackNoticeSelectedModel",
      "fallbackNoticeActiveModel",
      "fallbackNoticeReason"
    )) {
    if (Remove-ObjectProperty -Object $Entry -Name $name) {
      $updated = $true
    }
  }

  return $updated
}

function Ensure-SessionEntry {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Store,
    [Parameter(Mandatory = $true)]
    [string]$Key
  )

  $existing = $Store.PSObject.Properties[$Key]
  if ($existing) {
    return $existing.Value
  }

  $entry = [pscustomobject]@{
    sessionId = ([guid]::NewGuid().ToString())
    updatedAt = 0
  }
  $Store | Add-Member -NotePropertyName $Key -NotePropertyValue $entry
  return $entry
}

function Set-OrAddSessionProperty {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Entry,
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [object]$Value
  )

  $property = $Entry.PSObject.Properties[$Name]
  if ($property) {
    if ($property.Value -eq $Value) {
      return $false
    }
    $property.Value = $Value
    return $true
  }

  $Entry | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  return $true
}

function Sync-PortableSessionModelPreferences {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Config,
    [Parameter(Mandatory = $true)]
    [string]$StateDir,
    [Parameter(Mandatory = $true)]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [bool]$ApiConfigured,
    [Parameter(Mandatory = $true)]
    [string]$ApiFallbackModel,
    [Parameter(Mandatory = $true)]
    [string]$TelegramDirectModel,
    [Parameter(Mandatory = $true)]
    [string]$PrimaryModel
  )

  $sessionsPath = Join-Path $StateDir "agents\main\sessions\sessions.json"
  $sessionsDir = Split-Path -Parent $sessionsPath
  New-Item -ItemType Directory -Path $sessionsDir -Force | Out-Null

  $store = if (Test-Path $sessionsPath) {
    Get-Content $sessionsPath -Raw | ConvertFrom-Json
  } else {
    [pscustomobject]@{}
  }

  $updated = $false
  $primaryRef = Split-ModelRef -ModelRef $PrimaryModel
  $mainSessionKey = "agent:main:main"
  $mainEntry = $store.PSObject.Properties[$mainSessionKey]
  if ($mainEntry) {
    $mainProviderOverride = [string]$mainEntry.Value.providerOverride
    $mainModelOverride = [string]$mainEntry.Value.modelOverride
    $runtimeProvider = [string]$mainEntry.Value.modelProvider
    $runtimeModel = [string]$mainEntry.Value.model
    $runtimeStale = (
      [string]::IsNullOrWhiteSpace($mainProviderOverride) -and
      [string]::IsNullOrWhiteSpace($mainModelOverride) -and
      -not [string]::IsNullOrWhiteSpace($runtimeProvider) -and
      -not [string]::IsNullOrWhiteSpace($runtimeModel) -and
      ($runtimeProvider -ne $primaryRef.provider -or $runtimeModel -ne $primaryRef.model)
    )
    $hasFallbackNotice = (
      $mainEntry.Value.PSObject.Properties["fallbackNoticeSelectedModel"] -or
      $mainEntry.Value.PSObject.Properties["fallbackNoticeActiveModel"] -or
      $mainEntry.Value.PSObject.Properties["fallbackNoticeReason"]
    )
    if ($runtimeStale -or $hasFallbackNotice) {
      if (Clear-SessionRuntimeModelState -Entry $mainEntry.Value) {
        $updated = $true
      }
    }
  }

  $telegramChatId = $null
  if ($Config.channels -and $Config.channels.telegram -and $Config.channels.telegram.allowFrom) {
    $telegramChatId = @(
      $Config.channels.telegram.allowFrom |
        Where-Object {
          $value = [string]$_
          -not [string]::IsNullOrWhiteSpace($value) -and $value -ne "*"
        } |
        Select-Object -First 1
    )
    if ($telegramChatId) {
      $telegramChatId = [string]$telegramChatId
    }
  }
  if (-not $telegramChatId -and $Config.agents -and $Config.agents.defaults -and $Config.agents.defaults.heartbeat -and $Config.agents.defaults.heartbeat.to) {
    $telegramChatId = [string]$Config.agents.defaults.heartbeat.to
  }

  if ($telegramChatId) {
    $telegramSessionKey = "agent:main:telegram:direct:$telegramChatId"
    $directChatModel = Split-ModelRef -ModelRef $TelegramDirectModel
    $shouldPinTelegram = ($Mode -eq "smart-cost") -and ($TelegramDirectModel -ne $PrimaryModel)

    if ($shouldPinTelegram) {
      $telegramEntry = Ensure-SessionEntry -Store $store -Key $telegramSessionKey
      if (Set-OrAddSessionProperty -Entry $telegramEntry -Name "providerOverride" -Value $directChatModel.provider) {
        $updated = $true
      }
      if (Set-OrAddSessionProperty -Entry $telegramEntry -Name "modelOverride" -Value $directChatModel.model) {
        $updated = $true
      }
      if (Clear-SessionRuntimeModelState -Entry $telegramEntry) {
        $updated = $true
      }
    } else {
      $telegramEntryProperty = $store.PSObject.Properties[$telegramSessionKey]
      if ($telegramEntryProperty) {
        $telegramEntry = $telegramEntryProperty.Value
        if ([string]$telegramEntry.providerOverride -eq $directChatModel.provider -and [string]$telegramEntry.modelOverride -eq $directChatModel.model) {
          if (Remove-ObjectProperty -Object $telegramEntry -Name "providerOverride") {
            $updated = $true
          }
          if (Remove-ObjectProperty -Object $telegramEntry -Name "modelOverride") {
            $updated = $true
          }
          if (Clear-SessionRuntimeModelState -Entry $telegramEntry) {
            $updated = $true
          }
        }
      }
    }
  }

  if ($updated) {
    Write-JsonFileNoBom -Path $sessionsPath -Value $store -Depth 100
  }
}

$offlineTierSpecs = @(
  [pscustomobject]@{
    Tier = "10b"
    Model = "ollama/llama3.1:8b"
    ManifestPath = (Join-Path $BasePath "offline\ollama\models\manifests\registry.ollama.ai\library\llama3.1\8b")
    MinTotalGiB = 24.0
    MinFreeGiB = 10.0
  },
  [pscustomobject]@{
    Tier = "7b"
    Model = "ollama/qwen2.5:7b"
    ManifestPath = (Join-Path $BasePath "offline\ollama\models\manifests\registry.ollama.ai\library\qwen2.5\7b")
    MinTotalGiB = 18.0
    MinFreeGiB = 7.0
  },
  [pscustomobject]@{
    Tier = "3b"
    Model = "ollama/qwen2.5:3b"
    ManifestPath = (Join-Path $BasePath "offline\ollama\models\manifests\registry.ollama.ai\library\qwen2.5\3b")
    MinTotalGiB = 12.0
    MinFreeGiB = 4.0
  },
  [pscustomobject]@{
    Tier = "1b"
    Model = "ollama/llama3.2:1b"
    ManifestPath = (Join-Path $BasePath "offline\ollama\models\manifests\registry.ollama.ai\library\llama3.2\1b")
    MinTotalGiB = 8.0
    MinFreeGiB = 2.0
  }
)

function Test-TcpEndpoint {
  param(
    [string]$HostName,
    [int]$Port,
    [int]$TimeoutMs = 1200
  )

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $async = $client.BeginConnect($HostName, $Port, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
      return $false
    }
    $client.EndConnect($async) | Out-Null
    return $true
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function Invoke-JsonProbe {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Method,
    [Parameter(Mandatory = $true)]
    [string]$Uri,
    [object]$Body = $null,
    [hashtable]$Headers = @{},
    [int]$TimeoutSec = 10
  )

  try {
    $params = @{
      Method = $Method
      Uri = $Uri
      TimeoutSec = $TimeoutSec
      ErrorAction = "Stop"
    }

    if ($Headers.Count -gt 0) {
      $params.Headers = $Headers
    }

    if ($null -ne $Body) {
      $params.ContentType = "application/json"
      $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }

    $response = Invoke-RestMethod @params
    return [pscustomobject]@{
      ok = $true
      response = $response
      reason = "ok"
    }
  } catch {
    $reason = [string]$_.Exception.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
      $reason = [string]$_.ErrorDetails.Message
    }

    if ($reason.Length -gt 220) {
      $reason = $reason.Substring(0, 220) + "..."
    }

    return [pscustomobject]@{
      ok = $false
      response = $null
      reason = $reason
    }
  }
}

function Get-ApiKeyHealth {
  param([string]$ApiKey)

  if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    return [pscustomobject]@{
      ok = $false
      reason = "missing API key"
    }
  }

  $probe = Invoke-JsonProbe -Method "Get" -Uri "https://api.openai.com/v1/models" -Headers @{ Authorization = "Bearer $ApiKey" } -TimeoutSec 10
  if ($probe.ok) {
    return [pscustomobject]@{
      ok = $true
      reason = "API key accepted"
    }
  }

  return [pscustomobject]@{
    ok = $false
    reason = $probe.reason
  }
}

function Get-CodexHealth {
  param(
    [object]$Profile
  )

  if ($null -eq $Profile) {
    return [pscustomobject]@{
      ok = $false
      reason = "missing OAuth profile"
    }
  }

  $access = [string]$Profile.access
  $refresh = [string]$Profile.refresh
  if ([string]::IsNullOrWhiteSpace($access) -or [string]::IsNullOrWhiteSpace($refresh)) {
    return [pscustomobject]@{
      ok = $false
      reason = "missing OAuth tokens"
    }
  }

  $expires = $null
  if ($null -ne $Profile.expires) {
    try {
      $expires = [int64]$Profile.expires
    } catch {
    }
  }

  if ($expires -and $expires -le ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())) {
    return [pscustomobject]@{
      ok = $false
      reason = "OAuth token expired"
    }
  }

  if (-not (Test-TcpEndpoint -HostName "chatgpt.com" -Port 443)) {
    return [pscustomobject]@{
      ok = $false
      reason = "chatgpt.com unreachable"
    }
  }

  return [pscustomobject]@{
    ok = $true
    reason = "OAuth profile present and reachable"
  }
}

function Test-OllamaModelHealth {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,
    [Parameter(Mandatory = $true)]
    [string]$Model
  )

  if (-not (Test-TcpEndpoint -HostName "127.0.0.1" -Port 11500)) {
    return [pscustomobject]@{
      ok = $false
      reason = "Ollama port is closed"
    }
  }

  # Keep startup light: verify the local Ollama server responds without forcing a model load.
  $probe = Invoke-JsonProbe -Method "Get" -Uri ($BaseUrl.TrimEnd("/") + "/api/tags") -TimeoutSec 5
  if ($probe.ok) {
    return [pscustomobject]@{
      ok = $true
      reason = "Ollama reachable"
    }
  }

  return [pscustomobject]@{
    ok = $false
    reason = $probe.reason
  }
}

function Get-OfflineTierState {
  param(
    [double]$TotalGiB,
    [double]$FreeGiB
  )

  $tiers = foreach ($spec in $offlineTierSpecs) {
    $present = Test-Path $spec.ManifestPath
    $safe = $present -and $TotalGiB -ge $spec.MinTotalGiB -and $FreeGiB -ge $spec.MinFreeGiB
    $health = if ($present) {
      Test-OllamaModelHealth -BaseUrl "http://127.0.0.1:11500" -Model $spec.Model
    } else {
      [pscustomobject]@{
        ok = $false
        reason = "model manifest missing"
      }
    }
    [pscustomobject]@{
      tier = $spec.Tier
      model = $spec.Model
      manifestPath = $spec.ManifestPath
      present = $present
      safe = $safe
      healthy = [bool]$health.ok
      healthReason = $health.reason
      minTotalGiB = $spec.MinTotalGiB
      minFreeGiB = $spec.MinFreeGiB
    }
  }

  $available = @($tiers | Where-Object { $_.present })
  $healthy = @($tiers | Where-Object { $_.healthy })
  $safe = @($tiers | Where-Object { $_.safe })
  $safeHealthy = @($tiers | Where-Object { $_.safe -and $_.healthy })

  [pscustomobject]@{
    tiers = $tiers
    anyReady = $available.Count -gt 0
    anyHealthy = $healthy.Count -gt 0
    anySafe = $safe.Count -gt 0
    selectedAvailable = if ($available.Count -gt 0) { $available[0] } else { $null }
    selectedHealthy = if ($healthy.Count -gt 0) { $healthy[0] } else { $null }
    selectedSafe = Get-PreferredSafeOfflineTier -SafeTiers $safe
    selectedSafeHealthy = if ($safeHealthy.Count -gt 0) { $safeHealthy[0] } else { $null }
  }
}

function Get-TierLabel {
  param($Tier)

  if ($null -eq $Tier) {
    return "none"
  }
  return ($Tier.tier + " (" + $Tier.model + ")")
}

function Get-PreferredSafeOfflineTier {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$SafeTiers
  )

  if ($SafeTiers.Count -eq 0) {
    return $null
  }

  foreach ($tierName in @("3b", "1b", "7b", "10b")) {
    $match = @($SafeTiers | Where-Object { $_.tier -eq $tierName } | Select-Object -First 1)
    if ($match.Count -gt 0) {
      return $match[0]
    }
  }

  return $SafeTiers[0]
}

function Get-SystemMemorySnapshot {
  $totalBytes = $null
  $freeBytes = $null
  $source = "fallback"

  try {
    $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $totalBytes = [double]$computerSystem.TotalPhysicalMemory
    $freeBytes = [double]$operatingSystem.FreePhysicalMemory * 1KB
    $source = "cim"
  } catch {
  }

  if (-not $totalBytes -or -not $freeBytes) {
    try {
      $computerSystem = Get-WmiObject Win32_ComputerSystem -ErrorAction Stop
      $operatingSystem = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
      $totalBytes = [double]$computerSystem.TotalPhysicalMemory
      $freeBytes = [double]$operatingSystem.FreePhysicalMemory * 1KB
      $source = "wmi"
    } catch {
    }
  }

  if (-not $totalBytes -or -not $freeBytes) {
    try {
      Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop | Out-Null
      $computerInfo = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
      $totalBytes = [double]$computerInfo.TotalPhysicalMemory
      $freeBytes = [double]$computerInfo.AvailablePhysicalMemory
      $source = "computerinfo"
    } catch {
    }
  }

  if (-not $totalBytes -or -not $freeBytes) {
    # Conservative fallback so small-memory machines do not get oversized local models.
    $totalBytes = 8GB
    $freeBytes = 2GB
  }

  return [pscustomobject]@{
    totalGiB = [math]::Round(($totalBytes / 1GB), 1)
    freeGiB = [math]::Round(($freeBytes / 1GB), 1)
    source = $source
  }
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

if ($SetMode) {
  Set-Content $modePath $SetMode -Encoding ASCII
}

if (-not (Test-Path $modePath)) {
  Set-Content $modePath "auto" -Encoding ASCII
}

$mode = ((Get-Content $modePath -Raw).Trim().ToLowerInvariant())
if ($mode -notin @("auto", "online-first", "offline-first", "smart-cost")) {
  $mode = "auto"
  Set-Content $modePath $mode -Encoding ASCII
}

if (-not (Test-Path $configPath)) {
  throw "Missing portable config: $configPath"
}

$memorySnapshot = Get-SystemMemorySnapshot
$totalGiB = $memorySnapshot.totalGiB
$freeGiB = $memorySnapshot.freeGiB

$offlineState = Get-OfflineTierState -TotalGiB $totalGiB -FreeGiB $freeGiB
$offlineReady = $offlineState.anyReady
$offlineSafe = $offlineState.anySafe
$offlineAvailableTier = $offlineState.selectedAvailable
$offlineHealthyTier = $offlineState.selectedHealthy
$offlineSafeTier = $offlineState.selectedSafe
$offlineSafeHealthyTier = $offlineState.selectedSafeHealthy
$offlineModelAvailable = if ($offlineAvailableTier) { $offlineAvailableTier.model } else { $null }
$offlineModelHealthy = if ($offlineHealthyTier) { $offlineHealthyTier.model } else { $null }
$offlineModelSafe = if ($offlineSafeTier) { $offlineSafeTier.model } else { $null }
$offlinePreferredTier = if ($offlineSafeHealthyTier) { $offlineSafeHealthyTier } elseif ($offlineSafeTier) { $offlineSafeTier } elseif ($offlineHealthyTier) { $offlineHealthyTier } else { $offlineAvailableTier }
$offlinePreferredModel = if ($offlinePreferredTier) { $offlinePreferredTier.model } else { $null }
$offlineFallbackModel = if ($offlineModelSafe) { $offlineModelSafe } elseif ($offlinePreferredModel) { $offlinePreferredModel } else { $null }

function Get-OfflineFallbackModels {
  param($PreferredTier)

  if ($PreferredTier) {
    return @($PreferredTier.model)
  }

  return @()
}

function Get-FallbackChain {
  param(
    [string[]]$Models
  )

  $fallbacks = @()
  foreach ($model in $Models) {
    if (-not $model) {
      continue
    }
    if ($fallbacks -contains $model) {
      continue
    }
    $fallbacks += $model
  }

  return @($fallbacks)
}

$config = ConvertTo-PortableJsonObject (Get-Content $configPath -Raw | ConvertFrom-Json)
$authProfilesPath = Join-Path $stateDir "agents\main\agent\auth-profiles.json"
$authStore = [pscustomobject]@{}
if (Test-Path $authProfilesPath) {
  $authStore = ConvertTo-PortableJsonObject (Get-Content $authProfilesPath -Raw | ConvertFrom-Json)
}
$portableSecrets = Resolve-PortableSecretValues -BasePath $BasePath
$authProfiles = @()
if ($authStore.profiles) {
  $authProfiles = @($authStore.profiles.PSObject.Properties.Name)
} elseif ($config.auth -and $config.auth.profiles) {
  $authProfiles = @($config.auth.profiles.PSObject.Properties.Name)
}
$codexConfigured = $authProfiles -contains "openai-codex:default"
$apiConfigured = $authProfiles -contains "openai:default"
$apiProfile = $null
if ($authStore.profiles -and $authStore.profiles.'openai:default') {
  $apiProfile = $authStore.profiles.'openai:default'
} elseif ($config.auth -and $config.auth.profiles -and $config.auth.profiles.'openai:default') {
  $apiProfile = $config.auth.profiles.'openai:default'
}
$apiKey = $null
if ($apiConfigured -and $apiProfile) {
  $apiKey = Resolve-PortableSecretInputValue -Value $apiProfile.keyRef -PortableSecrets $portableSecrets
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    $apiKey = Resolve-PortableSecretInputValue -Value $apiProfile.key -PortableSecrets $portableSecrets
  }
}

$codexProfile = $null
if ($codexConfigured -and $authStore.profiles -and $authStore.profiles.'openai-codex:default') {
  $codexProfile = $authStore.profiles.'openai-codex:default'
} elseif ($codexConfigured -and $config.auth -and $config.auth.profiles) {
  $codexProfile = $config.auth.profiles.'openai-codex:default'
}

$apiHealth = Get-ApiKeyHealth -ApiKey $apiKey
$codexHealth = Get-CodexHealth -Profile $codexProfile
if ($codexHealth.ok -and $authStore.usageStats -and $authStore.usageStats.'openai-codex:default' -and $authStore.usageStats.'openai-codex:default'.cooldownUntil) {
  try {
    $codexCooldownUntil = [int64]$authStore.usageStats.'openai-codex:default'.cooldownUntil
    if ($codexCooldownUntil -gt ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())) {
      $codexHealth = [pscustomobject]@{
        ok = $false
        reason = 'OAuth profile is cooling down after rate limiting'
      }
    }
  } catch {
  }
}
$apiHealthy = $apiConfigured -and $apiHealth.ok
$codexHealthy = $codexConfigured -and $codexHealth.ok
$cloudReachable = $codexHealthy -or $apiHealthy

$telegramDirectModel = if ($apiHealthy) {
  $apiFallbackModel
} elseif ($codexHealthy) {
  $onlineModel
} elseif ($offlinePreferredModel) {
  $offlinePreferredModel
} else {
  $null
}

$subagentPrimary = $null
$subagentFallbacks = @()
$reason = ""
switch ($mode) {
  "smart-cost" {
    if ($offlinePreferredTier -and $offlinePreferredTier.healthy) {
      $primary = $offlinePreferredModel
      $fallbacks = Get-FallbackChain @(
        $(if ($apiHealthy) { $apiFallbackModel }),
        $(if ($codexHealthy) { $onlineModel })
      )

      if ($apiHealthy) {
        $subagentPrimary = $apiStrongModel
        $subagentFallbacks = Get-FallbackChain @(
          $apiFallbackModel,
          $offlinePreferredModel,
          $(if ($codexHealthy) { $onlineModel })
        )
      } elseif ($codexHealthy) {
        $subagentPrimary = $onlineModel
        $subagentFallbacks = Get-FallbackChain @(
          $offlinePreferredModel
        )
      } else {
        $subagentPrimary = $offlinePreferredModel
        $subagentFallbacks = @()
      }

      $reason = if ($offlineSafeTier) {
        "smart-cost mode selected offline tier " + (Get-TierLabel $offlinePreferredTier) + " for routine work; spawned sub-agents are pointed at " + $subagentPrimary + " for harder tasks"
      } else {
        "smart-cost mode selected offline tier " + (Get-TierLabel $offlinePreferredTier) + " for routine work even though free RAM is below the preferred threshold; spawned sub-agents are pointed at " + $subagentPrimary + " for harder tasks"
      }
    } elseif ($apiHealthy) {
      $primary = $apiFallbackModel
      $fallbacks = Get-FallbackChain @(
        $(if ($codexHealthy) { $onlineModel }),
        $offlinePreferredModel
      )
      $subagentPrimary = $apiStrongModel
      $subagentFallbacks = Get-FallbackChain @(
        $apiFallbackModel,
        $(if ($codexHealthy) { $onlineModel }),
        $offlinePreferredModel
      )
      $reason = if ($codexHealthy) {
        "smart-cost mode could not use a bundled offline tier, so GPT-5.4 mini became the fast Telegram-safe primary model and a stronger cloud model is reserved for harder spawned work"
      } else {
        "smart-cost mode could not use a bundled offline tier, so GPT-5.4 mini became the primary model and GPT-5.4 is reserved for harder spawned work"
      }
    } elseif ($codexHealthy) {
      $primary = $onlineModel
      $fallbacks = Get-FallbackChain @(
        $(if ($apiHealthy) { $apiFallbackModel }),
        $offlineFallbackModel
      )
      $subagentPrimary = $onlineModel
      $subagentFallbacks = Get-FallbackChain @(
        $(if ($apiHealthy) { $apiFallbackModel }),
        $offlineFallbackModel
      )
      $reason = "smart-cost mode could not use a bundled offline tier or GPT nano, so ChatGPT OAuth became the primary model"
    } elseif ($offlineReady) {
      $primary = $offlinePreferredModel
      $fallbacks = Get-FallbackChain @(
        $(if ($apiConfigured) { $apiFallbackModel }),
        $(if ($codexConfigured) { $onlineModel })
      )
      $subagentPrimary = if ($apiHealthy) { $apiStrongModel } elseif ($codexHealthy) { $onlineModel } else { $offlinePreferredModel }
      $subagentFallbacks = Get-FallbackChain @(
        $(if ($apiHealthy) { $apiFallbackModel }),
        $(if ($codexHealthy) { $onlineModel })
      )
      $reason = if ($offlineSafeTier) {
        "smart-cost mode selected the best available offline tier " + (Get-TierLabel $offlinePreferredTier) + " because cloud providers were not healthy"
      } else {
        "smart-cost mode selected the best available offline tier " + (Get-TierLabel $offlinePreferredTier) + " because cloud providers were not healthy and local RAM is below the preferred threshold"
      }
    } elseif ($apiConfigured -or $codexConfigured) {
      if ($apiConfigured) {
        $primary = $apiFallbackModel
        $fallbacks = @()
        $subagentPrimary = $apiStrongModel
        $subagentFallbacks = Get-FallbackChain @($apiFallbackModel)
        $reason = "smart-cost mode fell back to GPT-5.4 mini because no healthy provider answered the probe"
      } else {
        $primary = $onlineModel
        $fallbacks = @()
        $subagentPrimary = $onlineModel
        $subagentFallbacks = @()
        $reason = "smart-cost mode fell back to ChatGPT OAuth because no healthy provider answered the probe"
      }
    } else {
      throw "No online auth is configured and no offline model tiers are bundled."
    }
  }
  "offline-first" {
    if ($offlinePreferredTier -and $offlinePreferredTier.healthy) {
      $primary = $offlinePreferredModel
      $fallbacks = Get-FallbackChain @(
        $(if ($apiHealthy) { $apiFallbackModel }),
        $(if ($codexHealthy) { $onlineModel })
      )
      $reason = if ($offlineSafeTier) {
        "offline-first mode selected offline tier " + (Get-TierLabel $offlinePreferredTier)
      } else {
        "offline-first mode forced offline tier " + (Get-TierLabel $offlinePreferredTier) + " even though free RAM is below the preferred threshold"
      }
    } elseif ($offlineReady) {
      $primary = $offlinePreferredModel
      $fallbacks = Get-FallbackChain @(
        $(if ($apiHealthy) { $apiFallbackModel }),
        $(if ($codexHealthy) { $onlineModel })
      )
      $reason = "offline-first mode had no healthy local tier, so it selected the best available offline model anyway"
    } elseif ($apiHealthy) {
      $primary = $apiFallbackModel
      $fallbacks = Get-FallbackChain @(
        $(if ($codexHealthy) { $onlineModel })
      )
      $reason = "offline-first requested, but no offline tier was healthy; GPT nano API mode was selected"
    } elseif ($codexHealthy) {
      $primary = $onlineModel
      $fallbacks = @()
      $reason = "offline-first requested, but only Codex OAuth is healthy"
    } elseif ($apiConfigured) {
      $primary = $apiFallbackModel
      $fallbacks = @()
      $reason = "offline-first requested, but no offline tier is bundled on the USB; GPT nano API mode was selected"
    } elseif ($codexConfigured) {
      $primary = $onlineModel
      $fallbacks = @()
      $reason = "offline-first requested, but only Codex auth is configured"
    } else {
      throw "No offline model tiers are available and no online auth is configured."
    }
  }
  "online-first" {
    if ($codexHealthy) {
      $primary = $onlineModel
      $fallbacks = Get-FallbackChain @(
        $(if ($apiHealthy) { $apiFallbackModel }),
        $offlineFallbackModel
      )
      $reason = if ($apiHealthy) {
        "online-first mode selected ChatGPT OAuth because it is healthy; API and offline fallback models are armed behind it"
      } elseif ($offlinePreferredModel) {
        "online-first mode selected ChatGPT OAuth because it is healthy; offline fallback is armed behind it"
      } else {
        "online-first mode selected ChatGPT OAuth because it is healthy"
      }
    } elseif ($apiHealthy) {
      $primary = $apiFallbackModel
      $fallbacks = Get-FallbackChain @($offlineFallbackModel)
      $reason = if ($offlineFallbackModel) {
        "online-first mode selected GPT nano because ChatGPT OAuth is unhealthy; offline fallback is armed behind it"
      } else {
        "online-first mode selected GPT nano API mode"
      }
    } elseif ($offlinePreferredTier -and $offlinePreferredTier.healthy) {
      $primary = $offlinePreferredModel
      $fallbacks = @()
      $reason = if ($offlineSafeTier) {
        "online-first mode selected offline tier " + (Get-TierLabel $offlinePreferredTier) + " because ChatGPT OAuth and API are unhealthy"
      } else {
        "online-first mode selected offline tier " + (Get-TierLabel $offlinePreferredTier) + " because ChatGPT OAuth and API are unhealthy; local performance may vary on low-memory PCs"
      }
    } elseif ($offlineReady) {
      $primary = $offlinePreferredModel
      $fallbacks = @()
      $reason = if ($offlineSafeTier) {
        "online-first mode selected offline tier " + (Get-TierLabel $offlinePreferredTier) + " because ChatGPT OAuth and API are unavailable"
      } else {
        "online-first mode selected offline tier " + (Get-TierLabel $offlinePreferredTier) + " because ChatGPT OAuth and API are unavailable; local performance may vary on low-memory PCs"
      }
    } elseif ($codexConfigured) {
      $primary = $onlineModel
      $fallbacks = Get-FallbackChain @(
        $(if ($apiConfigured) { $apiFallbackModel }),
        $offlineFallbackModel
      )
      $reason = if ($apiConfigured) {
        "online-first mode selected ChatGPT OAuth because it is configured even though the reachability probe failed; API fallback is armed behind it"
      } else {
        "online-first mode selected ChatGPT OAuth because it is configured even though the reachability probe failed"
      }
    } elseif ($apiConfigured) {
      $primary = $apiFallbackModel
      $fallbacks = @()
      $reason = "online-first mode selected GPT nano because it is configured even though the reachability probe failed"
    } else {
      throw "No online auth is configured and no offline model tiers are bundled."
    }
  }
  default {
    if ($codexHealthy) {
      $primary = $onlineModel
      $fallbacks = Get-FallbackChain @(
        $(if ($apiHealthy) { $apiFallbackModel }),
        $offlineFallbackModel
      )
      $reason = if ($apiHealthy) {
        "auto mode selected ChatGPT OAuth because it is healthy; API and offline fallback models are armed behind it"
      } elseif ($offlinePreferredModel) {
        "auto mode selected ChatGPT OAuth because it is healthy; offline fallback is armed behind it"
      } else {
        "auto mode selected ChatGPT OAuth because it is healthy"
      }
    } elseif ($apiHealthy) {
      $primary = $apiFallbackModel
      $fallbacks = Get-FallbackChain @($offlineFallbackModel)
      $reason = if ($offlineFallbackModel) {
        "auto mode selected GPT nano because ChatGPT OAuth is unhealthy; offline fallback is armed behind it"
      } else {
        "auto mode selected GPT nano because it is the first healthy configured online model"
      }
    } elseif ($offlinePreferredTier -and $offlinePreferredTier.healthy) {
      $primary = $offlinePreferredModel
      $fallbacks = @()
      $reason = if ($offlineSafeTier) {
        "auto mode selected offline tier " + (Get-TierLabel $offlinePreferredTier) + " because ChatGPT OAuth and API are unhealthy"
      } else {
        "auto mode selected offline tier " + (Get-TierLabel $offlinePreferredTier) + " because ChatGPT OAuth and API are unhealthy; local performance may vary on low-memory PCs"
      }
    } elseif ($offlineReady) {
      $primary = $offlinePreferredModel
      $fallbacks = @()
      $reason = if ($offlineSafeTier) {
        "auto mode selected offline tier " + (Get-TierLabel $offlinePreferredTier) + " because ChatGPT OAuth and API are unavailable"
      } else {
        "auto mode selected offline tier " + (Get-TierLabel $offlinePreferredTier) + " because ChatGPT OAuth and API are unavailable; local performance may vary on low-memory PCs"
      }
    } elseif ($codexConfigured) {
      $primary = $onlineModel
      $fallbacks = Get-FallbackChain @(
        $(if ($apiConfigured) { $apiFallbackModel }),
        $offlineFallbackModel
      )
      $reason = if ($apiConfigured) {
        "auto mode selected ChatGPT OAuth because it is configured even though the health probe failed; API fallback is armed behind it"
      } else {
        "auto mode selected ChatGPT OAuth because it is configured even though the health probe failed"
      }
    } elseif ($apiConfigured) {
      $primary = $apiFallbackModel
      $fallbacks = @()
      $reason = "auto mode selected GPT nano because it is configured even though the health probe failed"
    } else {
      throw "No online auth is configured and no offline model tiers are bundled."
    }
  }
}

if (-not $telegramDirectModel) {
  $telegramDirectModel = $primary
}

if (-not $config.agents) {
  $config | Add-Member -NotePropertyName agents -NotePropertyValue ([pscustomobject]@{})
}
if (-not $config.agents.defaults) {
  $config.agents | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{})
}
if (-not $config.agents.defaults.model) {
  $config.agents.defaults | Add-Member -NotePropertyName model -NotePropertyValue ([pscustomobject]@{})
}

$config.agents.defaults.model.primary = $primary
$config.agents.defaults.model.fallbacks = @($fallbacks)

if (-not $config.agents.defaults.heartbeat) {
  $config.agents.defaults | Add-Member -NotePropertyName heartbeat -NotePropertyValue ([pscustomobject]@{})
}
$config.agents.defaults.heartbeat.model = $telegramDirectModel

if (-not $config.agents.defaults.subagents) {
  $config.agents.defaults | Add-Member -NotePropertyName subagents -NotePropertyValue ([pscustomobject]@{})
}

if ($subagentPrimary) {
  $subagentModel = [pscustomobject]@{
    primary = $subagentPrimary
    fallbacks = @($subagentFallbacks)
  }
  if ($config.agents.defaults.subagents.PSObject.Properties["model"]) {
    $config.agents.defaults.subagents.model = $subagentModel
  } else {
    $config.agents.defaults.subagents | Add-Member -NotePropertyName model -NotePropertyValue $subagentModel
  }
} elseif ($config.agents.defaults.subagents.PSObject.Properties["model"]) {
  $config.agents.defaults.subagents.PSObject.Properties.Remove("model")
}

Write-JsonFileNoBom -Path $configPath -Value $config
Sync-PortableSessionModelPreferences -Config $config -StateDir $stateDir -Mode $mode -ApiConfigured $apiConfigured -ApiFallbackModel $apiFallbackModel -TelegramDirectModel $telegramDirectModel -PrimaryModel $primary

$selection = [pscustomobject]@{
  mode = $mode
  evaluatedAt = (Get-Date).ToString("o")
  totalMemoryGiB = $totalGiB
  freeMemoryGiB = $freeGiB
  memoryProbe = $memorySnapshot.source
  offlineManifestPresent = $offlineReady
  offlineSafe = $offlineSafe
  offlineTierAvailable = if ($offlineAvailableTier) { $offlineAvailableTier.tier } else { $null }
  offlineTierHealthy = if ($offlineHealthyTier) { $offlineHealthyTier.tier } else { $null }
  offlineTierSafe = if ($offlineSafeTier) { $offlineSafeTier.tier } else { $null }
  availableOfflineTiers = @($offlineState.tiers | Where-Object { $_.present } | ForEach-Object { $_.tier })
  healthyOfflineTiers = @($offlineState.tiers | Where-Object { $_.healthy } | ForEach-Object { $_.tier })
  safeOfflineTiers = @($offlineState.tiers | Where-Object { $_.safe } | ForEach-Object { $_.tier })
  healthySafeOfflineTiers = @($offlineState.tiers | Where-Object { $_.safe -and $_.healthy } | ForEach-Object { $_.tier })
  codexConfigured = $codexConfigured
  apiConfigured = $apiConfigured
  codexHealthy = $codexHealthy
  apiHealthy = $apiHealthy
  cloudReachable = $cloudReachable
  primary = $primary
  fallbacks = @($fallbacks)
  subagentPrimary = $subagentPrimary
  subagentFallbacks = @($subagentFallbacks)
  reason = $reason
  roles = [pscustomobject]@{
    routine = $primary
    hardTask = if ($subagentPrimary) { $subagentPrimary } else { $primary }
    telegramDirect = $telegramDirectModel
  }
  health = [pscustomobject]@{
    codex = [pscustomobject]@{
      configured = $codexConfigured
      healthy = $codexHealthy
      reason = $codexHealth.reason
    }
    api = [pscustomobject]@{
      configured = $apiConfigured
      healthy = $apiHealthy
      reason = $apiHealth.reason
    }
    offline = @(
      $offlineState.tiers | ForEach-Object {
        [pscustomobject]@{
          tier = $_.tier
          model = $_.model
          present = $_.present
          healthy = $_.healthy
          safe = $_.safe
          reason = $_.healthReason
        }
      }
    )
  }
}

Write-JsonFileNoBom -Path $selectionPath -Value $selection -Depth 20

if ($Show) {
  Write-Output ("Mode: " + $selection.mode)
  Write-Output ("Total RAM GiB: " + $selection.totalMemoryGiB)
  Write-Output ("Free RAM GiB: " + $selection.freeMemoryGiB)
  Write-Output ("Offline tier available: " + ($selection.offlineTierAvailable -replace "^$", "none"))
  Write-Output ("Offline tier safe: " + ($selection.offlineTierSafe -replace "^$", "none"))
  Write-Output ("Bundled offline tiers: " + (($selection.availableOfflineTiers -join ", ") -replace "^$", "(none)"))
  Write-Output ("Healthy offline tiers: " + (($selection.healthyOfflineTiers -join ", ") -replace "^$", "(none)"))
  Write-Output ("Safe offline tiers on this PC: " + (($selection.safeOfflineTiers -join ", ") -replace "^$", "(none)"))
  Write-Output ("Healthy + safe offline tiers: " + (($selection.healthySafeOfflineTiers -join ", ") -replace "^$", "(none)"))
  Write-Output ("Codex configured: " + $selection.codexConfigured)
  Write-Output ("Codex healthy: " + $selection.codexHealthy)
  Write-Output ("GPT API configured: " + $selection.apiConfigured)
  Write-Output ("GPT API healthy: " + $selection.apiHealthy)
  Write-Output ("Cloud reachable: " + $selection.cloudReachable)
  Write-Output ("Primary: " + $selection.primary)
  Write-Output ("Fallbacks: " + (($selection.fallbacks -join ", ") -replace "^$", "(none)"))
  Write-Output ("Hard-task model: " + (($selection.subagentPrimary) -replace "^$", "(inherits primary)"))
  Write-Output ("Hard-task fallbacks: " + (($selection.subagentFallbacks -join ", ") -replace "^$", "(none)"))
  Write-Output ("Telegram direct: " + (($selection.roles.telegramDirect) -replace "^$", "(none)"))
  Write-Output ("Reason: " + $selection.reason)
}
