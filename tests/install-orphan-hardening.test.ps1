#Requires -Version 7
# tests/install-orphan-hardening.test.ps1 — Windows-native twin of
# tests/install-orphan-hardening.test.sh.
#
# install.ps1's orphan-subdir deletion hardening (path-traversal / control-chars
# / positive hash evidence / symlink rejection / corrupt-manifest skip). These
# assertions were SKIP stubs while install.ps1 used a wholesale-dir swap with no
# orphan routine. <TEAM>-294 F7 landed the per-subdir orphan hash-gate
# (Remove-StaleOrphanSubdirs, formerly the skills/-only Remove-StaleOrphanSkills)
# with the full defense set — control/whitespace, path-traversal, path-separator,
# .install-bak. prefix, NTFS ADS colon, trailing-dot, GetFullPath child-
# containment, symlink/reparse-point, nested-reparse, positive hash evidence — so
# the stubs now LIFT to live assertions against a real claude build.
#
# Per [[feedback_port_parity_vs_regression_split]] — the AC labels mirror the
# bash twin so the parity contract (same AC count, same PASS/FAIL on identical
# fixtures) holds; labels that name the script-under-test say install.ps1.
#
# Fixture discipline (mirrors the bash twin): sentinels live under temp dirs
# from [IO.Path]::GetTempPath() + a GUID (no real $TARGET contamination); the
# OLD manifest is hand-edited with the attack key AFTER a clean baseline install
# (never a tracked poisoned fixture); attack tokens (`..`/`.`/TAB/LF) are
# assembled at runtime so the source carries no literal `skills/../`-shaped
# segment that a future scanner might trip on. Each block ends by removing its
# temp dir; _Fail does NOT throw, so cleanup runs even when an assertion fails.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$INSTALL_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$utf8NoBom   = [System.Text.UTF8Encoding]::new($false)

# jq gates both the fixture manifest edits AND install.ps1's own orphan routine.
# Mirror the bash twin's single jq-absence skip + early return (preserves count).
if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    _Skip 'install-orphan-hardening.test: orphan-skill hardening (jq required)' 'jq not installed'
    return
}

# Helper: run install.ps1 --harness claude against a fixture local.env, suppress
# all output, return the exit code. For clean baseline installs + the cases that
# assert only filesystem state + exit code.
function Invoke-InstallClaude {
    param([Parameter(Mandatory)][string]$EnvFile)
    $env:AI_CONFIG_LOCAL_ENV = $EnvFile
    try {
        & pwsh -NoProfile -File $INSTALL_PS1 --harness claude *>$null
        return $LASTEXITCODE
    } finally {
        Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
    }
}

# Helper: run install.ps1 --harness claude capturing merged stdout+stderr AND the
# exit code. install.ps1's orphan-rejection warnings go to [Console]::Error; a
# child `pwsh ... 2>&1` capture includes them (the same pattern the N1 collision-
# warn case in install-shape-c.test.ps1 uses to read Warn's stderr output).
function Invoke-InstallClaudeCapture {
    param([Parameter(Mandatory)][string]$EnvFile)
    $env:AI_CONFIG_LOCAL_ENV = $EnvFile
    try {
        $out  = (& pwsh -NoProfile -File $INSTALL_PS1 --harness claude 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ Out = $out; Code = $code }
}

# Helper: inject a {<key> -> <hash>} entry into a build manifest's .generated map.
# Mirrors the bash twin's `jq --arg k <key> --arg h <hash> '.generated[$k]=$h'`
# hand-edit-the-OLD-manifest step. --arg keeps the key a literal string so
# embedded `..`/TAB/LF tokens never reach jq as program text.
function Add-ManifestSkillEntry {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Hash
    )
    $jq = (Get-Command jq -ErrorAction Stop).Source
    $out = Get-Content -Raw -LiteralPath $ManifestPath |
        & $jq --arg k $Key --arg h $Hash '.generated[$k] = $h'
    if ($out -is [array]) { $out = $out -join "`n" }
    [System.IO.File]::WriteAllText($ManifestPath, $out, $utf8NoBom)
}

# Helper: a fresh temp working dir (mirrors bash `mktemp -d`); returns its path.
function New-OrphanTmpDir {
    param([Parameter(Mandatory)][string]$Tag)
    $d = Join-Path ([IO.Path]::GetTempPath()) ("orphan-$Tag-" + [Guid]::NewGuid().Guid.Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

# Helper: set up <tmp>/tgt + a fixture local.env pointing CLAUDE_CONFIG_DIR there.
# Returns @{ Dir; Tgt; Env }. Mirrors the bash twin's per-block T*_DIR/T*_TGT/T*_ENV
# + make_local_env preamble.
function New-OrphanFixture {
    param([Parameter(Mandatory)][string]$Tag)
    $dir = New-OrphanTmpDir $Tag
    $tgt = Join-Path $dir 'tgt'
    New-Item -ItemType Directory -Path $tgt -Force | Out-Null
    $envFile = Join-Path $dir 'local.env'
    Write-LocalEnvFixture -EnvFile $envFile -ConfigDir $tgt -VaultDir (Join-Path $dir 'vault')
    return [pscustomobject]@{ Dir = $dir; Tgt = $tgt; Env = $envFile }
}

# Helper: write a minimal SKILL.md under <tgt>/skills/<base>/ (no-BOM, LF).
function New-OrphanSkill {
    param(
        [Parameter(Mandatory)][string]$Tgt,
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Body
    )
    $dir = Join-Path (Join-Path $Tgt 'skills') $Base
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir 'SKILL.md'), $Body, $script:utf8NoBom)
    return $dir
}

# ===========================================================================
# T1 — positive control: a well-formed orphan with a hash-match is deleted.
# Pins that orphan cleanup still works on clean inputs (the hardening must not
# break the happy path).
# ===========================================================================
$T1 = New-OrphanFixture 't1'
Invoke-InstallClaude -EnvFile $T1.Env | Out-Null

# Simulate a prior framework version that compiled an extra "que107-stale" skill:
# render its subdir, then record its ACTUAL on-disk hash in the OLD manifest.
$t1Orphan = New-OrphanSkill -Tgt $T1.Tgt -Base 'que107-stale' `
    -Body "---`nname: que107-stale`ndescription: stale framework skill`n---`nstale body`n"
$t1Hash = (Get-FileHash -LiteralPath (Join-Path $t1Orphan 'SKILL.md') -Algorithm SHA256).Hash.ToLower()
Add-ManifestSkillEntry -ManifestPath (Join-Path $T1.Tgt '.build-manifest.json') `
    -Key 'skills/que107-stale/SKILL.md' -Hash $t1Hash

# Re-install — untouched-stale orphan (hash matches the OLD manifest) is removed.
Invoke-InstallClaude -EnvFile $T1.Env | Out-Null
if (Test-Path -LiteralPath $t1Orphan -PathType Container) {
    _Fail 'install-orphan-hardening.test: T1: well-formed orphan with hash-match deleted' 'skills/que107-stale still present'
} else {
    _Pass 'install-orphan-hardening.test: T1: well-formed orphan with hash-match deleted'
}
Remove-Item -LiteralPath $T1.Dir -Recurse -Force -ErrorAction SilentlyContinue

# ===========================================================================
# T2 — path traversal `..` rejected with WARNING; $TARGET NOT wiped.
# A hand-edited OLD manifest key "skills/../x" makes split("/")[1] yield `..`;
# the routine must reject it before any filesystem touch (path-traversal guard).
# ===========================================================================
$T2 = New-OrphanFixture 't2'
Invoke-InstallClaude -EnvFile $T2.Env | Out-Null

# Sentinel directly under $TARGET (sibling of skills/) — its survival proves
# $TARGET was not wiped by a traversal-driven recursive delete.
[System.IO.File]::WriteAllText((Join-Path $T2.Tgt 'que107-sentinel.txt'), "sentinel content`n", $utf8NoBom)

# Build the `..` token at runtime so the source carries no literal `skills/../`.
$t2Traversal = ('.' + '.')
Add-ManifestSkillEntry -ManifestPath (Join-Path $T2.Tgt '.build-manifest.json') `
    -Key "skills/$t2Traversal/x" -Hash 'deadbeef'

$cap2 = Invoke-InstallClaudeCapture -EnvFile $T2.Env
Assert-File 'install-orphan-hardening.test: T2: $TARGET sentinel preserved against `..` orphan attack' `
    (Join-Path $T2.Tgt 'que107-sentinel.txt')
Assert-Contains 'install-orphan-hardening.test: T2: install.ps1 emits warning on `..` orphan rejection' `
    $cap2.Out 'unsafe orphan'
Assert-Eq 'install-orphan-hardening.test: T2: install.ps1 exit code on `..` orphan rejection is 0' '0' "$($cap2.Code)"
Remove-Item -LiteralPath $T2.Dir -Recurse -Force -ErrorAction SilentlyContinue

# ===========================================================================
# T3 — current-dir `.` rejected with WARNING; skills/ NOT wiped. Same attack
# class as T2 with the single-dot token. A Shape C survivor proves skills/ was
# not swept.
# ===========================================================================
$T3 = New-OrphanFixture 't3'
Invoke-InstallClaude -EnvFile $T3.Env | Out-Null

$t3Survivor = New-OrphanSkill -Tgt $T3.Tgt -Base 'que107-shape-c-survivor' `
    -Body "---`nname: que107-shape-c-survivor`n---`nshape c body`n"

# Single-dot token assembled at runtime (no literal `skills/./` in source).
$t3Current = '.'
Add-ManifestSkillEntry -ManifestPath (Join-Path $T3.Tgt '.build-manifest.json') `
    -Key "skills/$t3Current/y" -Hash 'cafebabe'

$cap3 = Invoke-InstallClaudeCapture -EnvFile $T3.Env
Assert-File 'install-orphan-hardening.test: T3: Shape C survivor preserved against `.` orphan attack' `
    (Join-Path $t3Survivor 'SKILL.md')
Assert-Contains 'install-orphan-hardening.test: T3: install.ps1 emits warning on `.` orphan rejection' `
    $cap3.Out 'unsafe orphan'
Assert-Eq 'install-orphan-hardening.test: T3: install.ps1 exit code on `.` orphan rejection is 0' '0' "$($cap3.Code)"
Remove-Item -LiteralPath $T3.Dir -Recurse -Force -ErrorAction SilentlyContinue

# ===========================================================================
# T4 — control character (TAB) in the orphan name rejected with WARNING. jq -r
# preserves an embedded TAB in-line (unlike LF, which splits — see T6), so this
# is the canonical control-char rejection case.
# ===========================================================================
$T4 = New-OrphanFixture 't4'
Invoke-InstallClaude -EnvFile $T4.Env | Out-Null

$t4Survivor = New-OrphanSkill -Tgt $T4.Tgt -Base 'que107-t4-survivor' `
    -Body "---`nname: que107-t4-survivor`n---`nbody`n"

# TAB-embedded subdir name (`t = TAB inside a double-quoted PS string).
$t4TabName = "attacker`tname"
Add-ManifestSkillEntry -ManifestPath (Join-Path $T4.Tgt '.build-manifest.json') `
    -Key "skills/$t4TabName/z" -Hash 'feedface'

$cap4 = Invoke-InstallClaudeCapture -EnvFile $T4.Env
Assert-File 'install-orphan-hardening.test: T4: survivor preserved against control-char orphan attack' `
    (Join-Path $t4Survivor 'SKILL.md')
Assert-Contains 'install-orphan-hardening.test: T4: install.ps1 emits warning on control-char orphan rejection' `
    $cap4.Out 'unsafe orphan'
Assert-Eq 'install-orphan-hardening.test: T4: install.ps1 exit code on control-char rejection is 0' '0' "$($cap4.Code)"
Remove-Item -LiteralPath $T4.Dir -Recurse -Force -ErrorAction SilentlyContinue

# ===========================================================================
# T5 — orphan dir with ZERO manifest path-matches is preserved (positive-
# evidence requirement). Manifest key shape "skills/<orphan>" (no trailing
# segment) qualifies <orphan> for the orphans list, but the inner hash-gate
# prefix "skills/<orphan>/" never matches → found_match stays false → no delete.
# ===========================================================================
$T5 = New-OrphanFixture 't5'
Invoke-InstallClaude -EnvFile $T5.Env | Out-Null

$t5Dir = Join-Path (Join-Path $T5.Tgt 'skills') 'que107-no-evidence'
New-Item -ItemType Directory -Path $t5Dir -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $t5Dir 'operator-file.md'), "operator content`n", $utf8NoBom)

# No trailing path segment, so split("/")[1] yields the base but the inner
# case-match "skills/que107-no-evidence/*" finds nothing.
Add-ManifestSkillEntry -ManifestPath (Join-Path $T5.Tgt '.build-manifest.json') `
    -Key 'skills/que107-no-evidence' -Hash '0000abcd'

$t5Code = Invoke-InstallClaude -EnvFile $T5.Env
Assert-File 'install-orphan-hardening.test: T5: orphan dir without hash evidence is preserved' `
    (Join-Path $t5Dir 'operator-file.md')
Assert-Eq 'install-orphan-hardening.test: T5: install.ps1 exit code on no-hash-evidence preservation is 0' '0' "$t5Code"
Remove-Item -LiteralPath $T5.Dir -Recurse -Force -ErrorAction SilentlyContinue

# ===========================================================================
# T6 — LF in a manifest key yields TWO orphan candidates, both preserved. jq -r
# emits an embedded LF as a line break, so a key "skills/<half-a>${LF}<half-b>/z"
# surfaces "<half-a>" and "<half-b>" as separate orphans. Neither matches the
# control-char guard (benign by then); both are saved by the empty-evidence guard
# (no manifest entry matches "skills/<half-a>/*" or "skills/<half-b>/*").
# ===========================================================================
$T6 = New-OrphanFixture 't6'
Invoke-InstallClaude -EnvFile $T6.Env | Out-Null

$t6A = New-OrphanSkill -Tgt $T6.Tgt -Base 'que107-lf-half-a' -Body "half-a`n"
$t6B = New-OrphanSkill -Tgt $T6.Tgt -Base 'que107-lf-half-b' -Body "half-b`n"

# LF-bearing subdir name (`n = LF inside a double-quoted PS string).
$t6LfName = "que107-lf-half-a`nque107-lf-half-b"
Add-ManifestSkillEntry -ManifestPath (Join-Path $T6.Tgt '.build-manifest.json') `
    -Key "skills/$t6LfName/z" -Hash 'deadbeef'

$t6Code = Invoke-InstallClaude -EnvFile $T6.Env
Assert-File 'install-orphan-hardening.test: T6: LF-driven false-positive orphan half-a preserved' `
    (Join-Path $t6A 'SKILL.md')
Assert-File 'install-orphan-hardening.test: T6: LF-driven false-positive orphan half-b preserved' `
    (Join-Path $t6B 'SKILL.md')
Assert-Eq 'install-orphan-hardening.test: T6: install.ps1 exit code on LF-driven preservation is 0' '0' "$t6Code"
Remove-Item -LiteralPath $T6.Dir -Recurse -Force -ErrorAction SilentlyContinue

# ===========================================================================
# T7 — symlink orphan rejected with WARNING; the link + its external target both
# survive. A symlinked orphan dir would have a recursive delete remove only the
# link while the hash validation reads through it — the routine rejects the
# reparse point before any read. Skips gracefully where the platform forbids
# symlink creation (preserves the AC count).
# ===========================================================================
$T7 = New-OrphanFixture 't7'
Invoke-InstallClaude -EnvFile $T7.Env | Out-Null

# Out-of-tree directory + a symlink into $TARGET/skills/que107-symlink.
$t7Ext = Join-Path (Join-Path $T7.Dir 'external') 'que107-symlink-source'
New-Item -ItemType Directory -Path $t7Ext -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $t7Ext 'SKILL.md'), "external content`n", $utf8NoBom)
$t7Link = Join-Path (Join-Path $T7.Tgt 'skills') 'que107-symlink'

$t7SymlinkOk = $true
try {
    New-Item -ItemType SymbolicLink -Path $t7Link -Target $t7Ext -ErrorAction Stop | Out-Null
} catch {
    $t7SymlinkOk = $false
}

if ($t7SymlinkOk) {
    # Manifest key under skills/que107-symlink/ — validation would read the
    # symlinked file, but the reparse-point rejection must fire first.
    $t7Hash = (Get-FileHash -LiteralPath (Join-Path $t7Link 'SKILL.md') -Algorithm SHA256).Hash.ToLower()
    Add-ManifestSkillEntry -ManifestPath (Join-Path $T7.Tgt '.build-manifest.json') `
        -Key 'skills/que107-symlink/SKILL.md' -Hash $t7Hash

    $cap7 = Invoke-InstallClaudeCapture -EnvFile $T7.Env

    # The symlink itself must survive (active rejection before any delete). Mirror
    # the bash twin's `[ -L ]`: present AND still a reparse point.
    $t7Item = Get-Item -LiteralPath $t7Link -Force -ErrorAction SilentlyContinue
    if ($null -ne $t7Item -and ($t7Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        _Pass 'install-orphan-hardening.test: T7: symlink orphan preserved against deletion attempt'
    } else {
        _Fail 'install-orphan-hardening.test: T7: symlink orphan preserved against deletion attempt' `
            "symlink at skills/que107-symlink removed or no longer a reparse point (exit=$($cap7.Code))"
    }
    Assert-File 'install-orphan-hardening.test: T7: external symlink target preserved' `
        (Join-Path $t7Ext 'SKILL.md')
    Assert-Contains 'install-orphan-hardening.test: T7: install.ps1 emits warning on symlink orphan rejection' `
        $cap7.Out 'symlink'
    Assert-Eq 'install-orphan-hardening.test: T7: install.ps1 exit code on symlink orphan rejection is 0' '0' "$($cap7.Code)"

    # Drop the link explicitly before the recursive cleanup so Remove-Item never
    # follows the reparse point into the external target.
    Remove-Item -LiteralPath $t7Link -Force -ErrorAction SilentlyContinue
} else {
    $skipReason = 'symlink creation not permitted on this platform'
    _Skip 'install-orphan-hardening.test: T7: symlink orphan preserved against deletion attempt' $skipReason
    _Skip 'install-orphan-hardening.test: T7: external symlink target preserved' $skipReason
    _Skip 'install-orphan-hardening.test: T7: install.ps1 emits warning on symlink orphan rejection' $skipReason
    _Skip 'install-orphan-hardening.test: T7: install.ps1 exit code on symlink orphan rejection is 0' $skipReason
}
Remove-Item -LiteralPath $T7.Dir -Recurse -Force -ErrorAction SilentlyContinue

# ===========================================================================
# T8 — corrupt OLD manifest → orphan cleanup skipped with WARNING, candidate
# preserved. Any non-zero jq exit on the OLD manifest aborts orphan cleanup
# entirely (rather LEAVE stale skills than risk a partial validation deleting
# operator content). <TEAM>-294 F7 parity fix: install.ps1 now emits the same
# "manifest enumeration failed" warning bash install.sh prints, where the lazy
# orphan computation previously skipped silently.
#
# T8-strength (Codex 2026-06-17 cross-model review of this PS-twin port): the
# prior fixture planted a Shape C file that was NEVER manifest-authored. A
# Shape C subdir is not a hash-gated orphan candidate, so it survives whether
# or not cleanup correctly skipped — the preservation assertion proved nothing
# about the destructive path. We now plant a subdir constructed EXACTLY like
# the T1 deletion target (a genuine stale orphan) and assert IT survives, so
# the assertion rides on a REAL deletion candidate (T1 proves it is deletable
# on a valid manifest) instead of a file that survives unconditionally.
#
# Subtlety: corrupting the OLD manifest destroys its `.generated` entry, so the
# "would-be-deleted" property is NOT re-derivable inside this test — no valid
# manifest is left to enumerate against. It is established by CONSTRUCTION-
# PARALLEL to T1 (identical render + on-disk hash + manifest authorship), which
# T1 independently proves leads to deletion on a valid manifest.
#
# Scope of proof (Codex cross-model review, conf-75): this asserts the safe
# OUTCOME — a real, T1-deletable candidate is NOT removed on corrupt input — it
# does NOT isolate the explicit `manifest enumeration failed` abort. Corrupt
# input fails safe at TWO independent points: orphan ENUMERATION reads the same
# OLD manifest (its jq yields an empty managed set, so the delete loop has
# nothing to iterate) AND the abort returns before that loop. A fixture cannot
# single out the abort, since deletion needs the (corrupt) manifest for both
# enumeration and the hash gate; isolating it alone would require harness
# instrumentation of the loop, deliberately out of scope.
# ===========================================================================
$T8 = New-OrphanFixture 't8'
Invoke-InstallClaude -EnvFile $T8.Env | Out-Null

# Plant a GENUINE stale-orphan candidate, constructed EXACTLY like T1's deletion
# target: render skills/que107-t8-orphan/SKILL.md and record its on-disk hash in
# the OLD manifest. On a VALID manifest this is the confirmed-stale shape T1
# proves WOULD be deleted. (Authored for construction fidelity even though the
# corruption below destroys the entry — see the block-header subtlety.)
$t8Orphan = New-OrphanSkill -Tgt $T8.Tgt -Base 'que107-t8-orphan' `
    -Body "---`nname: que107-t8-orphan`ndescription: stale framework skill`n---`nstale body`n"
$t8Hash = (Get-FileHash -LiteralPath (Join-Path $t8Orphan 'SKILL.md') -Algorithm SHA256).Hash.ToLower()
Add-ManifestSkillEntry -ManifestPath (Join-Path $T8.Tgt '.build-manifest.json') `
    -Key 'skills/que107-t8-orphan/SKILL.md' -Hash $t8Hash

# Corrupt the OLD manifest with un-parseable text. This DESTROYS the
# que107-t8-orphan entry just authored — the point: the candidate's would-be-
# deleted property is carried by the T1-identical construction above, NOT by
# anything readable now. The NEW manifest at $BUILD is fresh + well-formed;
# only the OLD-manifest enumeration fails.
[System.IO.File]::WriteAllText((Join-Path $T8.Tgt '.build-manifest.json'), "not valid json {{{`n", $utf8NoBom)

$cap8 = Invoke-InstallClaudeCapture -EnvFile $T8.Env
Assert-File 'install-orphan-hardening.test: T8: stale-orphan candidate preserved on corrupt-manifest path' `
    (Join-Path $t8Orphan 'SKILL.md')
Assert-Contains 'install-orphan-hardening.test: T8: install.ps1 emits warning on corrupt-manifest enumeration' `
    $cap8.Out 'manifest enumeration failed'
Assert-Eq 'install-orphan-hardening.test: T8: install.ps1 exit code on corrupt-manifest skip is 0' '0' "$($cap8.Code)"
Remove-Item -LiteralPath $T8.Dir -Recurse -Force -ErrorAction SilentlyContinue
