#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    _Skip 'session-index race regression PS' 'node not installed'
} else {
    $fixture = Join-Path $env:REPO_ROOT 'tests' 'session-index-race.test.js'
    $generator = Join-Path $env:REPO_ROOT 'obsidian' 'vault-scaffolding' 'bin' 'generate-session-index.js'
    $output = (& $node.Source $fixture $generator 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    Assert-Eq 'session-index race fixture PS exits 0' '0' "$exitCode"
    Assert-Contains 'session-index race fixture PS proves stale writer is blocked' $output 'PASS concurrent writer refuses active owner'
    Assert-Contains 'session-index race fixture PS proves new receipt is reconciled once' $output 'PASS final view contains B once'
    Assert-Contains 'session-index race fixture PS proves failed rename keeps old bytes' $output 'PASS failed rename preserves prior view'
}
