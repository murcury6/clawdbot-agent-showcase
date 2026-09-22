param(
  [string]$BasePath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$OpenClawArgs
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "portable-secrets.ps1")

if (-not (Test-Path $BasePath)) {
  throw "Base path does not exist: $BasePath"
}

$BasePath = (Resolve-Path $BasePath).Path
$stateDir = Join-Path $BasePath "state\.openclaw"
$unlockEnvName = "PORTABLE_CLAWD_UNLOCK_OK"

$env:OPENCLAW_HOME = Join-Path $BasePath "state"
$env:OPENCLAW_STATE_DIR = $stateDir
$env:OPENCLAW_CONFIG_PATH = Join-Path $stateDir "openclaw.json"
$env:OPENCLAW_WORKSPACE_DIR = Join-Path $BasePath "workspace"
$env:OLLAMA_API_KEY = "ollama-local"
$env:PATH = (Join-Path $BasePath "node") + ";" + $env:PATH

& (Join-Path $BasePath "scripts\sync-portable-keys.ps1") -BasePath $BasePath | Out-Null
if ([Environment]::GetEnvironmentVariable($unlockEnvName) -ne "1") {
  & (Join-Path $BasePath "scripts\require-unlock.ps1") -BasePath $BasePath
  Set-Item -Path ("Env:" + $unlockEnvName) -Value "1"
}
& (Join-Path $BasePath "scripts\sync-ai-context.ps1") -BasePath $BasePath | Out-Null
& (Join-Path $BasePath "scripts\ensure-portable-config.ps1") -BasePath $BasePath | Out-Null
& (Join-Path $BasePath "scripts\select-model.ps1") -BasePath $BasePath | Out-Null

$portableSecrets = Resolve-PortableSecretValues -BasePath $BasePath
Set-PortableProcessSecretEnv -Secrets $portableSecrets

$nodeExe = Join-Path $BasePath "node\node.exe"
$entry = Join-Path $BasePath "openclaw\openclaw.mjs"

& $nodeExe $entry @OpenClawArgs
exit $LASTEXITCODE
