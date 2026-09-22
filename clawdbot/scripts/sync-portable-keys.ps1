param(
  [Parameter(Mandatory = $true)]
  [string]$BasePath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "portable-secrets.ps1")

$keysDir = Join-Path $BasePath "clawdkeys"
$stateDir = Join-Path $BasePath "state\.openclaw"
$keysPath = Join-Path $keysDir "ENTER_KEYS_HERE.txt"
$configPath = Join-Path $stateDir "openclaw.json"
$authProfilesPath = Join-Path $stateDir "agents\main\agent\auth-profiles.json"
$policyPath = Join-Path $stateDir "access-policy.json"

if (-not (Test-Path $keysDir)) {
  return
}

function Read-LabeledKeyFile {
  param([string]$Path)

  $map = @{}
  if (-not (Test-Path $Path)) {
    return $map
  }

  $allowedLabels = @(Get-PortableSecretEditableLabels)

  foreach ($line in (Get-Content $Path)) {
    if ($null -eq $line) {
      continue
    }

    $trimmed = $line.Trim()
    if (-not $trimmed) {
      continue
    }

    if ($trimmed -notmatch '^\s*([^:]+?)\s*:\s*(.*)\s*$') {
      continue
    }

    $key = Normalize-PortableKeyLabel $matches[1]
    if ($allowedLabels -notcontains $key) {
      continue
    }

    $value = $matches[2].Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
      continue
    }

    $map[$key] = $value
  }

  return $map
}

function Set-OrAddProperty {
  param(
    $Object,
    [string]$Name,
    $Value
  )

  if ($null -eq $Object) {
    return
  }

  if ($Object.PSObject.Properties[$Name]) {
    $Object.$Name = $Value
  } else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
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

function New-DefaultPolicy {
  return [pscustomobject]@{
    enabled = $true
    delivery = "telegram"
    ownerPhone = ""
    codeLength = 6
    codeExpiresMinutes = 10
    unlockMinutes = 0
    maxAttempts = 3
  }
}

function Add-PortableSecretCandidate {
  param(
    [hashtable]$Map,
    [string]$Label,
    $Value
  )

  $normalized = Normalize-PortableKeyLabel $Label
  if (-not $normalized) {
    return
  }

  if ($Value -isnot [string]) {
    return
  }

  $trimmed = $Value.Trim()
  if (-not $trimmed) {
    return
  }

  $Map[$normalized] = $trimmed
}

function Add-PortableSecretCandidateFromArray {
  param(
    [hashtable]$Map,
    [string]$Label,
    $Value
  )

  if ($Value -is [System.Array] -and $Value.Count -gt 0) {
    Add-PortableSecretCandidate -Map $Map -Label $Label -Value ([string]$Value[0])
  }
}

function Write-PortableKeyTemplate {
  param(
    [string]$Path,
    [hashtable]$Secrets
  )

  $storedLabels = @(
    Get-PortableSecretEditableLabels |
      Where-Object { $Secrets.ContainsKey($_) -and (-not [string]::IsNullOrWhiteSpace([string]$Secrets[$_])) }
  )

  $storedSummary = if ($storedLabels.Count -gt 0) {
    ($storedLabels -join ", ")
  } else {
    "none"
  }

  $lines = @(
    "# Paste or update values here, then launch Portable Clawd."
    "# Values are imported into the protected local store and this file is cleared again after sync."
    "# Stored now: $storedSummary"
    ""
  )

  foreach ($label in (Get-PortableSecretEditableLabels)) {
    $lines += ($label + ":")
  }

  Write-Utf8NoBom -Path $Path -Content (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function ConvertFrom-Base64Url {
  param([string]$Value)

  if (-not $Value) {
    return $null
  }

  $normalized = $Value.Replace('-', '+').Replace('_', '/')
  switch ($normalized.Length % 4) {
    2 { $normalized += "==" }
    3 { $normalized += "=" }
  }

  try {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($normalized))
  } catch {
    return $null
  }
}

function Read-OpenAICodexAccessPayload {
  param([string]$AccessToken)

  if (-not $AccessToken) {
    return $null
  }

  $parts = $AccessToken.Split('.')
  if ($parts.Length -lt 2) {
    return $null
  }

  $json = ConvertFrom-Base64Url $parts[1]
  if (-not $json) {
    return $null
  }

  try {
    return ($json | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Resolve-OpenAICodexExpires {
  param(
    [string]$ExplicitValue,
    $AccessPayload
  )

  if ($ExplicitValue -and $ExplicitValue.Trim()) {
    $trimmed = $ExplicitValue.Trim()

    if ($trimmed -match '^\d{13,}$') {
      return [int64]$trimmed
    }

    if ($trimmed -match '^\d{10}$') {
      return ([int64]$trimmed * 1000)
    }

    try {
      return [DateTimeOffset]::Parse($trimmed).ToUnixTimeMilliseconds()
    } catch {
    }
  }

  if ($AccessPayload -and $null -ne $AccessPayload.exp) {
    try {
      return ([int64]$AccessPayload.exp * 1000)
    } catch {
    }
  }

  return $null
}

function Resolve-OpenAICodexAccountId {
  param(
    [string]$ExplicitValue,
    $AccessPayload
  )

  if ($ExplicitValue -and $ExplicitValue.Trim()) {
    return $ExplicitValue.Trim()
  }

  if ($AccessPayload) {
    $authBlock = $AccessPayload.PSObject.Properties['https://api.openai.com/auth']
    if ($authBlock -and $authBlock.Value) {
      $accountId = $authBlock.Value.PSObject.Properties['chatgpt_account_id']
      if ($accountId -and $accountId.Value) {
        return [string]$accountId.Value
      }
    }
  }

  return $null
}

$portableKeys = Read-LabeledKeyFile $keysPath

$config = [pscustomobject]@{}
if (Test-Path $configPath) {
  $config = ConvertTo-PortableJsonObject (Get-Content $configPath -Raw | ConvertFrom-Json)
}

$auth = $null
if (Test-Path $authProfilesPath) {
  $auth = Get-Content $authProfilesPath -Raw | ConvertFrom-Json
}

$policy = $null
if (Test-Path $policyPath) {
  $policy = Get-Content $policyPath -Raw | ConvertFrom-Json
}

$secretCandidates = @{}
foreach ($entry in $portableKeys.GetEnumerator()) {
  Add-PortableSecretCandidate -Map $secretCandidates -Label ([string]$entry.Key) -Value ([string]$entry.Value)
}

if ($config) {
  if ($config.tools -and $config.tools.web -and $config.tools.web.search -and $config.tools.web.search.gemini) {
    Add-PortableSecretCandidate -Map $secretCandidates -Label "google api" -Value $config.tools.web.search.gemini.apiKey
  }

  if ($config.channels -and $config.channels.telegram) {
    Add-PortableSecretCandidate -Map $secretCandidates -Label "telegram bot token" -Value $config.channels.telegram.botToken
    Add-PortableSecretCandidateFromArray -Map $secretCandidates -Label "telegram chat id" -Value $config.channels.telegram.allowFrom
  }
  if ($config.gateway -and $config.gateway.auth) {
    Add-PortableSecretCandidate -Map $secretCandidates -Label "_internal gateway auth token" -Value $config.gateway.auth.token
    Add-PortableSecretCandidate -Map $secretCandidates -Label "_internal gateway auth password" -Value $config.gateway.auth.password
  }
}

if ($auth -and $auth.profiles) {
  if ($auth.profiles.'openai:default') {
    Add-PortableSecretCandidate -Map $secretCandidates -Label "chat gpt api" -Value $auth.profiles.'openai:default'.key
  }

  if ($auth.profiles.'openai-codex:default') {
    Add-PortableSecretCandidate -Map $secretCandidates -Label "chat gpt oauth access token" -Value $auth.profiles.'openai-codex:default'.access
    Add-PortableSecretCandidate -Map $secretCandidates -Label "chat gpt oauth refresh token" -Value $auth.profiles.'openai-codex:default'.refresh
    Add-PortableSecretCandidate -Map $secretCandidates -Label "chat gpt oauth account id" -Value $auth.profiles.'openai-codex:default'.accountId
    if ($null -ne $auth.profiles.'openai-codex:default'.expires) {
      Add-PortableSecretCandidate -Map $secretCandidates -Label "chat gpt oauth expires" -Value ([string]$auth.profiles.'openai-codex:default'.expires)
    }
  }
}

if ($policy) {
  Add-PortableSecretCandidate -Map $secretCandidates -Label "telegram phone" -Value $policy.ownerPhone
}

if ($secretCandidates.Count -gt 0) {
  Set-PortableSecretValues -BasePath $BasePath -Values $secretCandidates | Out-Null
}

$portableSecrets = Resolve-PortableSecretValues -BasePath $BasePath

$googleApiRaw = [string]$portableSecrets["google api"]
$telegramTokenRaw = [string]$portableSecrets["telegram bot token"]
$telegramChatId = [string]$portableSecrets["telegram chat id"]
$telegramPhone = [string]$portableSecrets["telegram phone"]
$gptApiRaw = [string]$portableSecrets["chat gpt api"]
$codexOauthAccessRaw = [string]$portableSecrets["chat gpt oauth access token"]
$codexOauthRefreshRaw = [string]$portableSecrets["chat gpt oauth refresh token"]
$codexOauthAccountIdRaw = [string]$portableSecrets["chat gpt oauth account id"]
$codexOauthExpiresRaw = [string]$portableSecrets["chat gpt oauth expires"]
$gatewayAuthTokenRaw = [string]$portableSecrets["_internal gateway auth token"]
$gatewayAuthPasswordRaw = [string]$portableSecrets["_internal gateway auth password"]

$googleApiKey = ""
if ($googleApiRaw -match '([A-Za-z0-9_\-]{20,})') {
  $googleApiKey = $matches[1]
}

$resolvedGoogleApiKey = ""
if ($config -and $config.tools -and $config.tools.web -and $config.tools.web.search -and $config.tools.web.search.gemini) {
  $resolvedGoogleApiKey = Resolve-PortableSecretInputValue -Value $config.tools.web.search.gemini.apiKey -PortableSecrets $portableSecrets
}
if (-not $googleApiKey -and $resolvedGoogleApiKey -match '([A-Za-z0-9_\-]{20,})') {
  $googleApiKey = $matches[1]
}

$telegramToken = ""
if ($telegramTokenRaw -match '(\d{6,}:[A-Za-z0-9_-]{20,})') {
  $telegramToken = $matches[1]
}

$resolvedTelegramToken = ""
if ($config -and $config.channels -and $config.channels.telegram) {
  $resolvedTelegramToken = Resolve-PortableSecretInputValue -Value $config.channels.telegram.botToken -PortableSecrets $portableSecrets
}
if (-not $telegramToken -and $resolvedTelegramToken -match '(\d{6,}:[A-Za-z0-9_-]{20,})') {
  $telegramToken = $matches[1]
}

$telegramPhoneValue = ""
if ($telegramPhone -and $telegramPhone.Trim()) {
  $telegramPhoneValue = $telegramPhone.Trim()
}

$gptApiKey = ""
if ($gptApiRaw -match '(sk-[A-Za-z0-9_\-]+)') {
  $gptApiKey = $matches[1]
}

$resolvedGptApiKey = ""
if ($auth -and $auth.profiles -and $auth.profiles.'openai:default') {
  $resolvedGptApiKey = Resolve-PortableSecretInputValue -Value $auth.profiles.'openai:default'.keyRef -PortableSecrets $portableSecrets
}
if (-not $gptApiKey -and $resolvedGptApiKey -match '(sk-[A-Za-z0-9_\-]+)') {
  $gptApiKey = $matches[1]
}

$codexOauthAccess = ""
if ($codexOauthAccessRaw -match '^[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+$') {
  $codexOauthAccess = $codexOauthAccessRaw.Trim()
}

$codexOauthRefresh = ""
if ($codexOauthRefreshRaw -and $codexOauthRefreshRaw.Trim()) {
  $codexOauthRefresh = $codexOauthRefreshRaw.Trim()
}

$codexAccessPayload = Read-OpenAICodexAccessPayload $codexOauthAccess
$codexOauthExpires = Resolve-OpenAICodexExpires -ExplicitValue $codexOauthExpiresRaw -AccessPayload $codexAccessPayload
$codexOauthAccountId = Resolve-OpenAICodexAccountId -ExplicitValue $codexOauthAccountIdRaw -AccessPayload $codexAccessPayload

if ($config) {
  if (-not $config.channels) {
    $config | Add-Member -NotePropertyName channels -NotePropertyValue ([pscustomobject]@{})
  }
  if (-not $config.channels.telegram) {
    $config.channels | Add-Member -NotePropertyName telegram -NotePropertyValue ([pscustomobject]@{})
  }

  if (-not $config.tools) {
    $config | Add-Member -NotePropertyName tools -NotePropertyValue ([pscustomobject]@{})
  }
  if (-not $config.auth) {
    $config | Add-Member -NotePropertyName auth -NotePropertyValue ([pscustomobject]@{})
  }
  if (-not $config.auth.profiles) {
    $config.auth | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{})
  }
  if (-not $config.tools.web) {
    $config.tools | Add-Member -NotePropertyName web -NotePropertyValue ([pscustomobject]@{})
  }
  if (-not $config.tools.web.search) {
    $config.tools.web | Add-Member -NotePropertyName search -NotePropertyValue ([pscustomobject]@{})
  }
  if (-not $config.tools.web.search.gemini) {
    $config.tools.web.search | Add-Member -NotePropertyName gemini -NotePropertyValue ([pscustomobject]@{})
  }

  if ($googleApiKey) {
    $config.tools.web.search.enabled = $true
    $config.tools.web.search.provider = "gemini"
    $config.tools.web.search.gemini.apiKey = New-PortableSecretEnvRef -Label "google api"
  } else {
    $config.tools.web.search.enabled = $false
    $config.tools.web.search.provider = "gemini"
    $config.tools.web.search.gemini.apiKey = ""
  }

  if ($telegramToken) {
    $config.channels.telegram.enabled = $true
    $config.channels.telegram.botToken = New-PortableSecretEnvRef -Label "telegram bot token"
    $config.channels.telegram.groupPolicy = "disabled"
    $config.channels.telegram.streaming = "off"
    if ($config.channels.telegram.PSObject.Properties["timeoutSeconds"]) {
      $config.channels.telegram.timeoutSeconds = 60
    } else {
      $config.channels.telegram | Add-Member -NotePropertyName timeoutSeconds -NotePropertyValue 60
    }
  } else {
    $config.channels.telegram.enabled = $false
    if (-not (Test-PortableSecretRefConfigured -Value $config.channels.telegram.botToken)) {
      $config.channels.telegram.botToken = ""
    }
  }

  if ($telegramChatId) {
    $config.channels.telegram.dmPolicy = "allowlist"
    $config.channels.telegram.allowFrom = @($telegramChatId)
  } elseif ($telegramToken) {
    $config.channels.telegram.dmPolicy = "open"
    $config.channels.telegram.allowFrom = @("*")
  } else {
    $config.channels.telegram.dmPolicy = "allowlist"
    $config.channels.telegram.allowFrom = @()
  }

  if ($telegramChatId -and $config.agents -and $config.agents.defaults -and $config.agents.defaults.heartbeat) {
    $config.agents.defaults.heartbeat.to = $telegramChatId
    $config.agents.defaults.heartbeat.session = ("agent:main:telegram:direct:" + $telegramChatId)
  }

  if ($gptApiKey) {
    if (-not $config.auth.profiles.'openai:default') {
      $config.auth.profiles | Add-Member -NotePropertyName 'openai:default' -NotePropertyValue ([pscustomobject]@{
        provider = "openai"
        mode = "api_key"
      })
    } else {
      Set-OrAddProperty -Object $config.auth.profiles.'openai:default' -Name 'provider' -Value "openai"
      Set-OrAddProperty -Object $config.auth.profiles.'openai:default' -Name 'mode' -Value "api_key"
    }
  } else {
    $config.auth.profiles.PSObject.Properties.Remove('openai:default')
  }

  if ($codexOauthAccess -and $codexOauthRefresh) {
    if (-not $config.auth.profiles.'openai-codex:default') {
      $config.auth.profiles | Add-Member -NotePropertyName 'openai-codex:default' -NotePropertyValue ([pscustomobject]@{
        provider = "openai-codex"
        mode = "oauth"
      })
    } else {
      Set-OrAddProperty -Object $config.auth.profiles.'openai-codex:default' -Name 'provider' -Value "openai-codex"
      Set-OrAddProperty -Object $config.auth.profiles.'openai-codex:default' -Name 'mode' -Value "oauth"
    }
  } else {
    $config.auth.profiles.PSObject.Properties.Remove('openai-codex:default')
  }

  if (-not $config.gateway) {
    $config | Add-Member -NotePropertyName gateway -NotePropertyValue ([pscustomobject]@{})
  }
  if (-not $config.gateway.auth) {
    $config.gateway | Add-Member -NotePropertyName auth -NotePropertyValue ([pscustomobject]@{})
  }

  if ($gatewayAuthTokenRaw) {
    $config.gateway.auth.token = $gatewayAuthTokenRaw
  }

  if ($gatewayAuthPasswordRaw) {
    $config.gateway.auth.password = $gatewayAuthPasswordRaw
  }

  Write-JsonFileNoBom -Path $configPath -Value $config
}

if ($auth) {
  if (-not $auth.profiles) {
    $auth | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{})
  }

  if ($gptApiKey) {
    if (-not $auth.profiles.'openai:default') {
      $auth.profiles | Add-Member -NotePropertyName 'openai:default' -NotePropertyValue ([pscustomobject]@{
        type = "api_key"
        provider = "openai"
        keyRef = (New-PortableSecretEnvRef -Label "chat gpt api")
      })
    } else {
      $auth.profiles.'openai:default'.type = "api_key"
      $auth.profiles.'openai:default'.provider = "openai"
      Set-OrAddProperty -Object $auth.profiles.'openai:default' -Name 'keyRef' -Value (New-PortableSecretEnvRef -Label "chat gpt api")
      $auth.profiles.'openai:default'.PSObject.Properties.Remove('key')
    }
  } else {
    $auth.profiles.PSObject.Properties.Remove('openai:default')
  }

  if ($codexOauthAccess -and $codexOauthRefresh) {
    if (-not $auth.profiles.'openai-codex:default') {
      $auth.profiles | Add-Member -NotePropertyName 'openai-codex:default' -NotePropertyValue ([pscustomobject]@{
        type = "oauth"
        provider = "openai-codex"
        access = $codexOauthAccess
        refresh = $codexOauthRefresh
        expires = $codexOauthExpires
        accountId = $codexOauthAccountId
      })
    } else {
      Set-OrAddProperty -Object $auth.profiles.'openai-codex:default' -Name 'type' -Value "oauth"
      Set-OrAddProperty -Object $auth.profiles.'openai-codex:default' -Name 'provider' -Value "openai-codex"
      Set-OrAddProperty -Object $auth.profiles.'openai-codex:default' -Name 'access' -Value $codexOauthAccess
      Set-OrAddProperty -Object $auth.profiles.'openai-codex:default' -Name 'refresh' -Value $codexOauthRefresh
      if ($null -ne $codexOauthExpires) {
        Set-OrAddProperty -Object $auth.profiles.'openai-codex:default' -Name 'expires' -Value $codexOauthExpires
      } else {
        $auth.profiles.'openai-codex:default'.PSObject.Properties.Remove('expires')
      }
      if ($codexOauthAccountId) {
        Set-OrAddProperty -Object $auth.profiles.'openai-codex:default' -Name 'accountId' -Value $codexOauthAccountId
      } else {
        $auth.profiles.'openai-codex:default'.PSObject.Properties.Remove('accountId')
      }
    }

    if (-not $auth.lastGood) {
      $auth | Add-Member -NotePropertyName lastGood -NotePropertyValue ([pscustomobject]@{})
    }
    Set-OrAddProperty -Object $auth.lastGood -Name 'openai-codex' -Value 'openai-codex:default'
  } else {
    $auth.profiles.PSObject.Properties.Remove('openai-codex:default')
    if ($auth.lastGood) {
      $auth.lastGood.PSObject.Properties.Remove('openai-codex')
    }
  }

  Write-JsonFileNoBom -Path $authProfilesPath -Value $auth
}

if ($telegramPhoneValue -or (Test-Path $policyPath)) {
  if (-not $policy) {
    $policy = New-DefaultPolicy
  }

  $policy.unlockMinutes = 0

  if ($telegramPhoneValue) {
    $policy.ownerPhone = $telegramPhoneValue
  }

  Write-JsonFileNoBom -Path $policyPath -Value $policy
}

Write-PortableKeyTemplate -Path $keysPath -Secrets $portableSecrets
