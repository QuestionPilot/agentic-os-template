#Requires -Version 7
# Vault-index steward — Windows twin of steward.sh. SHIPPED UNREGISTERED;
# scheduling it is a deliberate operator act. Same cost discipline:
# skip-when-no-delta, one regenerate-and-recheck cycle, daily cap (4).

$ErrorActionPreference = 'SilentlyContinue'

$VAULT = '@@OBSIDIAN_VAULT_PATH@@'
$hhome = Split-Path -Parent $PSScriptRoot
if (-not $hhome) {
    $hhome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $HOME '.hermes' }
}
$stateDir = Join-Path $hhome 'agentic-os'
$stampFile = Join-Path $stateDir 'steward-runs'
$log = Join-Path $stateDir 'steward.log'
$DAILY_CAP = 4

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')

function Note([string]$Msg) {
    Add-Content -LiteralPath $log -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $Msg)
}

if ($args.Count -gt 0 -and $args[0] -eq '--status') {
    if (Test-Path -LiteralPath $stampFile) { Get-Content -LiteralPath $stampFile } else { 'no runs recorded' }
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 3 }
    exit 0
}

# Daily cap.
$count = 0
if (Test-Path -LiteralPath $stampFile) {
    $parts = (Get-Content -LiteralPath $stampFile -First 1) -split ' '
    if ($parts[0] -eq $today) { $count = [int]$parts[1] }
}
if ($count -ge $DAILY_CAP) {
    Note "daily cap reached ($count/$DAILY_CAP) — skipping"
    exit 0
}
Set-Content -LiteralPath $stampFile -Value ("{0} {1}" -f $today, ($count + 1))

$gen = Join-Path $VAULT 'bin' 'generate-harness-index.js'
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not (Test-Path -LiteralPath $gen) -or -not $node) {
    Note 'generator or node unavailable — nothing to steward'
    exit 0
}

# Skip-when-no-delta.
& node $gen --check *> $null
if ($LASTEXITCODE -eq 0) {
    Note 'no delta — views match regeneration; skipping'
    exit 0
}

# Iteration bound: exactly one regenerate-and-recheck cycle.
& node $gen *> $null
& node $gen --check *> $null
if ($LASTEXITCODE -eq 0) {
    Note 'reconciled — views regenerated'
    exit 0
}

Note 'CONFLICT — views still drift after one regeneration; flagging for the operator (no retry)'
exit 1
