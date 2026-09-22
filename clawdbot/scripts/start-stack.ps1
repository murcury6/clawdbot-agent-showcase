param(
  [string]$BasePath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  [switch]$SkipGateway
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "portable-secrets.ps1")

if (-not (Test-Path $BasePath)) {
  throw "Base path does not exist: $BasePath"
}
$BasePath = (Resolve-Path $BasePath).Path

& (Join-Path $BasePath "scripts\sync-portable-keys.ps1") -BasePath $BasePath | Out-Null

if ($env:PORTABLE_CLAWD_UNLOCK_OK -ne "1") {
  & (Join-Path $BasePath "scripts\require-unlock.ps1") -BasePath $BasePath
  $env:PORTABLE_CLAWD_UNLOCK_OK = "1"
}

& (Join-Path $BasePath "scripts\sync-ai-context.ps1") -BasePath $BasePath | Out-Null

function Read-LogTail {
  param(
    [string]$Path,
    [int]$Lines = 20
  )

  if (-not (Test-Path $Path)) {
    return ""
  }

  try {
    return ((Get-Content $Path -Tail $Lines) -join [Environment]::NewLine).Trim()
  } catch {
    return ""
  }
}

function Invoke-LoggedProcess {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [Parameter(Mandatory = $true)]
    [string[]]$ArgumentList,
    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory,
    [Parameter(Mandatory = $true)]
    [string]$StdOutPath,
    [Parameter(Mandatory = $true)]
    [string]$StdErrPath,
    [Parameter(Mandatory = $true)]
    [string]$FailureMessage
  )

  $previousLocation = Get-Location
  $combinedText = ""
  $exitCode = 1
  try {
    Set-Location $WorkingDirectory
    $combined = & $FilePath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
    if ($combined) {
      $combinedText = (($combined | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
    }
  } finally {
    Set-Location $previousLocation
  }

  Set-Content $StdOutPath -Value "" -Encoding UTF8
  Set-Content $StdErrPath -Value $combinedText -Encoding UTF8

  if ($exitCode -eq 0) {
    return
  }

  $stderrTail = Read-LogTail -Path $StdErrPath
  $details = @()
  if ($stderrTail) {
    $details += "stderr:"
    $details += $stderrTail
  }
  $detailText = if ($details.Count -gt 0) {
    [Environment]::NewLine + ($details -join [Environment]::NewLine)
  } else {
    ""
  }

  throw ($FailureMessage + " Exit code: " + $exitCode + "." + $detailText)
}

function Test-Port {
  param([int]$Port)

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $async = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
    $ready = $async.AsyncWaitHandle.WaitOne(500)
    if (-not $ready) {
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

function Get-PortOwnerId {
  param([int]$Port)

  try {
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
      Select-Object -First 1
    if ($listener -and $listener.OwningProcess) {
      return [int]$listener.OwningProcess
    }
  } catch {
  }

  return $null
}

function Remove-StalePidFile {
  param([string]$Path)

  if (-not (Test-Path $Path)) {
    return
  }

  try {
    $raw = (Get-Content $Path -Raw).Trim()
    if ($raw -notmatch '^\d+$') {
      Remove-Item $Path -Force -ErrorAction SilentlyContinue
      return
    }

    $pid = [int]$raw
    if (-not (Get-Process -Id $pid -ErrorAction SilentlyContinue)) {
      Remove-Item $Path -Force -ErrorAction SilentlyContinue
    }
  } catch {
    Remove-Item $Path -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-PortableGatewayStopBestEffort {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Root,
    [Parameter(Mandatory = $true)]
    [string]$Launcher,
    [Parameter(Mandatory = $true)]
    [string]$LogsDir
  )

  $stdoutPath = Join-Path $LogsDir "gateway-stop.out.log"
  $stderrPath = Join-Path $LogsDir "gateway-stop.err.log"
  $previousLocation = Get-Location
  $combinedText = ""
  $exitCode = 0

  try {
    Set-Location $Root
    $combined = & cmd.exe /d /c "`"$Launcher`" gateway stop" 2>&1
    $exitCode = $LASTEXITCODE
    if ($combined) {
      $combinedText = (($combined | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
    }
  } finally {
    Set-Location $previousLocation
  }

  Set-Content $stdoutPath -Value "" -Encoding UTF8
  Set-Content $stderrPath -Value $combinedText -Encoding UTF8

  return [pscustomobject]@{
    exitCode = $exitCode
    output = $combinedText
  }
}

function Get-PortableGatewayProcesses {
  param([string]$Root)

  $entryPath = (Join-Path $Root "openclaw\openclaw.mjs").ToLowerInvariant()

  return @(
    Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $cmd = [string]$_.CommandLine
        if (-not $cmd) {
          return $false
        }

        $normalized = $cmd.ToLowerInvariant()
        return $normalized.Contains($entryPath) -and $normalized -match '\bgateway\s+run\b'
      }
  )
}

function Get-PortableOllamaProcesses {
  param([string]$Root)

  $ollamaExe = (Join-Path $Root "offline\ollama\bin\ollama.exe").ToLowerInvariant()

  return @(
    Get-CimInstance Win32_Process -Filter "Name = 'ollama.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $exe = [string]$_.ExecutablePath
        if (-not $exe) {
          return $false
        }

        return $exe.ToLowerInvariant() -eq $ollamaExe
      }
  )
}

function Stop-PortableProcesses {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Label,
    [Parameter(Mandatory = $true)]
    [object[]]$Processes,
    [int]$WaitSeconds = 10
  )

  $ids = @($Processes | ForEach-Object { [int]$_.ProcessId } | Sort-Object -Unique)
  foreach ($id in $ids) {
    try {
      Stop-Process -Id $id -Force -ErrorAction Stop
    } catch {
    }
  }

  if ($ids.Count -eq 0) {
    return
  }

  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  while ((Get-Date) -lt $deadline) {
    $alive = @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($alive.Count -eq 0) {
      return
    }
    Start-Sleep -Milliseconds 250
  }

  throw ("Unable to stop stale portable " + $Label + " process(es): " + ($ids -join ", "))
}

function Wait-ForPort {
  param(
    [int]$Port,
    [int]$TimeoutSeconds = 20
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-Port -Port $Port) {
      return $true
    }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

function Start-Ollama {
  param([string]$Root)

  $runDir = Join-Path $Root "run"
  New-Item -ItemType Directory -Path $runDir -Force | Out-Null

  if (Test-Port -Port 11500) {
    $ownerId = Get-PortOwnerId -Port 11500
    if ($ownerId) {
      Set-Content (Join-Path $runDir "ollama.pid") $ownerId -Encoding ASCII
    }
    return "already-running"
  }

  $ollamaExe = Join-Path $Root "offline\ollama\bin\ollama.exe"
  $modelsDir = Join-Path $Root "offline\ollama\models"
  $logsDir = Join-Path $Root "logs"
  $ollamaHomeRoot = Join-Path $Root "state\ollama-home"
  $ollamaUserProfile = Join-Path $ollamaHomeRoot "profile"

  if (-not (Test-Path $ollamaExe)) {
    throw "Missing Ollama runtime: $ollamaExe"
  }
  if (-not (Test-Path $modelsDir)) {
    throw "Missing Ollama models: $modelsDir"
  }

  New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
  New-Item -ItemType Directory -Path $runDir -Force | Out-Null
  New-Item -ItemType Directory -Path $ollamaUserProfile -Force | Out-Null

  $stalePortable = @(Get-PortableOllamaProcesses -Root $Root)
  if ($stalePortable.Count -gt 0) {
    Stop-PortableProcesses -Label "Ollama" -Processes $stalePortable
  }

  $stdoutPath = Join-Path $logsDir "ollama.out.log"
  $stderrPath = Join-Path $logsDir "ollama.err.log"
  $workingDirectory = Split-Path -Parent $ollamaExe
  $escapedWorkdir = $workingDirectory.Replace('"', '""')
  $escapedExe = $ollamaExe.Replace('"', '""')
  $escapedModels = $modelsDir.Replace('"', '""')
  $escapedStdOut = $stdoutPath.Replace('"', '""')
  $escapedStdErr = $stderrPath.Replace('"', '""')
  $escapedUserProfile = $ollamaUserProfile.Replace('"', '""')
  $cmdLine = 'cd /d "{0}" && set "USERPROFILE={1}" && set "HOME={1}" && set "OLLAMA_HOST=127.0.0.1:11500" && set "OLLAMA_MODELS={2}" && set "OLLAMA_NO_CLOUD=1" && start "" /b "{3}" serve 1>>"{4}" 2>>"{5}"' -f $escapedWorkdir, $escapedUserProfile, $escapedModels, $escapedExe, $escapedStdOut, $escapedStdErr

  Set-Content $stdoutPath -Value "" -Encoding UTF8
  Set-Content $stderrPath -Value "" -Encoding UTF8
  & cmd.exe /d /c $cmdLine | Out-Null

  if (-not (Wait-ForPort -Port 11500 -TimeoutSeconds 20)) {
    throw "Portable Ollama did not start on 127.0.0.1:11500"
  }

  $ownerId = Get-PortOwnerId -Port 11500
  if ($ownerId) {
    Set-Content (Join-Path $runDir "ollama.pid") $ownerId -Encoding ASCII
  }

  return "started"
}

function Ensure-OllamaModel {
  param([string]$Root)

  $ollamaExe = Join-Path $Root "offline\ollama\bin\ollama.exe"
  $modelsDir = Join-Path $Root "offline\ollama\models"
  $ggufPath = Join-Path $Root "offline\llama\models\qwen2.5-coder.gguf"
  $manifestPath = Join-Path $modelsDir "manifests\registry.ollama.ai\library\qwen2.5-coder\7b"
  $logsDir = Join-Path $Root "logs"
  $runDir = Join-Path $Root "run"
  $ollamaHomeRoot = Join-Path $Root "state\ollama-home"
  $ollamaUserProfile = Join-Path $ollamaHomeRoot "profile"
  $modelfilePath = Join-Path $runDir "qwen2.5-coder.Modelfile"
  $createStdOutPath = Join-Path $logsDir "ollama-create.out.log"
  $createStdErrPath = Join-Path $logsDir "ollama-create.err.log"

  if (-not (Test-Path $ggufPath)) {
    throw "Missing bundled GGUF model: $ggufPath"
  }

  New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
  New-Item -ItemType Directory -Path $runDir -Force | Out-Null
  New-Item -ItemType Directory -Path $ollamaUserProfile -Force | Out-Null

  $previousHost = $env:OLLAMA_HOST
  $previousModels = $env:OLLAMA_MODELS
  $previousNoCloud = $env:OLLAMA_NO_CLOUD
  $previousUserProfile = $env:USERPROFILE
  $previousHome = $env:HOME

  $env:OLLAMA_HOST = "127.0.0.1:11500"
  $env:OLLAMA_MODELS = $modelsDir
  $env:OLLAMA_NO_CLOUD = "1"
  $env:USERPROFILE = $ollamaUserProfile
  $env:HOME = $ollamaUserProfile

  try {
    if (Test-Path $manifestPath) {
      return "present"
    }

    @(
      "FROM $ggufPath",
      "PARAMETER num_ctx 2048",
      "PARAMETER temperature 0.2"
    ) | Set-Content $modelfilePath -Encoding ASCII

    Write-Output "Importing bundled Ollama model..."
    Invoke-LoggedProcess `
      -FilePath $ollamaExe `
      -ArgumentList @("create", "qwen2.5-coder:7b", "-f", $modelfilePath) `
      -WorkingDirectory (Split-Path -Parent $ollamaExe) `
      -StdOutPath $createStdOutPath `
      -StdErrPath $createStdErrPath `
      -FailureMessage "Unable to import bundled GGUF into portable Ollama."

    return "created"
  } finally {
    $env:OLLAMA_HOST = $previousHost
    $env:OLLAMA_MODELS = $previousModels
    $env:OLLAMA_NO_CLOUD = $previousNoCloud
    $env:USERPROFILE = $previousUserProfile
    $env:HOME = $previousHome
  }
}

function Start-Gateway {
  param([string]$Root)

  $runDir = Join-Path $Root "run"
  $logsDir = Join-Path $Root "logs"
  New-Item -ItemType Directory -Path $runDir -Force | Out-Null
  New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

  Remove-StalePidFile -Path (Join-Path $runDir "gateway.pid")

  if (Test-Port -Port 18789) {
    $ownerId = Get-PortOwnerId -Port 18789
    if ($ownerId) {
      Write-Output ("gateway_existing_listener=" + $ownerId)
    } else {
      Write-Output "gateway_existing_listener=unknown"
    }
  }

  $launcher = Join-Path $Root "scripts\openclaw-portable.bat"

  if (-not (Test-Path $launcher)) {
    throw "Missing OpenClaw launcher: $launcher"
  }

  New-Item -ItemType Directory -Path $runDir -Force | Out-Null

  $stalePortable = @(Get-PortableGatewayProcesses -Root $Root)
  if ($stalePortable.Count -gt 0) {
    Stop-PortableProcesses -Label "gateway" -Processes $stalePortable
  }

  # Clear stale OpenClaw gateway ownership/lock state before launching.
  $null = Invoke-PortableGatewayStopBestEffort -Root $Root -Launcher $launcher -LogsDir $logsDir

  $proc = Start-Process -FilePath "cmd.exe" `
    -ArgumentList @("/d", "/c", "`"$launcher`" gateway run --force --port 18789") `
    -WorkingDirectory $Root `
    -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $logsDir "gateway.out.log") `
    -RedirectStandardError (Join-Path $logsDir "gateway.err.log") `
    -PassThru

  Set-Content (Join-Path $runDir "gateway.pid") $proc.Id -Encoding ASCII

  if (-not (Wait-ForPort -Port 18789 -TimeoutSeconds 25)) {
    Remove-StalePidFile -Path (Join-Path $runDir "gateway.pid")
    $outTail = Read-LogTail -Path (Join-Path $logsDir "gateway.out.log")
    $errTail = Read-LogTail -Path (Join-Path $logsDir "gateway.err.log")
    $details = @()
    if ($outTail) {
      $details += "stdout:"
      $details += $outTail
    }
    if ($errTail) {
      $details += "stderr:"
      $details += $errTail
    }
    $staleAfterLaunch = @(Get-PortableGatewayProcesses -Root $Root)
    if ($staleAfterLaunch.Count -gt 0) {
      $details += "portable gateway processes:"
      $details += ($staleAfterLaunch | ForEach-Object {
        $cmd = [string]$_.CommandLine
        if ($cmd.Length -gt 220) {
          $cmd = $cmd.Substring(0, 220) + "..."
        }
        ("pid " + $_.ProcessId + ": " + $cmd)
      })
    }
    $detailText = if ($details.Count -gt 0) {
      [Environment]::NewLine + ($details -join [Environment]::NewLine)
    } else {
      ""
    }
    throw ("Portable OpenClaw gateway did not start on 127.0.0.1:18789" + $detailText)
  }

  $ownerId = Get-PortOwnerId -Port 18789
  if ($ownerId) {
    Set-Content (Join-Path $runDir "gateway.pid") $ownerId -Encoding ASCII
  }

  return "started"
}

& (Join-Path $BasePath "scripts\ensure-portable-config.ps1") -BasePath $BasePath | Out-Null

$portableSecrets = Resolve-PortableSecretValues -BasePath $BasePath
Set-PortableProcessSecretEnv -Secrets $portableSecrets

$ollamaState = Start-Ollama -Root $BasePath
$modelState = Ensure-OllamaModel -Root $BasePath
$null = & (Join-Path $BasePath "scripts\select-model.ps1") -BasePath $BasePath
$gatewayState = if ($SkipGateway) { "skipped" } else { Start-Gateway -Root $BasePath }

if (-not $SkipGateway) {
  $helperCommands = @(
    (Join-Path $BasePath "scripts\telegram-auto-continue.cmd"),
    (Join-Path $BasePath "scripts\telegram-work-controller.cmd"),
    (Join-Path $BasePath "scripts\keep-working-nudge.cmd"),
    (Join-Path $BasePath "scripts\agent-continuity-watchdog.cmd")
  )

  foreach ($helperCmd in $helperCommands) {
    if (Test-Path $helperCmd) {
      & cmd.exe /d /c ('"' + $helperCmd + '" start') | Out-Null
    }
  }
}

Write-Output ("ollama=" + $ollamaState)
Write-Output ("ollama_model=" + $modelState)
Write-Output ("gateway=" + $gatewayState)
