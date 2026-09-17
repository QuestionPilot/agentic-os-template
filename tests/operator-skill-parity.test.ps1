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
# containing a space handled intact. Hermes consumes the Capability Map subset,
# declared variants use their named source pair, and an absent Hermes root fails.
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

# New-OspMap <dir> — alpha is expected on Hermes; beta's absence is intentional.
function New-OspMap([string]$d) {
    [IO.File]::WriteAllText((Join-Path $d 'Capability Map.md'), @'
| Skill | What | Where |
| --- | --- | --- |
| `alpha` | expected | all |
| `beta` | intentional absence | claude, codex |
| `session-agent` | managed | all |
'@)
}

# New-OspCaseMap <dir> — mixed-case headers and Hermes/All Where tokens.
function New-OspCaseMap([string]$d) {
    [IO.File]::WriteAllText((Join-Path $d 'Capability Map.md'), @'
| sKiLl | What | wHeRe |
| --- | --- | --- |
| `alpha` | Hermes casing | HeRmEs |
| `beta` | All casing | ALL |
| `session-agent` | managed | aLl |
'@)
}

# New-OspTwoColumnMap <dir> <with-final-pipe> — the minimum accepted Skill /
# Where schema, with either trailing-pipe form.
function New-OspTwoColumnMap([string]$d, [bool]$WithFinalPipe) {
    $suffix = if ($WithFinalPipe) { ' |' } else { '' }
    [IO.File]::WriteAllText((Join-Path $d 'Capability Map.md'), @"
| Skill | Where$suffix
| :--- | :---$suffix
| ``alpha`` | all$suffix
| ``session-agent`` | all$suffix
"@)
}

# Invoke-Osp — run the script in a child pwsh against a fixture. Sets the
# SKILL_PARITY_* env vars for the child and clears them afterwards.
# AI_CONFIG_LOCAL_ENV points at a nonexistent file so the operator's real
# local.env can never leak into a fixture run. Returns the combined output;
# $script:OspRc carries the exit code.
function Invoke-Osp {
    param([string]$Dir, [string]$Allow = '', [string]$Mirrors = '', [string]$Canonical = '', [string]$Map = '', [string]$Variants = '')
    if ([string]::IsNullOrEmpty($Mirrors)) {
        $Mirrors = "m1=$(Join-Path $Dir 'm1/skills'),m2=$(Join-Path $Dir 'm2/skills')"
    }
    if ([string]::IsNullOrEmpty($Canonical)) { $Canonical = (Join-Path $Dir 'home a/skills') }
    $env:AI_CONFIG_LOCAL_ENV     = Join-Path $Dir 'no-such-local.env'
    $env:SKILL_PARITY_CANONICAL  = $Canonical
    $env:SKILL_PARITY_MIRRORS    = $Mirrors
    $env:SKILL_PARITY_ALLOWLIST  = $Allow
    $env:SKILL_PARITY_CAPABILITY_MAP = $Map
    $env:SKILL_PARITY_VARIANTS   = $Variants
    try {
        $out = (& pwsh -NoProfile -File $OSP 2>&1 | Out-String)
        $script:OspRc = $LASTEXITCODE
    } finally {
        Remove-Item Env:AI_CONFIG_LOCAL_ENV    -ErrorAction SilentlyContinue
        Remove-Item Env:SKILL_PARITY_CANONICAL -ErrorAction SilentlyContinue
        Remove-Item Env:SKILL_PARITY_MIRRORS   -ErrorAction SilentlyContinue
        Remove-Item Env:SKILL_PARITY_ALLOWLIST -ErrorAction SilentlyContinue
        Remove-Item Env:SKILL_PARITY_CAPABILITY_MAP -ErrorAction SilentlyContinue
        Remove-Item Env:SKILL_PARITY_VARIANTS  -ErrorAction SilentlyContinue
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

# --- Hermes consumes the Capability Map, not the canonical full roster ------
$D8 = New-OspTmp; New-OspFixture $D8; New-OspMap $D8
New-Item -ItemType Directory -Path (Join-Path $D8 'hermes/skills/alpha') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $D8 'hermes/skills/alpha/SKILL.md'), "alpha body`n")
$hermesMirrors = "m1=$(Join-Path $D8 'm1/skills'),m2=$(Join-Path $D8 'm2/skills'),hermes=$(Join-Path $D8 'hermes/skills')"
$mapPath = Join-Path $D8 'Capability Map.md'
$o = Invoke-Osp -Dir $D8 -Mirrors $hermesMirrors -Map $mapPath
Assert-Eq 'operator-skill-parity: Hermes intentional absence exits 0' '0' "$script:OspRc"
Assert-Contains 'operator-skill-parity: Hermes subset reports its map source' $o "NOTE   Hermes expected subset: 2 skill(s) from $mapPath"
Assert-NotContains 'operator-skill-parity: map-omitted Hermes skill is not missing' $o 'MISSING hermes   beta'

Remove-Item -Recurse -Force (Join-Path $D8 'hermes/skills/alpha')
$o = Invoke-Osp -Dir $D8 -Mirrors $hermesMirrors -Map $mapPath
Assert-Eq 'operator-skill-parity: expected Hermes skill missing exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: expected Hermes skill is reported' $o 'MISSING hermes   alpha'
Remove-Item -Recurse -Force $D8

# The Hermes alpha variant must match its declared Codex source pair.
$D9 = New-OspTmp; New-OspFixture $D9; New-OspMap $D9
[IO.File]::WriteAllText((Join-Path $D9 'm1/skills/alpha/SKILL.md'), "codex variant`n")
New-Item -ItemType Directory -Path (Join-Path $D9 'hermes/skills/alpha') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $D9 'hermes/skills/alpha/SKILL.md'), "codex variant`n")
$variantMirrors = "codex=$(Join-Path $D9 'm1/skills'),hermes=$(Join-Path $D9 'hermes/skills')"
$o = Invoke-Osp -Dir $D9 -Allow 'codex/alpha' -Mirrors $variantMirrors -Map (Join-Path $D9 'Capability Map.md') -Variants 'hermes/alpha=codex/alpha'
Assert-Eq 'operator-skill-parity: declared Hermes variant exits 0' '0' "$script:OspRc"
Assert-Contains 'operator-skill-parity: declared Hermes variant names its source pair' $o 'VARIANT hermes   alpha (matched codex/alpha)'

# A declared pair is enforcement, not an allowlist: a mismatch stays red and
# names the source pair it was required to match.
[IO.File]::WriteAllText((Join-Path $D9 'hermes/skills/alpha/SKILL.md'), "wrong variant`n")
$o = Invoke-Osp -Dir $D9 -Allow 'codex/alpha' -Mirrors $variantMirrors -Map (Join-Path $D9 'Capability Map.md') -Variants 'hermes/alpha=codex/alpha'
Assert-Eq 'operator-skill-parity: declared Hermes variant mismatch exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: declared Hermes variant mismatch names expected source' $o 'DRIFT   hermes   alpha (expected codex/alpha)'
Remove-Item -Recurse -Force $D9

# A configured Hermes home cannot disappear while another mirror still passes.
$D10 = New-OspTmp; New-OspFixture $D10; New-OspMap $D10
$o = Invoke-Osp -Dir $D10 -Mirrors "m1=$(Join-Path $D10 'm1/skills'),hermes=$(Join-Path $D10 'absent-hermes/skills')" -Map (Join-Path $D10 'Capability Map.md')
Assert-Eq 'operator-skill-parity: absent Hermes home exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: absent Hermes home fails loudly' $o "FAIL Hermes skill root missing: $(Join-Path $D10 'absent-hermes/skills')"
Assert-NotContains 'operator-skill-parity: absent Hermes home cannot PASS' $o 'PASS operator-skill parity'
Remove-Item -Recurse -Force $D10

# Capability Map header and Where tokens are case-insensitive in both twins.
$D11 = New-OspTmp; New-OspFixture $D11; New-OspCaseMap $D11
foreach ($s in 'alpha', 'beta') {
    New-Item -ItemType Directory -Path (Join-Path $D11 "hermes/skills/$s") -Force | Out-Null
}
[IO.File]::WriteAllText((Join-Path $D11 'hermes/skills/alpha/SKILL.md'), "alpha body`n")
[IO.File]::WriteAllText((Join-Path $D11 'hermes/skills/beta/SKILL.md'), "beta body`n")
$o = Invoke-Osp -Dir $D11 -Mirrors "m1=$(Join-Path $D11 'm1/skills'),hermes=$(Join-Path $D11 'hermes/skills')" -Map (Join-Path $D11 'Capability Map.md')
Assert-Eq 'operator-skill-parity: mixed-case Hermes and All map tokens exit 0' '0' "$script:OspRc"
Assert-Contains 'operator-skill-parity: mixed-case map finds all expected skills' $o "NOTE   Hermes expected subset: 3 skill(s) from $(Join-Path $D11 'Capability Map.md')"
Remove-Item -Recurse -Force $D11

# The PowerShell twin also preserves the no-work result for an empty canonical root.
$D12 = New-OspTmp
New-Item -ItemType Directory -Path (Join-Path $D12 'canonical'), (Join-Path $D12 'm1/skills') -Force | Out-Null
$o = Invoke-Osp -Dir $D12 -Canonical (Join-Path $D12 'canonical') -Mirrors "m1=$(Join-Path $D12 'm1/skills')"
Assert-Eq 'operator-skill-parity: empty canonical root exits 0' '0' "$script:OspRc"
Assert-Contains 'operator-skill-parity: empty canonical root SKIPs cleanly' $o 'SKIP   no unmanaged skills to compare'
Remove-Item -Recurse -Force $D12

# Reject the same extra-slash pair shapes as the Bash twin.
$D13 = New-OspTmp; New-OspFixture $D13
$o = Invoke-Osp -Dir $D13 -Mirrors "m1=$(Join-Path $D13 'm1/skills')" -Variants 'm1/alpha/extra=canonical/alpha'
Assert-Eq 'operator-skill-parity: extra-slash variant target exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: extra-slash variant target is rejected' $o 'FAIL invalid variant target: m1/alpha/extra'
$o = Invoke-Osp -Dir $D13 -Mirrors "m1=$(Join-Path $D13 'm1/skills')" -Variants 'm1/alpha=canonical/alpha/extra'
Assert-Eq 'operator-skill-parity: extra-slash variant source exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: extra-slash variant source is rejected' $o 'FAIL invalid variant source: canonical/alpha/extra'
Remove-Item -Recurse -Force $D13

# A target can have exactly one case-sensitive mapping. Do not choose the first
# pair (Bash) or overwrite it with the last pair (PowerShell).
$D14 = New-OspTmp; New-OspFixture $D14
$o = Invoke-Osp -Dir $D14 -Mirrors "target=$(Join-Path $D14 'm1/skills'),good=$(Join-Path $D14 'm2/skills')" -Variants 'target/alpha=good/alpha,target/alpha=canonical/alpha'
Assert-Eq       'operator-skill-parity: duplicate variant target exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: duplicate variant target fails loudly' $o 'FAIL duplicate variant target: target/alpha'
Remove-Item -Recurse -Force $D14

# A literal self-pair would make the comparison vacuous before it reaches the
# filesystem. It must fail in both twins.
$D15 = New-OspTmp; New-OspFixture $D15
$o = Invoke-Osp -Dir $D15 -Mirrors "target=$(Join-Path $D15 'm1/skills')" -Variants 'target/alpha=target/alpha'
Assert-Eq       'operator-skill-parity: literal self-pair exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: literal self-pair fails loudly' $o 'FAIL variant source matches target: target/alpha'
Remove-Item -Recurse -Force $D15

# A different label may still lead to the same skill directory through a link.
# That comparison is equally vacuous and must not mask canonical drift.
$D16 = New-OspTmp; New-OspFixture $D16
[IO.File]::WriteAllText((Join-Path $D16 'm1/skills/alpha/SKILL.md'), "alias-only copy`n")
New-Item -ItemType Directory -Path (Join-Path $D16 'source/skills') -Force | Out-Null
New-Item -ItemType SymbolicLink -Path (Join-Path $D16 'source/skills/alpha') -Target (Join-Path $D16 'm1/skills/alpha') | Out-Null
$o = Invoke-Osp -Dir $D16 -Mirrors "target=$(Join-Path $D16 'm1/skills'),source=$(Join-Path $D16 'source/skills')" -Variants 'target/alpha=source/alpha'
Assert-Eq       'operator-skill-parity: physical self-alias exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: physical self-alias fails loudly' $o 'FAIL variant source aliases target: target/alpha = source/alpha'
Remove-Item -Recurse -Force $D16

# Separate labels can directly name the same directory without a symlink.
$D17 = New-OspTmp; New-OspFixture $D17
$o = Invoke-Osp -Dir $D17 -Mirrors "target=$(Join-Path $D17 'm1/skills'),source=$(Join-Path $D17 'm1/skills')" -Variants 'target/alpha=source/alpha'
Assert-Eq       'operator-skill-parity: direct physical self-alias exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: direct physical self-alias fails loudly' $o 'FAIL variant source aliases target: target/alpha = source/alpha'
Remove-Item -Recurse -Force $D17

# A symlinked mirror root has the same physical target as the direct root.
$D18 = New-OspTmp; New-OspFixture $D18
[IO.File]::WriteAllText((Join-Path $D18 'm1/skills/alpha/SKILL.md'), "alias-only copy`n")
New-Item -ItemType SymbolicLink -Path (Join-Path $D18 'source-skills') -Target (Join-Path $D18 'm1/skills') | Out-Null
$o = Invoke-Osp -Dir $D18 -Mirrors "target=$(Join-Path $D18 'm1/skills'),source=$(Join-Path $D18 'source-skills')" -Variants 'target/alpha=source/alpha'
Assert-Eq       'operator-skill-parity: symlink-root self-alias exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: symlink-root self-alias fails loudly' $o 'FAIL variant source aliases target: target/alpha = source/alpha'
Remove-Item -Recurse -Force $D18

# Pair keys are case-sensitive in both twins. These distinct labels must not be
# misread as a duplicate mapping during configuration parsing.
$D19 = New-OspTmp; New-OspFixture $D19
$o = Invoke-Osp -Dir $D19 -Mirrors "lower=$(Join-Path $D19 'm1/skills'),Lower=$(Join-Path $D19 'm2/skills')" -Variants 'lower/alpha=canonical/alpha,Lower/alpha=canonical/alpha'
Assert-Eq       'operator-skill-parity: case-distinct variant targets exit 0' '0' "$script:OspRc"
Assert-Contains 'operator-skill-parity: case-distinct variant targets PASS' $o 'PASS operator-skill parity'
Remove-Item -Recurse -Force $D19

# Mirror labels are case-sensitive. An uppercase Hermes label is ordinary and
# must compare the full canonical roster instead of taking the Hermes subset.
$D20 = New-OspTmp; New-OspFixture $D20
[IO.File]::WriteAllText((Join-Path $D20 'm2/skills/alpha/SKILL.md'), "uppercase label drift`n")
$o = Invoke-Osp -Dir $D20 -Mirrors "m1=$(Join-Path $D20 'm1/skills'),Hermes=$(Join-Path $D20 'm2/skills')"
Assert-Eq       'operator-skill-parity: uppercase Hermes label detects drift' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: uppercase Hermes label is ordinary mirror' $o 'DRIFT   Hermes   alpha'
Remove-Item -Recurse -Force $D20

# A missing Hermes root must stay failed when an empty canonical root leaves no
# comparisons. The no-work result cannot overwrite an accumulated failure.
$D21 = New-OspTmp; New-OspMap $D21
New-Item -ItemType Directory -Path (Join-Path $D21 'canonical'), (Join-Path $D21 'm1/skills') -Force | Out-Null
$o = Invoke-Osp -Dir $D21 -Canonical (Join-Path $D21 'canonical') -Mirrors "m1=$(Join-Path $D21 'm1/skills'),hermes=$(Join-Path $D21 'absent-hermes/skills')" -Map (Join-Path $D21 'Capability Map.md')
Assert-Eq       'operator-skill-parity: missing Hermes plus no-work exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: missing Hermes plus no-work FAILs' $o "FAIL Hermes skill root missing: $(Join-Path $D21 'absent-hermes/skills')"
Remove-Item -Recurse -Force $D21

# The Capability Map is required for the exact lowercase Hermes label. A
# missing map must fail, while a real map and in-sync subset pass.
$D22 = New-OspTmp; New-OspFixture $D22
New-Item -ItemType Directory -Path (Join-Path $D22 'hermes/skills/alpha') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $D22 'hermes/skills/alpha/SKILL.md'), "alpha body`n")
$o = Invoke-Osp -Dir $D22 -Mirrors "m1=$(Join-Path $D22 'm1/skills'),hermes=$(Join-Path $D22 'hermes/skills')" -Map (Join-Path $D22 'missing-map.md')
Assert-Eq       'operator-skill-parity: missing Hermes map exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: missing Hermes map fails loudly' $o 'FAIL Hermes Capability Map missing'
New-OspMap $D22
$o = Invoke-Osp -Dir $D22 -Mirrors "m1=$(Join-Path $D22 'm1/skills'),hermes=$(Join-Path $D22 'hermes/skills')" -Map (Join-Path $D22 'Capability Map.md')
Assert-Eq       'operator-skill-parity: present Hermes map positive control exits 0' '0' "$script:OspRc"
Assert-Contains 'operator-skill-parity: present Hermes map reports subset count' $o 'NOTE   Hermes expected subset: 2 skill(s)'
Remove-Item -Recurse -Force $D22

# A readable table with no Hermes/all skill rows is also a failure. A populated
# table is the paired control above, so this cannot pass by skipping the parser.
$D23 = New-OspTmp; New-OspFixture $D23
New-Item -ItemType Directory -Path (Join-Path $D23 'hermes/skills') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $D23 'Capability Map.md'), @'
| Skill | What | Where |
| --- | --- | --- |
| `beta` | other harnesses | codex |
'@)
$o = Invoke-Osp -Dir $D23 -Mirrors "m1=$(Join-Path $D23 'm1/skills'),hermes=$(Join-Path $D23 'hermes/skills')" -Map (Join-Path $D23 'Capability Map.md')
Assert-Eq       'operator-skill-parity: empty Hermes expected subset exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: empty Hermes expected subset fails loudly' $o 'FAIL Hermes Capability Map has no expected skills'
Remove-Item -Recurse -Force $D23

# Variant labels must resolve to canonical or an exact configured mirror label.
$D24 = New-OspTmp; New-OspFixture $D24
$o = Invoke-Osp -Dir $D24 -Mirrors "m1=$(Join-Path $D24 'm1/skills')" -Variants 'm1/alpha=unknown/alpha'
Assert-Eq       'operator-skill-parity: unknown variant source label exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: unknown variant source label fails loudly' $o 'FAIL variant source missing: unknown/alpha'
$o = Invoke-Osp -Dir $D24 -Mirrors "m1=$(Join-Path $D24 'm1/skills')" -Variants 'm1/alpha=canonical/alpha'
Assert-Eq       'operator-skill-parity: known variant source positive control exits 0' '0' "$script:OspRc"
Assert-Contains 'operator-skill-parity: known variant source is compared' $o 'VARIANT m1       alpha (matched canonical/alpha)'
Remove-Item -Recurse -Force $D24

# Every map skill must have a canonical source before Hermes can compare it.
$D25 = New-OspTmp; New-OspFixture $D25
New-Item -ItemType Directory -Path (Join-Path $D25 'hermes/skills/gamma') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $D25 'hermes/skills/gamma/SKILL.md'), "gamma body`n")
[IO.File]::WriteAllText((Join-Path $D25 'Capability Map.md'), @'
| Skill | What | Where |
| --- | --- | --- |
| `gamma` | missing canonical source | hermes |
'@)
$o = Invoke-Osp -Dir $D25 -Mirrors "m1=$(Join-Path $D25 'm1/skills'),hermes=$(Join-Path $D25 'hermes/skills')" -Map (Join-Path $D25 'Capability Map.md')
Assert-Eq       'operator-skill-parity: map skill absent from canonical exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: map skill absent from canonical is reported' $o 'MISSING canonical gamma'
foreach ($root in (Join-Path $D25 'home a/skills'), (Join-Path $D25 'm1/skills'), (Join-Path $D25 'm2/skills')) {
    New-Item -ItemType Directory -Path (Join-Path $root 'gamma') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'gamma/SKILL.md'), "gamma body`n")
}
$o = Invoke-Osp -Dir $D25 -Mirrors "m1=$(Join-Path $D25 'm1/skills'),m2=$(Join-Path $D25 'm2/skills'),hermes=$(Join-Path $D25 'hermes/skills')" -Map (Join-Path $D25 'Capability Map.md')
Assert-Eq       'operator-skill-parity: canonical map skill recovery exits 0' '0' "$script:OspRc"
Assert-Contains 'operator-skill-parity: canonical map skill recovery preserves count' $o '7 comparison(s) across 3 of 3 mirror root(s)'
Remove-Item -Recurse -Force $D25

# A two-column map with an omitted final pipe and aligned separator accepts the
# minimum schema in both twins. Literal mixed-case/punctuated names also work.
# The report count is contractual; diagnostic-line order is not.
$D26 = New-OspTmp; New-OspFixture $D26; New-OspTwoColumnMap $D26 $false
New-Item -ItemType Directory -Path (Join-Path $D26 'hermes/skills/alpha') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $D26 'hermes/skills/alpha/SKILL.md'), "alpha body`n")
foreach ($skill in 'Alpha-1', 'zeta_2') {
    foreach ($root in (Join-Path $D26 'home a/skills'), (Join-Path $D26 'm1/skills'), (Join-Path $D26 'm2/skills')) {
        New-Item -ItemType Directory -Path (Join-Path $root $skill) -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root "$skill/SKILL.md"), "$skill body`n")
    }
}
$d26Mirrors = "m1=$(Join-Path $D26 'm1/skills'),m2=$(Join-Path $D26 'm2/skills'),hermes=$(Join-Path $D26 'hermes/skills')"
$o = Invoke-Osp -Dir $D26 -Mirrors $d26Mirrors -Map (Join-Path $D26 'Capability Map.md')
Assert-Eq       'operator-skill-parity: mixed-case punctuated skills exit 0' '0' "$script:OspRc"
Assert-Contains 'operator-skill-parity: two-column omitted final pipe loads Hermes subset' $o 'NOTE   Hermes expected subset: 2 skill(s)'
Assert-Contains 'operator-skill-parity: mixed-case punctuated skills preserve count' $o '9 comparison(s) across 3 of 3 mirror root(s)'
New-OspTwoColumnMap $D26 $true
$o = Invoke-Osp -Dir $D26 -Mirrors $d26Mirrors -Map (Join-Path $D26 'Capability Map.md')
Assert-Eq       'operator-skill-parity: two-column final pipe exits 0' '0' "$script:OspRc"
Assert-Contains 'operator-skill-parity: two-column final pipe preserves count' $o '9 comparison(s) across 3 of 3 mirror root(s)'
[IO.File]::WriteAllText((Join-Path $D26 'm2/skills/Alpha-1/SKILL.md'), "Alpha-1 changed`n")
$o = Invoke-Osp -Dir $D26 -Mirrors $d26Mirrors -Map (Join-Path $D26 'Capability Map.md')
Assert-Eq       'operator-skill-parity: mixed-case punctuated drift exits 1' '1' "$script:OspRc"
Assert-Contains 'operator-skill-parity: mixed-case punctuated drift names literal skill' $o 'DRIFT   m2       Alpha-1'
Remove-Item -Recurse -Force $D26
