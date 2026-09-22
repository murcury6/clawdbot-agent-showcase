param([string]$Root = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = (Resolve-Path -LiteralPath $Root).Path
$manifest = Get-Content -LiteralPath (Join-Path $Root 'release-manifest.json') -Raw | ConvertFrom-Json
$approved = @{}
foreach ($entry in $manifest.files) {
    $path = [string]$entry.path
    if ($path -match '(^/|\\|(^|/)\.\.(/|$))' -or $approved.ContainsKey($path)) {
        throw "Invalid or duplicate manifest path: $path"
    }
    if ($entry.sha256 -notmatch '^[a-f0-9]{64}$') { throw "Invalid hash: $path" }
    $approved[$path] = [string]$entry.sha256
}
$patterns = @(
    'sk-[A-Za-z0-9_-]{20,}',
    'gh[pousr]_[A-Za-z0-9]{20,}',
    'github_pat_[A-Za-z0-9_]{20,}',
    'hf_[A-Za-z0-9]{20,}',
    'AIza[A-Za-z0-9_-]{20,}',
    'AKIA[A-Z0-9]{16}',
    '\b[0-9]{6,12}:[A-Za-z0-9_-]{30,}\b',
    '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}',
    '(?i)[A-Z]:\\Users\\[^\\\s]+\\'
)
$seen = @{}
function Get-ReleaseFiles([string]$Directory) {
    foreach ($item in Get-ChildItem -LiteralPath $Directory -Force) {
        if ($Directory -eq $Root -and $item.Name -eq '.git') { continue }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Links are not release files: $($item.Name)"
        }
        if ($item.PSIsContainer) { Get-ReleaseFiles $item.FullName } else { $item }
    }
}
foreach ($file in Get-ReleaseFiles $Root) {
    $relative = $file.FullName.Substring($Root.Length + 1).Replace('\', '/')
    if ($relative -ne 'release-manifest.json') {
        if (-not $approved.ContainsKey($relative)) { throw "Unreviewed file: $relative" }
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $approved[$relative]) {
            throw "Hash mismatch: $relative"
        }
        $seen[$relative] = $true
    }
    if ($file.Length -gt 131072 -or $file.Extension -notin @('.ps1','.bat','.cmd','.md','.txt','.json','.yml','.gitignore','.gitattributes')) {
        throw "Unsupported release payload: $relative"
    }
    $content = [IO.File]::ReadAllText($file.FullName)
    if ($content.Contains([char]0)) { throw "Binary payload: $relative" }
    foreach ($pattern in $patterns) {
        if ($content -match $pattern) { throw "Credential/personal-path pattern detected in $relative (value withheld)" }
    }
}
foreach ($path in $approved.Keys) {
    if (-not $seen.ContainsKey($path)) { throw "Missing approved file: $path" }
}
Write-Output "PASS: $($seen.Count) SHA-256-verified files plus manifest; no unexpected payloads or configured secret-pattern matches."
