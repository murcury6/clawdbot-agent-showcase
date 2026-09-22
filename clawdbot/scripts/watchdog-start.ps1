param(
  [string]$BasePath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $BasePath)) {
  throw "Base path does not exist: $BasePath"
}

$BasePath = (Resolve-Path $BasePath).Path
$runDir = Join-Path $BasePath "run"
$pausePath = Join-Path $runDir "watchdog.pause"
$logDir = Join-Path $BasePath "logs"
$logPath = Join-Path $logDir "watchdog.log"

function Write-WatchdogLog {
  param([string]$Message)

  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  Add-Content -Path $logPath -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message) -Encoding UTF8
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

function Test-HelperRunning {
  param([string[]]$Patterns)

  if (-not $Patterns -or $Patterns.Count -eq 0) {
    return $false
  }

  $matches = @(
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

  return ($matches.Count -gt 0)
}

New-Item -ItemType Directory -Path $runDir -Force | Out-Null

if (Test-Path $pausePath) {
  return
}

$ollamaUp = Test-Port -Port 11500
$gatewayUp = Test-Port -Port 18789
$autoContinueUp = Test-HelperRunning -Patterns @("telegram-auto-continue.ps1")
$workControllerUp = Test-HelperRunning -Patterns @("telegram-work-controller.ps1")
$keepWorkingUp = Test-HelperRunning -Patterns @("keep-working-nudge.cmd run")
$continuityUp = Test-HelperRunning -Patterns @("agent-continuity-watchdog.ps1")
$helpersUp = $autoContinueUp -and $workControllerUp -and $keepWorkingUp -and $continuityUp

if ($ollamaUp -and $gatewayUp -and $helpersUp) {
  return
}

Write-WatchdogLog ("Health/helper check failed (11500={0}, 18789={1}, auto={2}, work={3}, keep={4}, continuity={5}); starting stack." -f $ollamaUp, $gatewayUp, $autoContinueUp, $workControllerUp, $keepWorkingUp, $continuityUp)

try {
  $env:PORTABLE_CLAWD_UNLOCK_OK = "1"
  $output = & (Join-Path $BasePath "scripts\start-stack.ps1") -BasePath $BasePath 2>&1
  if ($output) {
    foreach ($line in $output) {
      Write-WatchdogLog ([string]$line)
    }
  }
} catch {
  Write-WatchdogLog ("Watchdog restart failed: " + $_.Exception.Message)
  throw
}
