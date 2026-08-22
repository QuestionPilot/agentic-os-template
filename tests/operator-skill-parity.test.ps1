#!/usr/bin/env pwsh
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/operator-skill-parity.test.ps1 — PowerShell twin of
# tests/operator-skill-parity.test.sh.
#
# Unit acceptance for scripts/operator-skill-parity-check.ps1: in-sync → PASS
# with the right denominator; planted content drift → DRIFT + exit 1 (positive
# control); allowlisted pair → VARIANT + exit 0; a skill absent from a mirror →
# MISSING + exit 1; no mirror root present → FAIL (never a silent PASS);
# manifest-managed skills excluded; a missing canonical root → FAIL; a path
# containing a space handled intact.
#
# Dot-sourced by tests/run.ps1; uses Assert-* from tests/lib.ps1.

$OSP = Join-Path $env:REPO_ROOT 'scripts' 'operator-skill-parity-check.ps1'
Assert-File 'operator-skill-parity-check.ps1 present' $OSP

function New-OspTmp {
    $p = Join-Path ([IO.Path]::GetTempPath()) ('operator-skill-parity-' + [Guid]::NewGuid().Guid.Substring(0, 8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

# New-OspFixture <dir> — canonical root at "<dir>/home a/skills" (the SPACE is
# deliberate: the parallel-list contract exists because render-home paths
# contain spaces) with two unmanaged skills (alpha, beta) plus one
# manifest-managed skill (session-agent, whose mirror copies DIFFER so an
# exclusion regression shows up as a DRIFT line). Mirrors m1 + m2 start in sync.
function New-OspFixture([string]$d) {
    $c = Join-Path $d 'home a/skills'
    foreach ($s in 'alpha', 'beta', 'session-agent') {
        New-Item -ItemType Directory -Path (Join-Path $c $s) -Force | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $c 'alpha/SKILL.md'), "alpha body`n")
    [IO.File]::WriteAllText((Join-Path $c 'beta/SKILL.md'), "beta body`n")
    [IO.File]::WriteAllText((Join-Path $c 'session-agent/SKILL.md'), "canonical spine render`n")
    [IO.File]::WriteAllText((Join-Path $d 'home a/.build-manifest.json'),
        '{"harness":"claude","generated":{"skills/session-agent/SKILL.md":"deadbeef","settings.json":"cafe"}}')
    foreach ($m in 'm1', 'm2') {
        foreach ($s in 'alpha', 'beta', 'session-agent') {
            New-Item -ItemType Directory -Path (Join-Path $d "$m/skills/$s") -Force | Out-Null
        }
        [IO.File]::WriteAllText((Join-Path $d "$m/skills/alpha/SKILL.md"), "alpha body`n")
        [IO.File]::WriteAllText((Join-Path $d "$m/skills/beta/SKILL.md"), "beta body`n")
        [IO.File]::WriteAllText((Join-Path $d "$m/skills/session-agent/SKILL.md"), "per-harness $m spine render`n")
    }
}

# Invoke-Osp — run the script in a child pwsh against a fixture. Sets the
# SKILL_PARITY_* env vars for the child and clears them afterwards.
# AI_CONFIG_LOCAL_ENV points at a nonexistent file so the operator's real
# local.env can never leak into a fixture run. Returns the combined output;
# $script:OspRc carries the exit code.
function Invoke-Osp {
    param([string]$Dir, [string]$Allow = '', [string]$Mirrors = '', [string]$Canonical = '')
    if ([string]::IsNullOrEmpty($Mirrors)) {
        $Mirrors = "m1=$(Join-Path $Dir 'm1/skills'),m2=$(Join-Path $Dir 'm2/skills')"
    }
    if ([string]::IsNullOrEmpty($Canonical)) { $Canonical = (Join-Path $Dir 'home a/skills') }
    $env:AI_CONFIG_LOCAL_ENV     = Join-Path $Dir 'no-such-local.env'
    $env:SKILL_PARITY_CANONICAL  = $Canonical
    $env:SKILL_PARITY_MIRRORS    = $Mirrors
    $env:SKILL_PARITY_ALLOWLIST  = $Allow
    try {
        $out = (& pwsh -NoProfile -File $OSP 2>&1 | Out-String)
        $script:OspRc = $LASTEXITCODE
    } finally {
        Remove-Item Env:AI_CONFIG_LOCAL_ENV    -ErrorAction SilentlyContinue
        Remove-Item Env:SKILL_PARITY_CANONICAL -ErrorAction SilentlyContinue
        Remove-Item Env:SKILL_PARITY_MIRRORS   -ErrorAction SilentlyContinue
        Remove-Item Env:SKILL_PARITY_ALLOWLIST -ErrorAction SilentlyContinue
    }
    return $out
}

# --- (a) in-sync mirrors PASS with the correct denominator ------------------
# 2 unmanaged skills x 2 mirror roots = 4 comparisons. The denominator is
# load-bearing: a PASS that compared nothing is what this gate exists to catch.
$D1 = New-OspTmp; New-OspFixture $D1
$o = Invoke-Osp -Dir $D1
Assert-Eq       'operator-skill-parity: in-sync exits 0'     '0' "$script:OspRc"
Assert-Contains 'operator-skill-parity: in-sync prints PASS' $o  'PASS operator-skill parity'
Assert-Contains 'operator-skill-parity: denominator is 4 across 2 of 2' `
    $o '4 comparison(s) across 2 of 2 mirror root(s)'

# --- (f) manifest-managed (spine) skills are excluded -----------------------
Assert-NotContains 'operator-skill-parity: manifest-managed skill not compared' $o 'session-agent'

# --- no-manifest fallback compares everything (and says so) -----------------
Move-Item (Join-Path $D1 'home a/.build-manifest.json') (Join-Path $D1 'manifest.bak')
$o = Invoke-Osp -Dir $D1
Assert-Eq       'operator-skill-parity: no manifest → exit 1 (spine now compared)' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: no manifest prints NOTE'    $o 'NOTE   no build manifest at'
Assert-Contains 'operator-skill-parity: no manifest compares spine' $o 'DRIFT   m1       session-agent'
Remove-Item -Recurse -Force $D1

# --- (b) planted content drift → DRIFT + exit 1 (positive control) ----------
$D2 = New-OspTmp; New-OspFixture $D2
[IO.File]::WriteAllText((Join-Path $D2 'm2/skills/alpha/SKILL.md'), "alpha body EDITED`n")
$o = Invoke-Osp -Dir $D2
Assert-Eq       'operator-skill-parity: planted drift exits 1'        '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: planted drift names the pair' $o 'DRIFT   m2       alpha'
Assert-Contains 'operator-skill-parity: planted drift prints FAIL'    $o 'FAIL operator-skill parity drift'
Assert-NotContains 'operator-skill-parity: clean mirror not flagged'  $o 'DRIFT   m1'

# --- (c) allowlisted variant → VARIANT + exit 0 -----------------------------
$o = Invoke-Osp -Dir $D2 -Allow 'm2/alpha'
Assert-Eq       'operator-skill-parity: allowlisted variant exits 0' '0' "$script:OspRc"
Assert-Contains 'operator-skill-parity: allowlisted prints VARIANT'  $o 'VARIANT m2       alpha (allowlisted)'
Assert-NotContains 'operator-skill-parity: allowlisted prints no DRIFT' $o 'DRIFT'
Assert-Contains 'operator-skill-parity: allowlisted still PASSes with denominator' `
    $o '4 comparison(s) across 2 of 2 mirror root(s)'

# An allowlist entry for a DIFFERENT root must not excuse this one — membership
# is on the whole `<label>/<skill>` pair, not the skill name.
$o = Invoke-Osp -Dir $D2 -Allow 'm1/alpha'
Assert-Eq       'operator-skill-parity: allowlist is per-root, not per-skill' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: wrong-root allowlist still DRIFTs'    $o 'DRIFT   m2       alpha'
Remove-Item -Recurse -Force $D2

# --- (d) missing skill dir in a mirror → MISSING + exit 1 -------------------
$D3 = New-OspTmp; New-OspFixture $D3
Remove-Item -Recurse -Force (Join-Path $D3 'm1/skills/beta')
$o = Invoke-Osp -Dir $D3
Assert-Eq       'operator-skill-parity: missing skill exits 1'  '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: missing skill reported' $o 'MISSING m1       beta'
Assert-NotContains 'operator-skill-parity: missing is not reported as DRIFT' $o 'DRIFT'
Remove-Item -Recurse -Force $D3

# --- (e) zero mirror roots present → FAIL, never a silent PASS --------------
$D4 = New-OspTmp; New-OspFixture $D4
$o = Invoke-Osp -Dir $D4 -Mirrors "m1=$(Join-Path $D4 'absent-1/skills'),m2=$(Join-Path $D4 'absent-2/skills')"
Assert-Eq       'operator-skill-parity: zero present roots exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: zero present roots FAILs loudly' $o 'FAIL no mirror root was present'
Assert-NotContains 'operator-skill-parity: zero present roots never PASSes' $o 'PASS'
Assert-Contains 'operator-skill-parity: absent root SKIP is loud' $o 'SKIP   m1       root not present'

# --- one root present, one absent → compares, denominator says 1 of 2 -------
$o = Invoke-Osp -Dir $D4 -Mirrors "m1=$(Join-Path $D4 'm1/skills'),gone=$(Join-Path $D4 'absent/skills')"
Assert-Eq       'operator-skill-parity: partial roots exits 0' '0' "$script:OspRc"
Assert-Contains 'operator-skill-parity: partial roots denominator is 2 across 1 of 2' `
    $o '2 comparison(s) across 1 of 2 mirror root(s)'
Remove-Item -Recurse -Force $D4

# --- missing canonical root → FAIL (fail loud, never open) ------------------
$D5 = New-OspTmp
$o = Invoke-Osp -Dir $D5 -Canonical (Join-Path $D5 'nope/skills') -Mirrors "m1=$(Join-Path $D5 'm1/skills')"
Assert-Eq       'operator-skill-parity: missing canonical root exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: missing canonical root FAILs'   $o 'FAIL canonical skill root missing'

# --- no canonical root configured at all → FAIL -----------------------------
$env:AI_CONFIG_LOCAL_ENV    = Join-Path $D5 'no-such-local.env'
$env:SKILL_PARITY_CANONICAL = ''
$env:CLAUDE_CONFIG_DIR      = ''
$env:SKILL_PARITY_MIRRORS   = "m1=$(Join-Path $D5 'm1/skills')"
$o = (& pwsh -NoProfile -File $OSP 2>&1 | Out-String); $rc = $LASTEXITCODE
Assert-Eq       'operator-skill-parity: unconfigured canonical exits 1' '1' "$rc"
Assert-Contains 'operator-skill-parity: unconfigured canonical names the key' $o 'set SKILL_PARITY_CANONICAL'

# --- no mirror configured at all → FAIL, not a vacuous PASS -----------------
$env:SKILL_PARITY_CANONICAL = $D5
$env:SKILL_PARITY_MIRRORS   = ''
$env:CODEX_HOME             = ''
$env:AGENTS_DIR             = ''
$env:CURSOR_CONFIG_DIR      = ''
$o = (& pwsh -NoProfile -File $OSP 2>&1 | Out-String); $rc = $LASTEXITCODE
Assert-Eq       'operator-skill-parity: no mirror configured exits 1' '1' "$rc"
Assert-Contains 'operator-skill-parity: no mirror configured FAILs'   $o 'FAIL no mirror skill root configured'
foreach ($k in 'AI_CONFIG_LOCAL_ENV', 'SKILL_PARITY_CANONICAL', 'SKILL_PARITY_MIRRORS',
               'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'AGENTS_DIR', 'CURSOR_CONFIG_DIR') {
    Remove-Item "Env:$k" -ErrorAction SilentlyContinue
}
Remove-Item -Recurse -Force $D5

# --- bare-path mirror entry derives its label from the render home ----------
# `<home>/.codex/skills` → label `codex` (leading dot stripped).
$D6 = New-OspTmp; New-OspFixture $D6
New-Item -ItemType Directory -Path (Join-Path $D6 '.codex') -Force | Out-Null
Copy-Item -Recurse (Join-Path $D6 'm1/skills') (Join-Path $D6 '.codex/skills')
[IO.File]::WriteAllText((Join-Path $D6 '.codex/skills/alpha/SKILL.md'), "alpha body EDITED`n")
$o = Invoke-Osp -Dir $D6 -Mirrors (Join-Path $D6 '.codex/skills')
Assert-Eq       'operator-skill-parity: bare-path mirror exits 1 on drift' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: bare-path mirror label is ''codex''' $o 'DRIFT   codex    alpha'
Remove-Item -Recurse -Force $D6

# --- canonical with no unmanaged skills → SKIP, exit 0 ----------------------
$D7 = New-OspTmp
New-Item -ItemType Directory -Path (Join-Path $D7 'home a/skills/session-agent') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $D7 'm1/skills') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $D7 'home a/skills/session-agent/SKILL.md'), "x`n")
[IO.File]::WriteAllText((Join-Path $D7 'home a/.build-manifest.json'),
    '{"generated":{"skills/session-agent/SKILL.md":"h"}}')
$o = Invoke-Osp -Dir $D7 -Mirrors "m1=$(Join-Path $D7 'm1/skills')"
Assert-Eq       'operator-skill-parity: nothing unmanaged exits 0' '0' "$script:OspRc"
Assert-Contains 'operator-skill-parity: nothing unmanaged SKIPs'   $o 'SKIP   no unmanaged skills to compare'
Remove-Item -Recurse -Force $D7
