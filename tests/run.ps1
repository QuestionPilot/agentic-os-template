#Requires -Version 7
# tests/run.ps1 — discovers and runs every tests/*.test.ps1, prints a summary.
#
# Test files are DOT-SOURCED, not executed: a bare `exit` in a *.test.ps1 file
# would kill this runner and suppress the summary. Test files must only call
# Assert-* helpers and must never call `exit` directly. (Each test file carries a
# standalone-invocation guard that DOES exit non-zero, but only when the Assert-*
# helpers are absent — i.e. never when dot-sourced here. See any tests/*.test.ps1 top.)
#
# Optional first argument -Filter: a targeted-run substring matched against each
# test file's name, so `pwsh tests/run.ps1 drift` runs only the files whose name
# contains "drift" (mirrors tests/run.sh's positional filter). This is the
# supported path for a targeted run (a bare `pwsh -File tests/foo.test.ps1` bails
# via that file's guard). With no argument every test file runs, unchanged.
#
# Mirrors tests/run.sh.
#
# $env:TEST_TIER (default 'full'): 'fast' skips slow-marked files for a quick
# inner loop; 'full' runs everything. See tests/TIERS.md and the tier helpers
# in tests/lib.ps1.
#
# PS-5 — $PSScriptRoot is empty when this script is dot-
# sourced or invoked through certain wrappers. Fall back to a $PWD-anchored
# resolution so dot-source paths still work. The unit test
# tests/run-resolve.test.ps1 verifies the fallback path; see the §"PS-5"
# block in docs/superpowers/specs/2026-05-27-windows-native-prototype.md.

# Targeted-run filter. Empty = run every file (the `$Filter -and`
# short-circuits below), so the no-argument path is unchanged.
param([string]$Filter = '')

if ($PSScriptRoot) {
    $testsDir = $PSScriptRoot
} else {
    $testsDir = (Resolve-Path "$PWD").Path
}
$repoRoot = Split-Path $testsDir -Parent
$env:REPO_ROOT = $repoRoot

# Isolate the harness config-dir env vars for the WHOLE suite (mirrors run.sh).
# A render test resolves its build target from CLAUDE_CONFIG_DIR / CODEX_HOME /
# HERMES_HOME whenever its fixture local.env does not set them; an inherited
# co-located value would leak the LIVE config dir into a throwaway build and
# overwrite the operator's real entrypoint. Clearing them makes a live-folder run
# behave like a clean clone. Tests that need one set it themselves per-invocation.
Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
Remove-Item Env:CODEX_HOME        -ErrorAction SilentlyContinue
Remove-Item Env:HERMES_HOME       -ErrorAction SilentlyContinue

# Dot-source the assertion library so counters and helpers live in this scope.
# (Counters are $script:-scoped; dot-source makes lib.ps1's $script: scope =
# run.ps1's scope, which is also the scope each.test.ps1 dot-sources into.)
. (Join-Path $testsDir 'lib.ps1')

$testFiles = @(Get-ChildItem -LiteralPath $testsDir -Filter '*.test.ps1' -File -ErrorAction SilentlyContinue)

if ($testFiles.Count -eq 0) {
    [Console]::Error.WriteLine("FAIL no test files found in $testsDir")
    exit 1
}

$matched = $false
$sourcedAny = $false
foreach ($tf in $testFiles) {
    # Targeted-run filter: skip files whose name does not contain $Filter.
    # `$Filter -and` short-circuits when empty, so the no-argument path is
    # unchanged. .Contains() is an ORDINAL, LITERAL, case-sensitive substring
    # test — byte-parity with the bash twin's `case *"$filter"*` (a wildcard
    # -like match would interpret `[`/`*` and compare case-insensitively).
    if ($Filter -and -not $tf.Name.Contains($Filter)) { continue }
    $matched = $true
    if (-not (Test-TierShouldRun -Path $tf.FullName)) {
        $tierName = $env:TEST_TIER; if (-not $tierName) { $tierName = 'full' }
        Write-Host "`n== $($tf.Name) == — skipped (TEST_TIER=$tierName)"
        continue
    }
    $sourcedAny = $true
    Write-Host "`n== $($tf.Name) ==`n"
    . $tf.FullName
}

# A non-empty filter that matched nothing is a caller error, not a silent pass
# (an empty run would print Total: 0 and exit 0 — the false-green this guard closes).
if ($Filter -and -not $matched) {
    [Console]::Error.WriteLine("FAIL no test files matched filter: $Filter")
    exit 1
}

# A filter whose every match was tier-skipped is the same false green through a
# different door: Total: 0 + exit 0 while the requested test never ran. Distinct
# message from the no-match case so the caller sees WHICH gate tripped.
if ($Filter -and -not $sourcedAny) {
    $tierName = $env:TEST_TIER; if (-not $tierName) { $tierName = 'full' }
    [Console]::Error.WriteLine("FAIL filter matched only tier-skipped files (TEST_TIER=$tierName) — run with TEST_TIER=full")
    exit 1
}

Write-Host "`n----------------------------------------"
Write-Host "Total: $($script:TESTS_RUN)   Failed: $($script:TESTS_FAILED)"

if ($script:TESTS_FAILED -gt 0) {
    exit 1
}

Write-Host 'PASS acceptance suite'
