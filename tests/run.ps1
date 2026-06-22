#Requires -Version 7
# tests/run.ps1 — discovers and runs every tests/*.test.ps1, prints a summary.
#
# Test files are DOT-SOURCED, not executed: a bare `exit` in a *.test.ps1 file
# would kill this runner and suppress the summary. Test files must only call
# Assert-* helpers and must never call `exit` directly.
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

foreach ($tf in $testFiles) {
    if (-not (Test-TierShouldRun -Path $tf.FullName)) {
        $tierName = $env:TEST_TIER; if (-not $tierName) { $tierName = 'full' }
        Write-Host "`n== $($tf.Name) == — skipped (TEST_TIER=$tierName)"
        continue
    }
    Write-Host "`n== $($tf.Name) ==`n"
    . $tf.FullName
}

Write-Host "`n----------------------------------------"
Write-Host "Total: $($script:TESTS_RUN)   Failed: $($script:TESTS_FAILED)"

if ($script:TESTS_FAILED -gt 0) {
    exit 1
}

Write-Host 'PASS acceptance suite'
