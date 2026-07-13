#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/run-resolve.test.ps1 — PS-5 fallback regression pin.
#
# Verifies that the $PSScriptRoot empty-string fallback pattern used by
# tests/run.ps1, scripts/install.ps1, scripts/validate.ps1, and the ported
# harness hooks produces a usable path even when $PSScriptRoot is empty.
#
# The pattern:
# if ($PSScriptRoot) {... } else { (Resolve-Path "$PWD/..").Path }
#
# is what PS-5 mandates. This test forces a $PSScriptRoot-empty
# context and asserts the fallback produces a working directory that contains
# a known anchor file (the repo's README.md). If the fallback regressed, the
# install.ps1 / validate.ps1 / hook scripts would silently use $PWD-relative
# paths under dot-source conditions and fail in non-obvious ways.

# tests/lib.ps1 is dot-sourced by tests/run.ps1 BEFORE each test file is
# dot-sourced; Assert-* helpers and counters are already in scope. Do NOT
# re-dot-source lib.ps1 here — it would zero the suite counters mid-run.

# Resolve $PWD against the repo root by walking up from tests/. The fallback
# pattern is: when $PSScriptRoot is empty, resolve "$PWD/.." — but in run.ps1
# the resolution is `Resolve-Path "$PWD"`, with $PWD assumed to point at
# tests/. In the install.ps1 / validate.ps1 fallback (where the script lives
# in scripts/), the resolution is `Resolve-Path "$PWD/.."` (one level up).
#
# This test verifies the install.ps1 / validate.ps1 fallback shape, the
# riskier of the two: a wrong $PWD assumption would cause every path lookup
# to be off by one directory.
$savedPwd = $PWD
try {
    # Set $PWD to the scripts/ subdirectory so the fallback should resolve up
    # to the repo root.
    $scriptsDir = Join-Path $env:REPO_ROOT 'scripts'
    Set-Location -LiteralPath $scriptsDir

    # Simulate the fallback branch (PSScriptRoot empty) explicitly. We don't
    # actually clear $PSScriptRoot — it's session-state. We just exercise the
    # pure expression the scripts use in their else branch.
    $fallbackRoot = (Resolve-Path "$PWD/..").Path

    # The fallback should produce the repo root, which contains README.md.
    Assert-File 'run-resolve.test: PSScriptRoot fallback resolves to repo root (README.md present)' (Join-Path $fallbackRoot 'README.md')

    # And it should match $env:REPO_ROOT (with separator normalization).
    $normFb   = $fallbackRoot.TrimEnd('/','\')
    $normRepo = ($env:REPO_ROOT).TrimEnd('/','\')
    Assert-Eq 'run-resolve.test: PSScriptRoot fallback equals REPO_ROOT' $normRepo $normFb
} finally {
    Set-Location -LiteralPath $savedPwd
}
