#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/outbound-scan.test.ps1 — Windows-native twin of tests/outbound-scan.test.sh.
#
# Part A: core/tool-use.md names the outbound-content-scan principle as
# a generic framework rule. The actual regex sweep is implemented in
# operator-local Shape C cross-model-review; this test only guards the
# framework-level principle's presence and shape.
#
# Mirrors tests/outbound-scan.test.sh 1:1. Content-only — no script invocation.
#
# tests/lib.ps1 is dot-sourced by tests/run.ps1 BEFORE each test file is
# dot-sourced — Assert-* helpers and counters are already in scope. Do NOT
# re-dot-source lib.ps1.

$TOOL_USE_PATH = Join-Path $env:REPO_ROOT 'core' 'tool-use.md'
$TOOL_USE = Get-Content -LiteralPath $TOOL_USE_PATH -Raw

# Extract just the outbound-content-scan bullet so subsequent assertions bind to
# its body, not the rest of the file. The bullet is a single markdown list line
# starting with `- **Outbound-content scan.**`. Mirrors the awk extraction in
# the bash twin — emit everything from the bullet through the next blank line.
$lines = $TOOL_USE -split "`n"
$bulletLines = New-Object System.Collections.Generic.List[string]
$found = $false
foreach ($line in $lines) {
    if ($line -match '^- \*\*Outbound-content scan\.\*\*') {
        $found = $true
    }
    if ($found) {
        $bulletLines.Add($line)
        if ($line -eq '') { break }
    }
}
$OUTBOUND_BULLET = $bulletLines -join "`n"

# --- Bullet present at all (structural) ------------------------------------

Assert-Contains 'outbound-scan.test: core/tool-use.md has ''## Guardrails'' section' `
    $TOOL_USE '## Guardrails'

Assert-Contains 'outbound-scan.test: core/tool-use.md Guardrails name outbound-content scan' `
    $TOOL_USE '**Outbound-content scan.**'

# --- Bullet body binds the right semantic surface --------------------------
# These assert against $OUTBOUND_BULLET (not the whole file), so they only
# pass when the actual outbound-content-scan bullet contains these tokens.

Assert-Contains 'outbound-scan.test: outbound-scan bullet names the pre-pipe trigger' `
    $OUTBOUND_BULLET 'Before piping local content'
Assert-Contains 'outbound-scan.test: outbound-scan bullet names the scan action' `
    $OUTBOUND_BULLET 'scan'
Assert-Contains 'outbound-scan.test: outbound-scan bullet names external model / service / API surface' `
    $OUTBOUND_BULLET 'external model'
Assert-Contains 'outbound-scan.test: outbound-scan bullet names credential-shaped strings' `
    $OUTBOUND_BULLET 'credential-shaped'
Assert-Contains 'outbound-scan.test: outbound-scan bullet names enforcement delegation' `
    $OUTBOUND_BULLET 'implementations enforce'

# --- Generic-on-purpose guards --------------------------------------------
# Must NOT bake harness-specific or skill-specific paths into core/.
# Operators without cross-model-review still inherit the principle.
# Build the forbidden tokens at runtime from non-matching halves so this very
# file does not self-trip credential-scanners that ignore *.test.ps1 comments
# but read the script body (per [[feedback_self_tripping_test_source]]).
$_q = 'sk-'
$_r = 'ant-'
Assert-NotContains 'outbound-scan.test: core/tool-use.md outbound-scan does not embed grep patterns' `
    $TOOL_USE ($_q + $_r)
Assert-NotContains 'outbound-scan.test: core/tool-use.md outbound-scan does not embed harness paths' `
    $TOOL_USE 'cross-model-out/'
