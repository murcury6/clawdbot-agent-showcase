$script:PortableSecretEditableLabels = @(
  "google api",
  "chat gpt api",
  "chat gpt oauth access token",
  "chat gpt oauth refresh token",
  "chat gpt oauth account id",
  "chat gpt oauth expires",
  "telegram bot token",
  "telegram chat id",
  "telegram phone"
)

$script:PortableSecretInternalLabels = @(
  "_internal gateway auth token",
  "_internal gateway auth password"
)

$script:PortableSecretEnvNames = @{
  "google api" = "PORTABLE_CLAWD_GOOGLE_API_KEY"
  "chat gpt api" = "PORTABLE_CLAWD_OPENAI_API_KEY"
  "telegram bot token" = "PORTABLE_CLAWD_TELEGRAM_BOT_TOKEN"
  "_internal gateway auth token" = "PORTABLE_CLAWD_GATEWAY_TOKEN"
  "_internal gateway auth password" = "PORTABLE_CLAWD_GATEWAY_PASSWORD"
}

function Normalize-PortableKeyLabel {
  param([string]$Value)

  if ($null -eq $Value) {
    return ""
  }

  return (($Value.Trim().ToLowerInvariant() -replace '\s+', ' ').Trim())
}

function Get-PortableSecretEditableLabels {
  return @($script:PortableSecretEditableLabels)
}

function Get-PortableSecretAllLabels {
  return @($script:PortableSecretEditableLabels + $script:PortableSecretInternalLabels)
}

function Get-PortableSecretEnvName {
  param([string]$Label)

  $normalized = Normalize-PortableKeyLabel $Label
  if (-not $normalized) {
    return $null
  }

  if ($script:PortableSecretEnvNames.ContainsKey($normalized)) {
    return [string]$script:PortableSecretEnvNames[$normalized]
  }

  return $null
}

function New-PortableSecretEnvRef {
  param([string]$Label)

  $envName = Get-PortableSecretEnvName -Label $Label
  if (-not $envName) {
    throw "No environment mapping exists for portable secret label: $Label"
  }

  return [pscustomobject]@{
    source = "env"
    provider = "default"
    id = $envName
  }
}

function Test-PortableSecretRefConfigured {
  param($Value)

  if ($null -eq $Value -or ($Value -is [string])) {
    return $false
  }

  $sourceProp = $Value.PSObject.Properties["source"]
  $idProp = $Value.PSObject.Properties["id"]
  if (-not $sourceProp -or -not $idProp) {
    return $false
  }

  return (-not [string]::IsNullOrWhiteSpace([string]$sourceProp.Value)) -and
    (-not [string]::IsNullOrWhiteSpace([string]$idProp.Value))
}

function Get-PortableSecretStorePath {
  param([string]$BasePath)

  return (Join-Path $BasePath "state\.openclaw\portable-secrets.json")
}

function Get-PortableSecretEntropyBytes {
  param([string]$BasePath)

  $resolved = (Resolve-Path $BasePath).Path
  return [System.Text.Encoding]::UTF8.GetBytes(("PortableClawd|" + $resolved.ToLowerInvariant()))
}

function Ensure-PortableSecretCrypto {
  try {
    [void][System.Security.Cryptography.ProtectedData]
    return
  } catch {
  }

  foreach ($assemblyName in @("System.Security", "System.Security.Cryptography.ProtectedData")) {
    try {
      Add-Type -AssemblyName $assemblyName -ErrorAction Stop | Out-Null
    } catch {
    }
  }

  try {
    [void][System.Security.Cryptography.ProtectedData]
    return
  } catch {
    throw "Windows DPAPI is unavailable in this PowerShell runtime."
  }
}

function Protect-PortableSecretText {
  param(
    [string]$BasePath,
    [string]$Text
  )

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return ""
  }

  Ensure-PortableSecretCrypto
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $entropy = Get-PortableSecretEntropyBytes -BasePath $BasePath
  $protected = [System.Security.Cryptography.ProtectedData]::Protect(
    $bytes,
    $entropy,
    [System.Security.Cryptography.DataProtectionScope]::CurrentUser
  )

  return [Convert]::ToBase64String($protected)
}

function Unprotect-PortableSecretText {
  param(
    [string]$BasePath,
    [string]$CipherText
  )

  if ([string]::IsNullOrWhiteSpace($CipherText)) {
    return ""
  }

  try {
    Ensure-PortableSecretCrypto
    $bytes = [Convert]::FromBase64String($CipherText)
    $entropy = Get-PortableSecretEntropyBytes -BasePath $BasePath
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
      $bytes,
      $entropy,
      [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [System.Text.Encoding]::UTF8.GetString($plain)
  } catch {
    return ""
  }
}

function Read-PortableSecretStore {
  param([string]$BasePath)

  $path = Get-PortableSecretStorePath -BasePath $BasePath
  if (-not (Test-Path $path)) {
    return [pscustomobject]@{
      version = 1
      updatedAt = $null
      secrets = [pscustomobject]@{}
    }
  }

  $store = Get-Content $path -Raw | ConvertFrom-Json
  if (-not $store.secrets) {
    $store | Add-Member -NotePropertyName secrets -NotePropertyValue ([pscustomobject]@{})
  }

  return $store
}

function Save-PortableSecretStore {
  param(
    [string]$BasePath,
    [object]$Store
  )

  $path = Get-PortableSecretStorePath -BasePath $BasePath
  $parent = Split-Path -Parent $path
  New-Item -ItemType Directory -Path $parent -Force | Out-Null

  if (-not $Store.PSObject.Properties["version"]) {
    $Store | Add-Member -NotePropertyName version -NotePropertyValue 1
  }

  $timestamp = (Get-Date).ToString("o")
  if ($Store.PSObject.Properties["updatedAt"]) {
    $Store.updatedAt = $timestamp
  } else {
    $Store | Add-Member -NotePropertyName updatedAt -NotePropertyValue $timestamp
  }

  if (-not $Store.PSObject.Properties["secrets"]) {
    $Store | Add-Member -NotePropertyName secrets -NotePropertyValue ([pscustomobject]@{})
  }

  if (Test-Path $path) {
    try {
      $existing = Get-Item $path -Force
      if (($existing.Attributes -band [System.IO.FileAttributes]::Hidden) -ne 0) {
        $existing.Attributes = ($existing.Attributes -band (-bnot [System.IO.FileAttributes]::Hidden))
      }
    } catch {
    }
  }

  $json = $Store | ConvertTo-Json -Depth 20
  $encoding = New-Object System.Text.UTF8Encoding($false)
  $content = $json + [Environment]::NewLine
  $tempPath = $path + ".tmp"
  $saved = $false

  for ($attempt = 1; $attempt -le 8; $attempt++) {
    try {
      [System.IO.File]::WriteAllText($tempPath, $content, $encoding)
      if (Test-Path $path) {
        try {
          [System.IO.File]::Replace($tempPath, $path, $null, $true)
        } catch {
          Move-Item -Path $tempPath -Destination $path -Force
        }
      } else {
        Move-Item -Path $tempPath -Destination $path -Force
      }
      $saved = $true
      break
    } catch {
      Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
      if ($attempt -ge 8) {
        throw
      }
      Start-Sleep -Milliseconds (75 * $attempt)
    }
  }

  if (-not $saved) {
    throw "Unable to save portable secrets store: $path"
  }

  try {
    $item = Get-Item $path -Force
    $item.Attributes = ($item.Attributes -bor [System.IO.FileAttributes]::Hidden)
  } catch {
  }
}

function Resolve-PortableSecretValues {
  param([string]$BasePath)

  $store = Read-PortableSecretStore -BasePath $BasePath
  $map = @{}

  foreach ($property in $store.secrets.PSObject.Properties) {
    $label = Normalize-PortableKeyLabel $property.Name
    if (-not $label) {
      continue
    }

    $value = Unprotect-PortableSecretText -BasePath $BasePath -CipherText ([string]$property.Value)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      $map[$label] = $value
    }
  }

  return $map
}

function Set-PortableSecretValues {
  param(
    [string]$BasePath,
    [hashtable]$Values
  )

  $allowed = @(Get-PortableSecretAllLabels)
  $store = Read-PortableSecretStore -BasePath $BasePath
  $updated = $false

  foreach ($entry in $Values.GetEnumerator()) {
    $label = Normalize-PortableKeyLabel $entry.Key
    if (-not $label -or ($allowed -notcontains $label)) {
      continue
    }

    $value = [string]$entry.Value
    if ([string]::IsNullOrWhiteSpace($value)) {
      continue
    }

    $cipherText = Protect-PortableSecretText -BasePath $BasePath -Text $value.Trim()
    if ($store.secrets.PSObject.Properties[$label]) {
      if ([string]$store.secrets.PSObject.Properties[$label].Value -ne $cipherText) {
        $store.secrets.PSObject.Properties[$label].Value = $cipherText
        $updated = $true
      }
    } else {
      $store.secrets | Add-Member -NotePropertyName $label -NotePropertyValue $cipherText
      $updated = $true
    }
  }

  if ($updated) {
    Save-PortableSecretStore -BasePath $BasePath -Store $store
  }

  return $store
}

function Get-PortableSecretEnvMap {
  param([hashtable]$Secrets)

  $envMap = @{}
  foreach ($entry in $script:PortableSecretEnvNames.GetEnumerator()) {
    $label = [string]$entry.Key
    $envName = [string]$entry.Value
    if ($Secrets.ContainsKey($label) -and (-not [string]::IsNullOrWhiteSpace([string]$Secrets[$label]))) {
      $envMap[$envName] = [string]$Secrets[$label]
    }
  }

  return $envMap
}

function Set-PortableProcessSecretEnv {
  param([hashtable]$Secrets)

  $envMap = Get-PortableSecretEnvMap -Secrets $Secrets

  foreach ($envName in $script:PortableSecretEnvNames.Values) {
    $existing = Get-Item -Path ("Env:" + $envName) -ErrorAction SilentlyContinue
    if ($envMap.ContainsKey($envName)) {
      Set-Item -Path ("Env:" + $envName) -Value $envMap[$envName]
    } elseif ($existing) {
      Remove-Item -Path ("Env:" + $envName) -ErrorAction SilentlyContinue
    }
  }
}

function Resolve-PortableSecretInputValue {
  param(
    $Value,
    [hashtable]$PortableSecrets
  )

  if ($null -eq $Value) {
    return ""
  }

  if ($Value -is [string]) {
    return $Value.Trim()
  }

  if (Test-PortableSecretRefConfigured -Value $Value) {
    $envName = [string]$Value.id
    $processValue = [Environment]::GetEnvironmentVariable($envName)
    if (-not [string]::IsNullOrWhiteSpace($processValue)) {
      return $processValue.Trim()
    }

    if ($PortableSecrets) {
      $envMap = Get-PortableSecretEnvMap -Secrets $PortableSecrets
      if ($envMap.ContainsKey($envName)) {
        return ([string]$envMap[$envName]).Trim()
      }
    }
  }

  return ""
}
