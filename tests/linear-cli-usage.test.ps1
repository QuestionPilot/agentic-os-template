#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/linear-cli-usage.test.ps1 — Windows-native twin of
# tests/linear-cli-usage.test.sh: drift tripwire for the static `linear` CLI
# usage fixture (linear/linear-cli-usage.md).
#
# Three layers (see the .sh twin's header for rationale):
#   T1 (hermetic)  — fixture exists, names the installer's pinned tag, stays
#                    under the 4500-byte load budget.
#   T2 (hermetic)  — the load-bearing contracts survive rewrites (.nodes
#                    unwrap, explicit open states, team scope).
#   T3 (live-only) — when the PINNED binary is on PATH, every command group
#                    the fixture names exists in `linear --help`. Named skip
#                    (never silent) when absent or version-mismatched.

$lcuFixture = Join-Path $env:REPO_ROOT 'linear' 'linear-cli-usage.md'
$lcuInstaller = Join-Path $env:REPO_ROOT 'scripts' 'install-linear-cli.sh'

# --- T1: fixture exists, version-pinned, and small ---------------------------
Assert-File 'linear-cli-usage.test: fixture exists' $lcuFixture

$lcuPin = ''
$pinLine = Select-String -Path $lcuInstaller -Pattern '^LINEAR_CLI_DEFAULT_VERSION="([^"]+)"$' | Select-Object -First 1
if ($pinLine) { $lcuPin = $pinLine.Matches[0].Groups[1].Value }
Assert-Contains 'linear-cli-usage.test: installer default pin parsed (sanity)' "v:$lcuPin" 'v:v'

$lcuBody = Get-Content -Raw $lcuFixture -ErrorAction SilentlyContinue
Assert-Contains "linear-cli-usage.test: fixture names the installer's pinned version ($lcuPin)" $lcuBody $lcuPin

$lcuBytes = (Get-Item $lcuFixture).Length
$lcuSizeVerdict = if ($lcuBytes -le 4500) { 'under-budget' } else { 'OVER-budget' }
Assert-Eq "linear-cli-usage.test: fixture stays under the 4500-byte load budget (${lcuBytes}B)" 'under-budget' $lcuSizeVerdict

# --- T2: the two load-bearing contracts survive rewrites ---------------------
Assert-Contains 'linear-cli-usage.test: fixture teaches the .nodes unwrap contract' $lcuBody '.nodes'
Assert-Contains 'linear-cli-usage.test: fixture teaches the explicit open-states contract' $lcuBody '-s triage -s backlog -s unstarted -s started'
Assert-Contains 'linear-cli-usage.test: fixture teaches the team-scope contract' $lcuBody '--all-teams'

# --- T3: live drift check against the pinned binary (skip when absent) -------
$ansi = [char]27 + '\[[0-9;]*[A-Za-z]'
$lcuLiveVersion = ''
if (Get-Command linear -ErrorAction SilentlyContinue) {
    $verOut = (& linear --version 2>$null | Out-String) -replace $ansi, ''
    if ($verOut -match '(\d+\.\d+\.\d+)') { $lcuLiveVersion = $Matches[1] }
}

if ($lcuLiveVersion -and ("v$lcuLiveVersion" -eq $lcuPin)) {
    $lcuHelp = (& linear --help 2>&1 | Out-String) -replace $ansi, ''
    foreach ($grp in @('auth', 'issue', 'team', 'user', 'project', 'project-update',
                       'cycle', 'milestone', 'initiative', 'initiative-update',
                       'label', 'document', 'completions', 'config', 'schema', 'api')) {
        Assert-Contains "linear-cli-usage.test: pinned binary still exposes command group: $grp" $lcuHelp $grp
    }
    $lcuIssueHelp = (& linear issue --help 2>&1 | Out-String) -replace $ansi, ''
    foreach ($sub in @('query', 'view', 'create', 'update', 'comment', 'relation')) {
        Assert-Contains "linear-cli-usage.test: pinned binary still exposes issue subcommand: $sub" $lcuIssueHelp $sub
    }
    # orient's mine cut parses "Display name:" out of `auth whoami` TEXT output —
    # an upstream rewording would silently degrade that cut, so pin the field
    # here (mirrors the .sh twin's rationale).
    $lcuWhoami = (& linear auth whoami 2>&1 | Out-String) -replace $ansi, ''
    Assert-Contains 'linear-cli-usage.test: pinned binary whoami still prints the Display name field' $lcuWhoami 'Display name:'
} else {
    # Named skip, mirroring the .sh twin: absence and version-mismatch are
    # legitimate local states, but visible ones.
    $liveLabel = if ($lcuLiveVersion) { $lcuLiveVersion } else { 'absent' }
    Write-Host "note: linear-cli-usage T3 live drift check skipped (binary $liveLabel, pin $lcuPin)"
}
