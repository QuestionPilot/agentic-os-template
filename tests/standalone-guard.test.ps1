#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/standalone-guard.test.ps1 — Windows-native twin of
# tests/standalone-guard.test.sh. Meta-test for the standalone-invocation
# guard and the runner's targeted-run filter.
#
# Three things are pinned (mirrors the bash twin 1:1):
# (a) SHAPE: every tests/*.test.sh carries the bash guard marker and every
#     tests/*.test.ps1 carries the PS guard marker.
# (b) BEHAVIOR: a standalone invocation of one real test file per language exits
#     non-zero and prints the run-via-runner message.
# (c) FILTER: the runner's targeted-run filter selects only the matching file and
#     exits 0.
#
# Markers (byte-identical guard lines): bash → `declare -F assert_exit`,
# ps → `Get-Command Assert-Exit`. This is a .ps1 file, so the *.test.sh
# enumeration in (a) never scans it; it matches its own PS marker as every twin
# must.
#
# Dot-sourced by tests/run.ps1; Assert-* helpers + counters already in scope. The
# guard above is the only `exit`, and it never fires when dot-sourced.

$sgTestsDir  = Join-Path $env:REPO_ROOT 'tests'
$sgBashMarker = 'declare -F assert_exit'
$sgPsMarker   = 'Get-Command Assert-Exit'

# --- (a) every twin carries its guard marker ---------------------------------
$sgMissingSh = @(
    Get-ChildItem -LiteralPath $sgTestsDir -Filter '*.test.sh' -File |
        Where-Object { -not (Select-String -LiteralPath $_.FullName -SimpleMatch -Pattern $sgBashMarker -Quiet) } |
        ForEach-Object { $_.Name }
)
Assert-Eq 'every tests/*.test.sh carries the standalone guard' '' ($sgMissingSh -join ' ')

$sgMissingPs = @(
    Get-ChildItem -LiteralPath $sgTestsDir -Filter '*.test.ps1' -File |
        Where-Object { -not (Select-String -LiteralPath $_.FullName -SimpleMatch -Pattern $sgPsMarker -Quiet) } |
        ForEach-Object { $_.Name }
)
Assert-Eq 'every tests/*.test.ps1 carries the standalone guard' '' ($sgMissingPs -join ' ')

# --- (b) a standalone invocation actually bails ------------------------------
$sgOut = (& pwsh -NoProfile -File (Join-Path $sgTestsDir 'drift.test.ps1') 2>&1) -join "`n"
$sgRc  = $LASTEXITCODE
Assert-Eq 'standalone pwsh test file exits non-zero' 'True' "$($sgRc -ne 0)"
Assert-Contains 'standalone pwsh test file prints the run-via-runner message' `
    $sgOut 'run via tests/run.ps1'

# --- (c) the targeted-run filter selects only the matching file --------------
# `tiers` matches exactly one fast test stem (tiers.test.ps1). Nested runner runs
# in its own pwsh subprocess (own counters); only exit code + output are inspected.
$sgFilterOut = (& pwsh -NoProfile -File (Join-Path $sgTestsDir 'run.ps1') tiers 2>&1) -join "`n"
$sgFilterRc  = $LASTEXITCODE
Assert-Eq 'targeted-run filter (tiers) exits 0' '0' "$sgFilterRc"
Assert-Contains 'targeted-run filter actually ran the matched file' `
    $sgFilterOut 'tiers.test.ps1'
Assert-NotContains 'targeted-run filter excluded non-matching files' `
    $sgFilterOut 'drift.test.ps1'
