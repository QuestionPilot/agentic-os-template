#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/fresh-clone-validate.test.ps1 — Windows-native twin of
# tests/fresh-clone-validate.test.sh.
#
# T-90B: validate.ps1 must exit 0 on a fresh clone with no operator
# tools installed (codegraph, agy, superpowers). Same hermetic-PATH
# discipline as the bash twin.
#
# Mirrors tests/fresh-clone-validate.test.sh 1:1.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$VALIDATE_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'validate.ps1'
Assert-File 'fresh-clone-validate.test: scripts/validate.ps1 exists' $VALIDATE_PS1

# Minimal PATH discipline mirrors the bash twin's `MINIMAL_PATH=/usr/bin:/bin:/usr/sbin:/sbin`
# pattern. On Unix-flavored hosts (macOS/Linux) that POSIX baseline carries
# all the standard utilities (git/jq/awk/grep/etc.) validate.ps1 needs. On
# Windows-native pwsh, the POSIX paths don't exist — instead the runner's
# tools live under C:\Program Files\Git\bin, C:\hostedtoolcache\..., etc.
# Stripping the entire PATH would also strip git, jq, and other tools
# validate.ps1 legitimately calls — which is NOT the fresh-clone scenario
# (the bash twin's MINIMAL_PATH leaves git/jq present too; only the operator-
# tool dirs are absent).
#
# Approach: instead of hard PATH replacement, dynamically prune entries from
# the current PATH that contain operator tools (codegraph/agy). The
# operator tools live under directories specific to operator installs;
# subtracting those leaves the system tools intact AND removes operator-
# tool visibility.
$savedPath = $env:PATH

# Find dirs hosting any of the operator tools and exclude them from PATH.
# This is more robust than guessing operator-install paths, and matches the
# bash twin's "no operator tools on PATH" assertion intent without breaking
# the standard system tools the test-target script needs.
$opToolDirs = New-Object System.Collections.Generic.HashSet[string]
foreach ($tool in @('codegraph', 'agy', 'pp-linear', 'linctl', 'schpet')) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        [void]$opToolDirs.Add((Split-Path -Parent $cmd.Source))
    }
}

$pathSep = if ($IsWindows) { ';' } else { ':' }
$pathDirs = $savedPath -split $pathSep
$minPathDirs = @($pathDirs | Where-Object {
    $entry = $_.TrimEnd('\', '/')
    -not $opToolDirs.Contains($entry) -and `
    -not ($entry -match '/\.local/bin$' -or $entry -match '\\\.local\\bin$')
})
$minPath = $minPathDirs -join $pathSep

try {
    $env:PATH = $minPath

    # Confirm we're stripping the operator tools — they should be absent under MINIMAL_PATH.
    foreach ($tool in @('codegraph', 'agy')) {
        $found = $null -ne (Get-Command $tool -ErrorAction SilentlyContinue)
        if ($found) {
            _Fail "fresh-clone-validate.test: fresh-clone PATH still has $tool" `
                "MINIMAL_PATH=$minPath includes $tool — fix the test setup"
        }
    }

    # Run validate.ps1 under the minimal PATH.
    $fresh_out = & pwsh -NoProfile -File $VALIDATE_PS1 2>&1
    $fresh_rc = $LASTEXITCODE
    if ($fresh_out -is [array]) { $fresh_out = $fresh_out -join "`n" }

    if ($fresh_rc -eq 0) {
        _Pass 'fresh-clone-validate.test: validate.ps1 exits 0 with no operator tools on PATH'
    } else {
        $snippet = if ($fresh_out.Length -gt 400) { $fresh_out.Substring(0, 400) } else { $fresh_out }
        _Fail 'fresh-clone-validate.test: validate.ps1 fails on fresh clone (no operator tools)' `
            "exit=$fresh_rc; first 400 chars of output: $snippet"
    }

    # Defensive: any FAIL line mentioning a known operator tool is a leak.
    # Runtime-construct the tool sentinels per [[feedback_self_tripping_test_source]].
    $TOOL_CODEGRAPH = 'code' + 'graph'
    $TOOL_SUPERPOWERS = 'super' + 'powers'
    $TOOL_AGY = 'a' + 'gy'
    $fail_re = "^FAIL .*($TOOL_CODEGRAPH|$TOOL_SUPERPOWERS|$TOOL_AGY)"
    if ($fresh_out -cmatch "(?m)$fail_re") {
        _Fail 'fresh-clone-validate.test: validate.ps1 has tool-presence FAIL on fresh clone' `
            'output mentions FAIL near a tool name'
    } else {
        _Pass 'fresh-clone-validate.test: validate.ps1 output contains no tool-presence FAIL lines'
    }
} finally {
    $env:PATH = $savedPath
}
