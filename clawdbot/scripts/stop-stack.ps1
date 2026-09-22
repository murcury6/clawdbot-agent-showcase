param(
  [string]$BasePath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "SilentlyContinue"

$runDir = Join-Path $BasePath "run"
$portableGatewayEntry = (Join-Path $BasePath "openclaw\openclaw.mjs").ToLowerInvariant()
$portableOllamaExe = (Join-Path $BasePath "offline\ollama\bin\ollama.exe").ToLowerInvariant()
$pidFiles = @(
  @{ Name = "gateway"; Path = (Join-Path $runDir "gateway.pid") },
  @{ Name = "ollama"; Path = (Join-Path $runDir "ollama.pid") }
)

$helperLoops = @(
  @{
    Name = "keep-working-nudge"
    Command = (Join-Path $BasePath "scripts\keep-working-nudge.cmd")
    Patterns = @("keep-working-nudge.cmd run")
    LockPath = (Join-Path $runDir "keep-working-nudge.lock")
  },
  @{
    Name = "telegram-auto-continue"
    Command = (Join-Path $BasePath "scripts\telegram-auto-continue.cmd")
    Patterns = @("telegram-auto-continue.ps1")
    LockPath = (Join-Path $runDir "telegram-auto-continue.lock")
  },
  @{
    Name = "telegram-work-controller"
    Command = (Join-Path $BasePath "scripts\telegram-work-controller.cmd")
    Patterns = @("telegram-work-controller.ps1")
    LockPath = (Join-Path $runDir "telegram-work-controller.lock")
  },
  @{
    Name = "agent-continuity-watchdog"
    Command = (Join-Path $BasePath "scripts\agent-continuity-watchdog.cmd")
    Patterns = @("agent-continuity-watchdog.ps1")
    LockPath = (Join-Path $runDir "agent-continuity-watchdog.lock")
  }
)

function Get-MatchingProcesses {
  param([string[]]$Patterns)

  if (-not $Patterns -or $Patterns.Count -eq 0) {
    return @()
  }

  return @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $cmd = [string]$_.CommandLine
        if (-not $cmd) {
          return $false
        }

        foreach ($pattern in $Patterns) {
          if (-not [string]::IsNullOrWhiteSpace($pattern) -and $cmd -like ('*' + $pattern + '*')) {
            return $true
          }
        }

        return $false
      }
  )
}

function Test-Port {
  param([int]$Port)

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $async = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
    $ready = $async.AsyncWaitHandle.WaitOne(400)
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

function Wait-ForPortDown {
  param(
    [int]$Port,
    [int]$TimeoutSeconds = 10
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (-not (Test-Port -Port $Port)) {
      return $true
    }

    Start-Sleep -Milliseconds 250
  }

  return (-not (Test-Port -Port $Port))
}

function Get-PortableGatewayProcesses {
  param([string]$EntryPath)

  return @(
    Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $cmd = [string]$_.CommandLine
        if (-not $cmd) {
          return $false
        }

        $normalized = $cmd.ToLowerInvariant()
        return $normalized.Contains($EntryPath) -and $normalized -match '\bgateway\s+run\b'
      }
  )
}

function Get-PortableOllamaProcesses {
  param([string]$ExecutablePath)

  return @(
    Get-CimInstance Win32_Process -Filter "Name = 'ollama.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $exe = [string]$_.ExecutablePath
        if (-not $exe) {
          return $false
        }

        return $exe.ToLowerInvariant() -eq $ExecutablePath
      }
  )
}

function Stop-HelperLoop {
  param(
    [hashtable]$Helper,
    [int]$WaitSeconds = 8
  )

  $hadLock = Test-Path $Helper.LockPath
  $initialProcesses = @(Get-MatchingProcesses -Patterns $Helper.Patterns)

  if (Test-Path $Helper.Command) {
    & cmd.exe /d /c ('"' + $Helper.Command + '" stop') | Out-Null
  }

  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  do {
    $remaining = @(Get-MatchingProcesses -Patterns $Helper.Patterns)
    if ($remaining.Count -eq 0) {
      break
    }

    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)

  $remaining = @(Get-MatchingProcesses -Patterns $Helper.Patterns)
  if ($remaining.Count -gt 0) {
    foreach ($procId in @($remaining | ForEach-Object { [int]$_.ProcessId } | Sort-Object -Unique)) {
      Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Milliseconds 500
    $remaining = @(Get-MatchingProcesses -Patterns $Helper.Patterns)
  }

  Remove-Item $Helper.LockPath -Recurse -Force -ErrorAction SilentlyContinue

  if ($remaining.Count -gt 0) {
    Write-Output ($Helper.Name + "=force-stop-pending:" + (($remaining | ForEach-Object { $_.ProcessId } | Sort-Object -Unique) -join ","))
    return
  }

  if ($initialProcesses.Count -gt 0) {
    Write-Output ($Helper.Name + "=stopped")
    return
  }

  if ($hadLock) {
    Write-Output ($Helper.Name + "=stale-lock-cleared")
    return
  }

  Write-Output ($Helper.Name + "=not-running")
}

foreach ($helper in $helperLoops) {
  Stop-HelperLoop -Helper $helper
}

foreach ($pidFile in $pidFiles) {
  if (-not (Test-Path $pidFile.Path)) {
    Write-Output ($pidFile.Name + "=not-recorded")
    continue
  }

  $pidValue = Get-Content $pidFile.Path -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($pidValue -and ($pidValue -as [int])) {
    $proc = Get-Process -Id ([int]$pidValue) -ErrorAction SilentlyContinue
    if ($proc) {
      Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
      Write-Output ($pidFile.Name + "=stopped")
    } else {
      Write-Output ($pidFile.Name + "=missing")
    }
  } else {
    Write-Output ($pidFile.Name + "=invalid-pid")
  }

  Remove-Item $pidFile.Path -Force -ErrorAction SilentlyContinue
}

$gatewayProcesses = @(Get-PortableGatewayProcesses -EntryPath $portableGatewayEntry)
if ($gatewayProcesses.Count -gt 0) {
  $gatewayProcesses | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
  Write-Output ("gateway=portable-processes-stopped:" + (($gatewayProcesses | ForEach-Object { $_.ProcessId }) -join ","))
}
if (Wait-ForPortDown -Port 18789 -TimeoutSeconds 10) {
  Write-Output "gateway_port=closed"
} else {
  Write-Output "gateway_port=still-listening"
}

$ollamaProcesses = @(Get-PortableOllamaProcesses -ExecutablePath $portableOllamaExe)
if ($ollamaProcesses.Count -gt 0) {
  $ollamaProcesses | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
  Write-Output ("ollama=portable-processes-stopped:" + (($ollamaProcesses | ForEach-Object { $_.ProcessId }) -join ","))
}
if (Wait-ForPortDown -Port 11500 -TimeoutSeconds 10) {
  Write-Output "ollama_port=closed"
} else {
  Write-Output "ollama_port=still-listening"
}
