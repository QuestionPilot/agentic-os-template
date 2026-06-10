#Requires -Version 7
# Memory-write governance hook (Hermes pre_tool_call, matcher memory) —
# Windows twin of memory-sanitize.sh. Runs the framework injection scan over
# content being persisted to Hermes's native memory and blocks on a hit.
# Governance gate: fails CLOSED when the scan is unavailable.

$ErrorActionPreference = 'SilentlyContinue'

$AI_CONFIG_DIR = '@@AI_CONFIG_DIR@@'

function Block([string]$Reason) {
    @{ decision = 'block'; reason = $Reason } | ConvertTo-Json -Compress
    exit 0
}

$inputRaw = [Console]::In.ReadToEnd()
try { $evt = $inputRaw | ConvertFrom-Json } catch { exit 0 }

# Every string value in tool_input — the memory tool's write surface.
$strings = [System.Collections.Generic.List[string]]::new()
function Collect($node) {
    if ($null -eq $node) { return }
    if ($node -is [string]) { [void]$strings.Add($node); return }
    if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
        foreach ($item in $node) { Collect $item }
        return
    }
    if ($node -is [pscustomobject]) {
        foreach ($p in $node.PSObject.Properties) { Collect $p.Value }
    }
}
Collect $evt.tool_input
$content = $strings -join "`n"
if (-not $content) { exit 0 }

$scan = Join-Path $AI_CONFIG_DIR 'scripts' 'check-memory-drift.ps1'
if (-not (Test-Path -LiteralPath $scan)) {
    Block "Memory-sanitize hook cannot find the injection scan at $scan — refusing to persist memory content until the framework checkout is restored."
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ms-" + [guid]::NewGuid().ToString('N') + '.md')
Set-Content -LiteralPath $tmp -Value $content
try {
    & pwsh -NoProfile -File $scan -InjectionScan $tmp *> $null
    if ($LASTEXITCODE -ne 0) {
        Block 'Memory persistence blocked: the content matches a prompt-injection payload class (chat-role spoof / override-instructions / persona flip / future-agent targeting / memory-write directive / prompt exfil). Native memory is injected into every future session, so hostile shapes must not persist. To document such a pattern legitimately, fence it in a code block and persist via a normal note instead.'
    }
}
finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
exit 0
