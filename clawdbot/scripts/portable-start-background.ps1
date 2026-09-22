param(
  [Parameter(Mandatory = $true)]
  [string]$BasePath
)

$ErrorActionPreference = 'Stop'

$BasePath = (Resolve-Path $BasePath).Path
$logDir = Join-Path $BasePath 'logs'
$logPath = Join-Path $logDir 'portable-start.log'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Add-PortableStartLog {
  param([string]$Message)

  if ([string]::IsNullOrWhiteSpace($Message)) {
    return
  }

  $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
  [System.IO.File]::AppendAllText($logPath, ('[' + $timestamp + '] ' + $Message + [Environment]::NewLine), $utf8NoBom)
}

$env:PORTABLE_CLAWD_UNLOCK_OK = '1'

try {
  $output = & (Join-Path $BasePath 'scripts\start-stack.ps1') -BasePath $BasePath 2>&1
  if ($output) {
    $text = (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
    Add-PortableStartLog -Message $text
  } else {
    Add-PortableStartLog -Message 'start-stack completed with no console output.'
  }
} catch {
  Add-PortableStartLog -Message ('start-stack failed: ' + $_.Exception.Message)
  if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
    Add-PortableStartLog -Message $_.InvocationInfo.PositionMessage
  }
  exit 1
}
