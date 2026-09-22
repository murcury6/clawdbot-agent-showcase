param(
  [Parameter(Mandatory = $true)]
  [string]$BasePath,
  [switch]$LockOnly
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "portable-secrets.ps1")

$stateDir = Join-Path $BasePath "state\.openclaw"
$keysPath = Join-Path $BasePath "clawdkeys\ENTER_KEYS_HERE.txt"
$configPath = Join-Path $stateDir "openclaw.json"
$policyPath = Join-Path $stateDir "access-policy.json"
$sessionPath = Join-Path $stateDir "access-session.json"
$launchUnlockEnvName = "PORTABLE_CLAWD_UNLOCK_OK"

function New-DefaultPolicy {
  [pscustomobject]@{
    enabled = $true
    delivery = "telegram"
    ownerPhone = ""
    codeLength = 6
    codeExpiresMinutes = 10
    unlockMinutes = 0
    maxAttempts = 3
  }
}

function Save-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )

  $json = $Value | ConvertTo-Json -Depth 20
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, ($json + [Environment]::NewLine), $encoding)
}

function Get-Sha256Hex {
  param([string]$Text)

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function New-NumericCode {
  param([int]$Length)

  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $chars = for ($idx = 0; $idx -lt $Length; $idx++) {
      $buffer = New-Object byte[] 1
      $rng.GetBytes($buffer)
      [string]($buffer[0] % 10)
    }
    return (-join $chars)
  } finally {
    $rng.Dispose()
  }
}

function Send-TelegramCode {
  param(
    [string]$BotToken,
    [string]$ChatId,
    [string]$Code,
    [int]$Minutes
  )

  $uri = "https://api.telegram.org/bot$BotToken/sendMessage"
  $text = "Clawd unlock code: $Code`nExpires in $Minutes minutes."
  $body = @{
    chat_id = $ChatId
    text = $text
  }

  Invoke-RestMethod -Method Post -Uri $uri -Body $body | Out-Null
}

function Read-PortableKeyFileValue {
  param(
    [string]$Path,
    [string]$Label
  )

  if (-not (Test-Path $Path)) {
    return ""
  }

  $normalizedLabel = Normalize-PortableKeyLabel $Label
  if (-not $normalizedLabel) {
    return ""
  }

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

    if ((Normalize-PortableKeyLabel $matches[1]) -ne $normalizedLabel) {
      continue
    }

    return ([string]$matches[2]).Trim()
  }

  return ""
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

New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

if (-not (Test-Path $policyPath)) {
  Save-JsonFile -Path $policyPath -Value (New-DefaultPolicy)
}

$policy = Get-Content $policyPath -Raw | ConvertFrom-Json
if (-not $policy.enabled) {
  exit 0
}

if ([Environment]::GetEnvironmentVariable($launchUnlockEnvName) -eq "1") {
  exit 0
}

if ($LockOnly) {
  if (Test-Path $sessionPath) {
    Remove-Item $sessionPath -Force
  }
  Write-Host "Portable Clawd is locked."
  exit 0
}

$session = if (Test-Path $sessionPath) {
  Get-Content $sessionPath -Raw | ConvertFrom-Json
} else {
  [pscustomobject]@{}
}

$now = Get-Date
if ([int]$policy.unlockMinutes -gt 0 -and $session.unlockedUntil) {
  $unlockedUntil = [datetime]$session.unlockedUntil
  if ($unlockedUntil -gt $now) {
    exit 0
  }
}

if (-not (Test-Path $configPath)) {
  throw "Missing OpenClaw config: $configPath"
}

$config = ConvertTo-PortableJsonObject (Get-Content $configPath -Raw | ConvertFrom-Json)
$telegram = $null
if ($config.channels) {
  $telegram = $config.channels.telegram
}
$portableSecrets = Resolve-PortableSecretValues -BasePath $BasePath
$botToken = ""
if ($telegram) {
  $botToken = Resolve-PortableSecretInputValue -Value $telegram.botToken -PortableSecrets $portableSecrets
}
if ([string]::IsNullOrWhiteSpace($botToken)) {
  $botToken = Read-PortableKeyFileValue -Path $keysPath -Label "telegram bot token"
}
if (-not $telegram -or -not $telegram.enabled) {
  Write-Host "Telegram unlock delivery is disabled. Skipping the local unlock check for this launch."
  exit 0
}
if ([string]::IsNullOrWhiteSpace($botToken)) {
  Write-Host "Telegram bot token is missing from the portable secret store. Skipping the local unlock check for this launch."
  exit 0
}

$chatId = $null
if ($telegram.allowFrom -and $telegram.allowFrom.Count -gt 0 -and $telegram.allowFrom[0] -ne "*") {
  $chatId = [string]$telegram.allowFrom[0]
}
if ([string]::IsNullOrWhiteSpace($chatId)) {
  $chatId = Read-PortableKeyFileValue -Path $keysPath -Label "telegram chat id"
}
if ([string]::IsNullOrWhiteSpace($chatId)) {
  Write-Host "No Telegram chat id is configured for unlock delivery. Skipping the local unlock check for this launch."
  exit 0
}

$code = New-NumericCode -Length ([int]$policy.codeLength)
$expiresAt = $now.AddMinutes([int]$policy.codeExpiresMinutes)

$session = [pscustomobject]@{
  pendingCodeHash = (Get-Sha256Hex -Text $code)
  pendingCodeExpiresAt = $expiresAt.ToString("o")
  unlockedUntil = $null
  lastCodeSentAt = $now.ToString("o")
  delivery = "telegram"
  deliveryTarget = $chatId
}
Save-JsonFile -Path $sessionPath -Value $session

try {
  Send-TelegramCode -BotToken $botToken -ChatId $chatId -Code $code -Minutes ([int]$policy.codeExpiresMinutes)
} catch {
  throw "Unable to send unlock code to Telegram. Internet access is required for this step. $($_.Exception.Message)"
}

$phoneSuffix = if ($policy.ownerPhone) { " for phone " + [string]$policy.ownerPhone } else { "" }
Write-Host ("A Clawd unlock code was sent to your Telegram phone" + $phoneSuffix + ".")

for ($attempt = 1; $attempt -le [int]$policy.maxAttempts; $attempt++) {
  $entered = Read-Host "Enter the unlock code"
  $latest = Get-Content $sessionPath -Raw | ConvertFrom-Json
  if (-not $latest.pendingCodeExpiresAt -or ([datetime]$latest.pendingCodeExpiresAt) -lt (Get-Date)) {
    throw "The unlock code expired. Run the launcher again to request a new code."
  }
  if ((Get-Sha256Hex -Text $entered) -eq $latest.pendingCodeHash) {
    $unlockMinutes = [int]$policy.unlockMinutes
    $unlockedUntil = if ($unlockMinutes -gt 0) {
      (Get-Date).AddMinutes($unlockMinutes)
    } else {
      Get-Date
    }
    $updated = [pscustomobject]@{
      pendingCodeHash = $null
      pendingCodeExpiresAt = $null
      unlockedUntil = $unlockedUntil.ToString("o")
      lastCodeSentAt = $latest.lastCodeSentAt
      delivery = $latest.delivery
      deliveryTarget = $latest.deliveryTarget
      lastUnlockAt = (Get-Date).ToString("o")
    }
    Save-JsonFile -Path $sessionPath -Value $updated
    if ($unlockMinutes -gt 0) {
      Write-Host ("Portable Clawd unlocked until " + $unlockedUntil.ToString("g"))
    } else {
      Write-Host "Portable Clawd unlocked for this launch."
    }
    exit 0
  }

  if ($attempt -lt [int]$policy.maxAttempts) {
    Write-Host "Incorrect code. Try again."
  }
}

throw "Incorrect unlock code."
