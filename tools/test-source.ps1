param([string]$Root = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$source = Join-Path $Root 'clawdbot/scripts'
$trees = @{}
foreach ($file in Get-ChildItem -LiteralPath $source -Filter '*.ps1' -File) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "Parse failed: $($file.Name): $($parseErrors.Message -join '; ')" }
    $trees[$file.Name] = $ast
}
# Extract only reviewed pure definitions. Do not dot-source the original scripts:
# their top-level code starts services, touches private state or has other effects.
$functions = @{
    'select-model.ps1' = @('Split-ModelRef','Get-OllamaProbeModelId','Get-FallbackChain','Get-PreferredSafeOfflineTier','Remove-ObjectProperty','Clear-SessionRuntimeModelState')
    'telegram-work-controller.ps1' = @('Normalize-Text','Test-TaskListHasActiveWork','Get-QueueCandidateJob')
    'portable-secrets.ps1' = @('Normalize-PortableKeyLabel','Test-PortableSecretRefConfigured')
}
foreach ($file in $functions.Keys) {
    foreach ($name in $functions[$file]) {
        $matches = @($trees[$file].FindAll({param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true))
        if ($matches.Count -ne 1) { throw "Expected one definition: $file/$name" }
        . ([scriptblock]::Create($matches[0].Extent.Text))
    }
}
$script:checks = 0
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -cne $Expected) { throw "FAIL: $Label" }
    $script:checks++
}
Assert-Equal (Split-ModelRef 'ollama/example:small').provider 'ollama' 'provider parsing'
Assert-Equal (Split-ModelRef 'vendor/group/model').model 'group/model' 'model slash preservation'
$rejected = $false
try { Split-ModelRef 'invalid' | Out-Null } catch { $rejected = $true }
Assert-Equal $rejected $true 'malformed model reference'
Assert-Equal (Get-OllamaProbeModelId 'ollama/example:small') 'example:small' 'local probe identifier'
Assert-Equal ((Get-FallbackChain @('a','b','a','','c')) -join ',') 'a,b,c' 'stable fallback deduplication'
$tiers = @([pscustomobject]@{tier='7b'}, [pscustomobject]@{tier='3b'}, [pscustomobject]@{tier='1b'})
Assert-Equal (Get-PreferredSafeOfflineTier $tiers).tier '3b' 'actual historical tier preference'
Assert-Equal (Normalize-Text "  hello `n world  ") 'hello world' 'message whitespace'
Assert-Equal (Normalize-PortableKeyLabel '  TELEGRAM   BOT TOKEN ') 'telegram bot token' 'key-label normalization'
Assert-Equal (Test-PortableSecretRefConfigured 'not-a-reference') $false 'plain string is not reference'
Assert-Equal (Test-PortableSecretRefConfigured ([pscustomobject]@{source='env';id='SYNTHETIC_VARIABLE'})) $true 'environment reference shape'
Assert-Equal (Test-TaskListHasActiveWork $null) $false 'missing queue'
Assert-Equal (Test-TaskListHasActiveWork ([pscustomobject]@{currentJobId='example'})) $true 'active job'
Assert-Equal (Test-TaskListHasActiveWork ([pscustomobject]@{doingNow=@();jobQueue=@()})) $false 'empty queue'
$queue = [pscustomobject]@{jobQueue=@([pscustomobject]@{id='first';status='queued'},[pscustomobject]@{id='active';status='doing'})}
Assert-Equal (Get-QueueCandidateJob $queue).id 'active' 'in-progress queue priority'
$queue.jobQueue[1].status = 'queued'
Assert-Equal (Get-QueueCandidateJob $queue).id 'first' 'ordered queue fallback'
$entry = [pscustomobject]@{modelProvider='example';model='example';contextTokens=123;keep='unchanged'}
Assert-Equal (Clear-SessionRuntimeModelState $entry) $true 'clear stale model state'
Assert-Equal ($null -eq $entry.PSObject.Properties['model']) $true 'stale model removed'
Assert-Equal $entry.keep 'unchanged' 'unrelated session data retained'
Assert-Equal (Clear-SessionRuntimeModelState $entry) $false 'state clear idempotency'
Write-Output "PASS: $($trees.Count) PowerShell source files parsed; $checks isolated assertions passed. No bot/runtime code executed."
