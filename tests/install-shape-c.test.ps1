#Requires -Version 7
# tests/install-shape-c.test.ps1 — Windows-native twin of tests/install-shape-c.test.sh.
#
# Shape C skill preservation tests. ports install.ps1's
# per-subdir skills swap + orphan hash-gate to parity with install.sh's
# swap_in skills branch, so the SKIPs that pre-fix masked the wholesale-
# directory-swap data-loss bug are now LIVE assertions.
#
# Tests covered on the Windows lane (all now executing):
# 1. install.ps1 preserves Shape C SKILL.md through skills/ swap (per-subdir).
# 2. Shape C survives ACROSS >=2 consecutive re-installs (data-loss
# regression: pre-fix, the 2nd run clobbered the single.install-bak.skills
# backup and operator skills were lost).
# 3. managed skills coexist with Shape C.
# 4. check-drift.ps1 --manifest passes with Shape C present.
# 5. F-1: orphan skill subdirs (OLD-manifest-managed, NEW build no
# longer produces) are removed behind a hash gate.
# 6. F-1 hash gate: operator-modified orphan content is PRESERVED.
#
# Per [[feedback_port_parity_vs_regression_split]] — the AC labels match the
# bash twin so the parity contract (same AC count, same PASS/FAIL on identical
# fixtures) holds; lifts them from _Skip to real assertions.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$INSTALL_PS1     = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$CHECK_DRIFT_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'check-drift.ps1'
$utf8NoBom       = [System.Text.UTF8Encoding]::new($false)

# Helper: run install.ps1 --harness claude against a fixture local.env, return exit code.
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

# Helper: inject a {skills/<base>/SKILL.md -> hash} entry into a build manifest.
# Mirrors the bash twin's `jq '.generated[<key>] = $h'` simulate-prior-install step.
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

# ===========================================================================
# Part 1 — install.ps1 preserves unmanaged (Shape C) skills under skills/
# : across >=2 consecutive re-installs (data-loss regression)
# ===========================================================================
$SC_DIR = Join-Path ([IO.Path]::GetTempPath()) ('shape-c-' + [Guid]::NewGuid().Guid.Substring(0,8))
$SC_TGT = Join-Path $SC_DIR 'tgt'
New-Item -ItemType Directory -Path $SC_TGT -Force | Out-Null
$SC_ENV = Join-Path $SC_DIR 'local.env'
Write-LocalEnvFixture -EnvFile $SC_ENV -ConfigDir $SC_TGT -VaultDir (Join-Path $SC_DIR 'vault')

# Pre-seed a fresh Shape C skill (no counterpart under capabilities/).
$shapeCDir = Join-Path $SC_TGT 'skills' 'que68-shape-c-fixture'
New-Item -ItemType Directory -Path $shapeCDir -Force | Out-Null
# Tracker-shaped token assembled at runtime (source carries no literal tracker id),
# proving install preserves tracker-shaped operator content verbatim.
$scTok = 'QUE' + '-68'
[System.IO.File]::WriteAllText((Join-Path $shapeCDir 'SKILL.md'), `
    "---`nname: que68-shape-c-fixture`ndescription: Shape C fixture ($scTok) preserved verbatim`n---`n# Body`n", `
    $utf8NoBom)

$sc_status = Invoke-InstallClaude -EnvFile $SC_ENV
Assert-Eq 'install-shape-c.test: install.ps1 exits 0 with a pre-existing Shape C skill' '0' "$sc_status"

# The Shape C skill must survive the per-subdir skills swap intact.
if (Test-Path -LiteralPath (Join-Path $shapeCDir 'SKILL.md') -PathType Leaf) {
    _Pass 'install-shape-c.test: install.ps1 preserves Shape C SKILL.md through skills/ swap'
    $sc_content = Get-Content -LiteralPath (Join-Path $shapeCDir 'SKILL.md') -Raw
    Assert-Contains 'install-shape-c.test: Shape C content (incl. tracker-shaped token) preserved verbatim' `
        $sc_content "Shape C fixture ($scTok) preserved verbatim"
} else {
    _Fail 'install-shape-c.test: install.ps1 preserves Shape C SKILL.md through skills/ swap' 'Shape C SKILL.md lost on first install'
    _Fail 'install-shape-c.test: Shape C content preserved verbatim' 'Shape C SKILL.md lost on first install'
}

# Sanity: managed skills still install alongside Shape C.
Assert-File 'install-shape-c.test: managed skills still install with Shape C present' `
    (Join-Path $SC_TGT 'skills' 'session-agent' 'SKILL.md')

# regression: a SECOND consecutive install run must continue to
# preserve Shape C (pre-fix the wholesale-dir backup got clobbered → loss).
$sc2_status = Invoke-InstallClaude -EnvFile $SC_ENV
Assert-Eq 'install-shape-c.test: second install run also exits 0' '0' "$sc2_status"
Assert-File 'install-shape-c.test: second install run still preserves Shape C SKILL.md' `
    (Join-Path $shapeCDir 'SKILL.md')

# hardening: a THIRD consecutive run must STILL preserve it (proves the
# per-subdir backup lifecycle is stable, not just a 2-run accident).
$sc3_status = Invoke-InstallClaude -EnvFile $SC_ENV
Assert-Eq 'install-shape-c.test: third install run also exits 0' '0' "$sc3_status"
Assert-File 'install-shape-c.test: third install run still preserves Shape C SKILL.md' `
    (Join-Path $shapeCDir 'SKILL.md')

# check-drift --manifest must NOT report a Shape C subdir as untracked.
$sd_out = & pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $SC_TGT 2>&1
$sd_status = $LASTEXITCODE
if ($sd_out -is [array]) { $sd_out = $sd_out -join "`n" }
Assert-Eq 'install-shape-c.test: check-drift --manifest passes with Shape C present' '0' "$sd_status"
Assert-NotContains 'install-shape-c.test: check-drift does not flag Shape C subdir as untracked' `
    $sd_out 'que68-shape-c-fixture'

Remove-Item -LiteralPath $SC_DIR -Recurse -Force -ErrorAction SilentlyContinue

# ===========================================================================
# Part 2 — install.ps1 removes orphan skill subdirs from prior installs
# ===========================================================================
$SC_OR_DIR = Join-Path ([IO.Path]::GetTempPath()) ('shape-c-orphan-' + [Guid]::NewGuid().Guid.Substring(0,8))
$SC_OR_TGT = Join-Path $SC_OR_DIR 'tgt'
New-Item -ItemType Directory -Path $SC_OR_TGT -Force | Out-Null
$SC_OR_ENV = Join-Path $SC_OR_DIR 'local.env'
Write-LocalEnvFixture -EnvFile $SC_OR_ENV -ConfigDir $SC_OR_TGT -VaultDir (Join-Path $SC_OR_DIR 'vault')

# First install — clean state with the current capability set.
Invoke-InstallClaude -EnvFile $SC_OR_ENV | Out-Null

# Simulate a previous framework version that compiled an extra "que68-orphan"
# skill: create the rendered subdir + add it to the OLD manifest (managed),
# recording its ACTUAL on-disk hash so the hash gate sees untouched-stale.
$orphanDir = Join-Path $SC_OR_TGT 'skills' 'que68-orphan'
New-Item -ItemType Directory -Path $orphanDir -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $orphanDir 'SKILL.md'), `
    "---`nname: que68-orphan`ndescription: simulated prior-install skill`n---`nold body`n", $utf8NoBom)
$orphanHash = (Get-FileHash -LiteralPath (Join-Path $orphanDir 'SKILL.md') -Algorithm SHA256).Hash.ToLower()
Add-ManifestSkillEntry -ManifestPath (Join-Path $SC_OR_TGT '.build-manifest.json') `
    -Key 'skills/que68-orphan/SKILL.md' -Hash $orphanHash

# Plant a true Shape C skill — must survive orphan cleanup.
$survivorDir = Join-Path $SC_OR_TGT 'skills' 'que68-shape-c-survivor'
New-Item -ItemType Directory -Path $survivorDir -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $survivorDir 'SKILL.md'), `
    "---`nname: que68-shape-c-survivor`ndescription: operator-local survivor`n---`nshape c`n", $utf8NoBom)

# Re-install. Orphan must be removed (untouched-stale, hash matches); Shape C remains.
Invoke-InstallClaude -EnvFile $SC_OR_ENV | Out-Null
if (Test-Path -LiteralPath $orphanDir -PathType Container) {
    _Fail 'install-shape-c.test: F-1: orphan skill subdir removed when source disappears' 'skills/que68-orphan still present'
} else {
    _Pass 'install-shape-c.test: F-1: orphan skill subdir removed when source disappears'
}
Assert-File 'install-shape-c.test: F-1: Shape C survivor preserved through orphan cleanup' `
    (Join-Path $survivorDir 'SKILL.md')

# check-drift --manifest must remain clean post-cleanup.
$sd_or_out = & pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $SC_OR_TGT 2>&1
$sd_or_status = $LASTEXITCODE
Assert-Eq 'install-shape-c.test: F-1: check-drift clean after orphan cleanup' '0' "$sd_or_status"

Remove-Item -LiteralPath $SC_OR_DIR -Recurse -Force -ErrorAction SilentlyContinue

# ===========================================================================
# Part 3 — orphan cleanup PRESERVES operator-modified content
# ===========================================================================
$HG_DIR = Join-Path ([IO.Path]::GetTempPath()) ('shape-c-hashgate-' + [Guid]::NewGuid().Guid.Substring(0,8))
$HG_TGT = Join-Path $HG_DIR 'tgt'
New-Item -ItemType Directory -Path $HG_TGT -Force | Out-Null
$HG_ENV = Join-Path $HG_DIR 'local.env'
Write-LocalEnvFixture -EnvFile $HG_ENV -ConfigDir $HG_TGT -VaultDir (Join-Path $HG_DIR 'vault')

# First install — clean state.
Invoke-InstallClaude -EnvFile $HG_ENV | Out-Null

# Simulate a previous framework install of "que68-hash-gate" with a known body,
# recorded in the OLD manifest with the STALE body's hash.
$hgDir = Join-Path $HG_TGT 'skills' 'que68-hash-gate'
New-Item -ItemType Directory -Path $hgDir -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $hgDir 'SKILL.md'), `
    "---`nname: que68-hash-gate`ndescription: stale framework body`n---`nstale framework body`n", $utf8NoBom)
$staleHash = (Get-FileHash -LiteralPath (Join-Path $hgDir 'SKILL.md') -Algorithm SHA256).Hash.ToLower()
Add-ManifestSkillEntry -ManifestPath (Join-Path $HG_TGT '.build-manifest.json') `
    -Key 'skills/que68-hash-gate/SKILL.md' -Hash $staleHash

# NOW the operator overwrites with their own Shape C body — DIFFERENT hash.
[System.IO.File]::WriteAllText((Join-Path $hgDir 'SKILL.md'), `
    "---`nname: que68-hash-gate`ndescription: operator Shape C version`n---`noperator-authored Shape C body`n", $utf8NoBom)

# Re-install. Hash gate must detect the modification (hash mismatch) and PRESERVE.
Invoke-InstallClaude -EnvFile $HG_ENV | Out-Null
Assert-File 'install-shape-c.test: F-1: hash gate preserves operator-modified orphan subdir' `
    (Join-Path $hgDir 'SKILL.md')
if (Test-Path -LiteralPath (Join-Path $hgDir 'SKILL.md') -PathType Leaf) {
    $hg_content = Get-Content -LiteralPath (Join-Path $hgDir 'SKILL.md') -Raw
    Assert-Contains 'install-shape-c.test: F-1: hash gate preserves operator content verbatim' `
        $hg_content 'operator-authored Shape C body'
} else {
    _Fail 'install-shape-c.test: F-1: hash gate preserves operator content verbatim' 'subdir deleted by orphan cleanup despite hash mismatch'
}

Remove-Item -LiteralPath $HG_DIR -Recurse -Force -ErrorAction SilentlyContinue

# ===========================================================================
# Part 4 — operator skill named.install-bak.* survives install + rollback
# ===========================================================================
# Per-subdir skills backups live in a run-private root OUTSIDE skills/
# ($TARGET/.install-bak.d/), so an operator-authored Shape C skill literally
# named ".install-bak.foo" is NOT treated as an installer backup by the swap,
# cleanup, or rollback paths. Pre-fix the success-cleanup loop globbed
# "$TARGET/skills/.install-bak.*" and deleted it on every install (F1); rollback
# globbed the same and mis-restored it to skills/foo (F3). Labels match the bash
# twin (tests/install-shape-c.test.sh) per the parity contract.
$BN_DIR = Join-Path ([IO.Path]::GetTempPath()) ('shape-c-bakns-' + [Guid]::NewGuid().Guid.Substring(0,8))
$BN_TGT = Join-Path $BN_DIR 'tgt'
New-Item -ItemType Directory -Path $BN_TGT -Force | Out-Null
$BN_ENV = Join-Path $BN_DIR 'local.env'
Write-LocalEnvFixture -EnvFile $BN_ENV -ConfigDir $BN_TGT -VaultDir (Join-Path $BN_DIR 'vault')

# First install — clean baseline.
Invoke-InstallClaude -EnvFile $BN_ENV | Out-Null

# Operator authors a Shape C skill whose name collides with the reserved backup
# prefix. Astronomically unlikely, but a reserved namespace must hold.
$bakNsDir = Join-Path $BN_TGT 'skills' '.install-bak.foo'
New-Item -ItemType Directory -Path $bakNsDir -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $bakNsDir 'SKILL.md'), `
    "---`nname: install-bak-foo`ndescription: operator skill with reserved-prefix name`n---`noperator backup-prefix body`n", `
    $utf8NoBom)

# Re-install (normal success path). The reserved-prefix skill must survive the
# success cleanup; the run-private backup root must be removed (no lingering junk).
$bn_status = Invoke-InstallClaude -EnvFile $BN_ENV
Assert-Eq 'install exits 0 with a reserved-prefix operator skill present' '0' "$bn_status"
Assert-File 'operator .install-bak.foo skill survives install (cleanup no longer globs skills/)' `
    (Join-Path $bakNsDir 'SKILL.md')
if (Test-Path -LiteralPath (Join-Path $bakNsDir 'SKILL.md') -PathType Leaf) {
    $bn_content = Get-Content -LiteralPath (Join-Path $bakNsDir 'SKILL.md') -Raw
    Assert-Contains 'operator .install-bak.foo content preserved verbatim through install' `
        $bn_content 'operator backup-prefix body'
} else {
    _Fail 'operator .install-bak.foo content preserved verbatim through install' 'skill lost on install'
}
if (Test-Path -LiteralPath (Join-Path $BN_TGT '.install-bak.d')) {
    _Fail 'run-private backup root removed after successful install' '.install-bak.d still present'
} else {
    _Pass 'run-private backup root removed after successful install'
}

# Now prove it survives a ROLLBACK. The test-only fault-injection seam forces a
# deterministic swap failure on "hooks" — a managed path AFTER skills, so the
# skills swap has already happened when Restore-Backups runs.
$env:AI_CONFIG_INSTALL_TEST_FAIL_SWAP = 'hooks'
try {
    $br_status = Invoke-InstallClaude -EnvFile $BN_ENV
} finally {
    Remove-Item Env:AI_CONFIG_INSTALL_TEST_FAIL_SWAP -ErrorAction SilentlyContinue
}
if ("$br_status" -ne '0') {
    _Pass 'forced swap failure aborts install (nonzero exit)'
} else {
    _Fail 'forced swap failure aborts install (nonzero exit)' 'exit was 0'
}
Assert-File 'operator .install-bak.foo skill survives rollback' `
    (Join-Path $bakNsDir 'SKILL.md')
if (Test-Path -LiteralPath (Join-Path $BN_TGT 'skills' 'foo') -PathType Container) {
    _Fail 'rollback did not mis-restore .install-bak.foo to skills/foo' 'skills/foo created'
} else {
    _Pass 'rollback did not mis-restore .install-bak.foo to skills/foo'
}
if (Test-Path -LiteralPath (Join-Path $BN_TGT '.install-bak.d')) {
    _Fail 'run-private backup root removed after rollback' '.install-bak.d still present'
} else {
    _Pass 'run-private backup root removed after rollback'
}
Assert-File 'managed skills restored after rollback' `
    (Join-Path $BN_TGT 'skills' 'session-agent' 'SKILL.md')

# --- crash-recovery — a leftover.install-bak.d is recovered, not lost ---
# Simulate an install that crashed mid-swap: a skill was moved into the
# run-private backup root but its replacement was never moved into place (its
# live counterpart is missing). The NEXT install must restore it BEFORE the
# swap loop and never blind-delete the only surviving copy (Codex adversarial F2).
$recoverBak = Join-Path $BN_TGT '.install-bak.d' 'skills' 'que147-recover'
New-Item -ItemType Directory -Path $recoverBak -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $recoverBak 'SKILL.md'), `
    "---`nname: que147-recover`ndescription: crashed-install backup body`n---`nrecovered body`n", $utf8NoBom)
$recoverLive = Join-Path $BN_TGT 'skills' 'que147-recover'
if (Test-Path -LiteralPath $recoverLive) { Remove-Item -LiteralPath $recoverLive -Recurse -Force }
$bn_rec_status = Invoke-InstallClaude -EnvFile $BN_ENV
Assert-Eq 'install exits 0 after recovering a crashed prior install' '0' "$bn_rec_status"
Assert-File 'crash-recovery restores a backed-up skill whose live copy was missing' `
    (Join-Path $recoverLive 'SKILL.md')
if (Test-Path -LiteralPath (Join-Path $recoverLive 'SKILL.md') -PathType Leaf) {
    Assert-Contains 'crash-recovery restores the backup content verbatim' `
        (Get-Content -LiteralPath (Join-Path $recoverLive 'SKILL.md') -Raw) 'recovered body'
}
if (Test-Path -LiteralPath (Join-Path $BN_TGT '.install-bak.d')) {
    _Fail 'run-private backup root removed after crash-recovery' '.install-bak.d still present'
} else {
    _Pass 'run-private backup root removed after crash-recovery'
}
Assert-File 'operator .install-bak.foo survives crash-recovery too' `
    (Join-Path $bakNsDir 'SKILL.md')

Remove-Item -LiteralPath $BN_DIR -Recurse -Force -ErrorAction SilentlyContinue

# ===========================================================================
# Part N1 — collision warn when install replaces a skills/<base> subdir no
# prior framework install authored (claude, live; mirrors the bash twin).
# Invoke-InstallClaude suppresses stderr (*>$null), so invoke directly with
# 2>&1 to capture Warn's [Console]::Error output.
# ===========================================================================
$N1_DIR = Join-Path ([IO.Path]::GetTempPath()) ('shape-c-n1-' + [Guid]::NewGuid().Guid.Substring(0,8))
$N1_TGT = Join-Path $N1_DIR 'tgt'
New-Item -ItemType Directory -Path (Join-Path $N1_TGT 'skills' 'session-agent') -Force | Out-Null
$N1_ENV = Join-Path $N1_DIR 'local.env'
Write-LocalEnvFixture -EnvFile $N1_ENV -ConfigDir $N1_TGT -VaultDir (Join-Path $N1_DIR 'vault')
[System.IO.File]::WriteAllText((Join-Path $N1_TGT 'skills' 'session-agent' 'SKILL.md'), `
    "---`nname: session-agent`ndescription: operator collision fixture`n---`n# operator body`n", `
    $utf8NoBom)

$env:AI_CONFIG_LOCAL_ENV = $N1_ENV
try {
    $n1_out = (& pwsh -NoProfile -File $INSTALL_PS1 --harness claude 2>&1 | Out-String)
    $n1_status = $LASTEXITCODE
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
Assert-Eq 'install-shape-c.test: N1: install still exits 0 on a colliding non-framework skill' '0' "$n1_status"
Assert-Contains 'install-shape-c.test: N1: collision warns for a non-framework-authored skills subdir' `
    $n1_out 'replacing skills/session-agent which no prior framework install authored'
if (Test-Path -LiteralPath (Join-Path $N1_TGT 'skills' 'session-agent' 'SKILL.md') -PathType Leaf) {
    Assert-NotContains 'install-shape-c.test: N1: framework session-agent replaces the colliding operator body' `
        (Get-Content -LiteralPath (Join-Path $N1_TGT 'skills' 'session-agent' 'SKILL.md') -Raw) 'operator body'
}
# A SECOND install (now manifest-authored) must NOT warn.
$env:AI_CONFIG_LOCAL_ENV = $N1_ENV
try {
    $n1_out2 = (& pwsh -NoProfile -File $INSTALL_PS1 --harness claude 2>&1 | Out-String)
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
Assert-NotContains 'install-shape-c.test: N1: no collision warn on a normal framework re-install' `
    $n1_out2 'no prior framework install authored'

Remove-Item -LiteralPath $N1_DIR -Recurse -Force -ErrorAction SilentlyContinue

# ===========================================================================
# Part app-owned plugins — check-drift IGNORES app-owned plugins/ on a claude
# target (managed-vs-app-owned gate; mirrors the bash twin). Claude Code writes
# plugins/known_marketplaces.json into the config dir; the manifest has no
# managed plugins, so plugins/ must not be scanned or flagged.
# ===========================================================================
$AP_DIR = Join-Path ([IO.Path]::GetTempPath()) ('shape-c-ap-' + [Guid]::NewGuid().Guid.Substring(0,8))
$AP_TGT = Join-Path $AP_DIR 'tgt'
New-Item -ItemType Directory -Path $AP_TGT -Force | Out-Null
$AP_ENV = Join-Path $AP_DIR 'local.env'
Write-LocalEnvFixture -EnvFile $AP_ENV -ConfigDir $AP_TGT -VaultDir (Join-Path $AP_DIR 'vault')
[void](Invoke-InstallClaude -EnvFile $AP_ENV)
New-Item -ItemType Directory -Path (Join-Path $AP_TGT 'plugins' 'cache' 'marketplace-x') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $AP_TGT 'plugins' 'known_marketplaces.json'), '{}', $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $AP_TGT 'plugins' 'cache' 'marketplace-x' 'data.json'), "cached`n", $utf8NoBom)
$ap_out = (& pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $AP_TGT 2>&1 | Out-String)
$ap_status = $LASTEXITCODE
Assert-Eq 'install-shape-c.test: check-drift ignores app-owned plugins/ on a claude target (exit 0)' '0' "$ap_status"
Assert-NotContains 'install-shape-c.test: check-drift does not flag app-owned plugins/known_marketplaces.json' `
    $ap_out 'known_marketplaces.json'
Remove-Item -LiteralPath $AP_DIR -Recurse -Force -ErrorAction SilentlyContinue
