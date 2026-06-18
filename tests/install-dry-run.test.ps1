#Requires -Version 7
# tests/install-dry-run.test.ps1 — Windows-native twin of tests/install-dry-run.test.sh.
#
# install.ps1 -DryRun classifies the LIVE target against the freshly-built NEW
# manifest and the OLD installed manifest, and REPORTS the state of every
# framework-managed file (managed/missing/broken/custom/stale) WITHOUT writing
# anything. Pins: the five classes, the no-write guarantee, and that a real
# install (repair) restores managed/broken/missing while PRESERVING operator-
# custom (Shape C) content.
#
# Per [[feedback_port_parity_vs_regression_split]] the AC labels match the bash
# twin so the parity contract (same AC count + same PASS/FAIL on identical
# fixtures) holds. Execution-verified under local pwsh per
# [[feedback_ps_twin_execution_verify]].
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$INSTALL_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$utf8NoBom   = [System.Text.UTF8Encoding]::new($false)

function Get-Sha {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}
# Run a real install (no flag), return exit code.
function Invoke-InstallClaude {
    param([Parameter(Mandatory)][string]$EnvFile)
    $env:AI_CONFIG_LOCAL_ENV = $EnvFile
    try { & pwsh -NoProfile -File $INSTALL_PS1 --harness claude *>$null; return $LASTEXITCODE }
    finally { Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue }
}
# Run install.ps1 --dry-run, return its stdout report as a single string.
function Invoke-DryRun {
    param([Parameter(Mandatory)][string]$EnvFile)
    $env:AI_CONFIG_LOCAL_ENV = $EnvFile
    try { return ((& pwsh -NoProfile -File $INSTALL_PS1 --dry-run 2>$null) | Out-String) }
    finally { Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue }
}
# Fingerprint a tree as "<relpath>\t<sha>" lines — for the no-write proof.
function Get-TreeFingerprint {
    param([Parameter(Mandatory)][string]$Root)
    $items = Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Sort-Object FullName
    ($items | ForEach-Object {
        "$($_.FullName.Substring($Root.Length))`t$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower())"
    }) -join "`n"
}

$DR_DIR = Join-Path ([IO.Path]::GetTempPath()) ('dry-run-' + [Guid]::NewGuid().Guid.Substring(0,8))
$DR_TGT = Join-Path $DR_DIR 'tgt'
New-Item -ItemType Directory -Path $DR_TGT -Force | Out-Null
$DR_ENV = Join-Path $DR_DIR 'local.env'
Write-LocalEnvFixture -EnvFile $DR_ENV -ConfigDir $DR_TGT -VaultDir (Join-Path $DR_DIR 'vault')

Assert-Eq "install.sh exits 0 (dry-run setup)" "0" ([string](Invoke-InstallClaude -EnvFile $DR_ENV))

# --- 1) in-sync target: managed>0, zero stale/broken/missing ---------------
$drOut = Invoke-DryRun -EnvFile $DR_ENV
$env:AI_CONFIG_LOCAL_ENV = $DR_ENV
try { & pwsh -NoProfile -File $INSTALL_PS1 --dry-run *>$null; $drExit = $LASTEXITCODE }
finally { Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue }
Assert-Eq "--dry-run exits 0 on an in-sync target" "0" ([string]$drExit)
Assert-Contains "--dry-run announces it wrote nothing" $drOut "no changes written (dry-run)"
Assert-Contains "in-sync target: stale 0"   $drOut "stale:   0"
Assert-Contains "in-sync target: broken 0"  $drOut "broken:  0"
Assert-Contains "in-sync target: missing 0" $drOut "missing: 0"
Assert-Contains "in-sync target: declared in sync" $drOut "in sync with the current framework"

# --- 2) -DryRun writes nothing: tree is byte-identical before/after ---------
$fpBefore = Get-TreeFingerprint -Root $DR_TGT
[void](Invoke-DryRun -EnvFile $DR_ENV)
$fpAfter = Get-TreeFingerprint -Root $DR_TGT
Assert-Eq "--dry-run leaves the target byte-identical (writes nothing)" $fpBefore $fpAfter
$leftover = @(Get-ChildItem -LiteralPath $DR_TGT -Filter '.install-build.*' -Force -ErrorAction SilentlyContinue)
Assert-Eq "--dry-run leaves no .install-build.* temp dir" "0" ([string]$leftover.Count)

# --- 3) broken + missing + custom in one mutated target --------------------
[System.IO.File]::AppendAllText((Join-Path $DR_TGT 'CLAUDE.md'), "`nDRYRUN_BROKEN_MARKER`n", $utf8NoBom)
Remove-Item -LiteralPath (Join-Path $DR_TGT 'SKILLS.md') -Force
$customDir = Join-Path $DR_TGT 'skills' 'dry-run-custom-fixture'
New-Item -ItemType Directory -Path $customDir -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $customDir 'SKILL.md'),
    "---`nname: dry-run-custom-fixture`ndescription: Shape C fixture`n---`n# body`n", $utf8NoBom)

$drOut2 = Invoke-DryRun -EnvFile $DR_ENV
Assert-Contains "hand-edited CLAUDE.md classified broken" $drOut2 "broken:  1"
Assert-Contains "broken list names CLAUDE.md"             $drOut2 "- CLAUDE.md"
Assert-Contains "removed SKILLS.md classified missing"    $drOut2 "missing: 1"
Assert-Contains "missing list names SKILLS.md"            $drOut2 "- SKILLS.md"
Assert-Contains "operator skill classified custom"        $drOut2 "custom:  1"
Assert-NotContains "custom skill is not flagged as drift" $drOut2 "dry-run-custom-fixture"

# --- 4) repair: a real install restores managed/broken/missing, keeps custom -
Assert-Eq "install (repair) exits 0" "0" ([string](Invoke-InstallClaude -EnvFile $DR_ENV))
Assert-File "repair restored the missing SKILLS.md" (Join-Path $DR_TGT 'SKILLS.md')
Assert-NotContains "repair overwrote the broken CLAUDE.md (marker gone)" `
    (Get-Content -Raw -LiteralPath (Join-Path $DR_TGT 'CLAUDE.md')) "DRYRUN_BROKEN_MARKER"
Assert-File "repair PRESERVED the operator-custom skill" (Join-Path $customDir 'SKILL.md')

# --- 5) stale: on-disk matches the OLD manifest but the NEW build differs ----
$DR_TGT2 = Join-Path $DR_DIR 'tgt2'
New-Item -ItemType Directory -Path $DR_TGT2 -Force | Out-Null
$DR_ENV2 = Join-Path $DR_DIR 'local.env2'
Write-LocalEnvFixture -EnvFile $DR_ENV2 -ConfigDir $DR_TGT2 -VaultDir (Join-Path $DR_DIR 'vault2')
[void](Invoke-InstallClaude -EnvFile $DR_ENV2)
[System.IO.File]::WriteAllText((Join-Path $DR_TGT2 'CLAUDE.md'), "STALE-FRAMEWORK-STATE`n", $utf8NoBom)
$staleSha = Get-Sha -Path (Join-Path $DR_TGT2 'CLAUDE.md')
$man = Join-Path $DR_TGT2 '.build-manifest.json'
$jq = (Get-Command jq -ErrorAction Stop).Source
$manOut = Get-Content -Raw -LiteralPath $man | & $jq --arg h $staleSha '.generated["CLAUDE.md"] = $h'
if ($manOut -is [array]) { $manOut = $manOut -join "`n" }
[System.IO.File]::WriteAllText($man, $manOut, $utf8NoBom)
$drOut3 = Invoke-DryRun -EnvFile $DR_ENV2
Assert-Contains "matches-old-but-not-new classified stale" $drOut3 "stale:   1"
Assert-Contains "stale list names CLAUDE.md"               $drOut3 "- CLAUDE.md"
Assert-Contains "stale (not broken) — broken stays 0"      $drOut3 "broken:  0"
Assert-Contains "stale target prompts a reconcile"         $drOut3 "re-run without --dry-run to reconcile"

# --- 6) -DryRun rejects multi-harness (parity with -BuildOnly) --------------
$env:AI_CONFIG_LOCAL_ENV = $DR_ENV
try {
    & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --harness codex --dry-run *>$null
    $multiExit = $LASTEXITCODE
} finally { Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue }
Assert-Eq "--dry-run + multiple --harness is rejected (exit 1)" "1" ([string]$multiExit)

# --- 7) a managed path replaced by a DIRECTORY classifies broken, never aborts -
# (cross-model adversarial finding: Get-FileHash on a dir throws under StrictMode
# and would abort the report instead of reporting it broken.)
$dirTgt = Join-Path $DR_DIR 'tgt3'; New-Item -ItemType Directory -Path $dirTgt -Force | Out-Null
$dirEnv = Join-Path $DR_DIR 'local.env3'
Write-LocalEnvFixture -EnvFile $dirEnv -ConfigDir $dirTgt -VaultDir (Join-Path $DR_DIR 'v3')
$env:AI_CONFIG_LOCAL_ENV = $dirEnv
try { & pwsh -NoProfile -File $INSTALL_PS1 --harness claude *>$null } finally { Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath (Join-Path $dirTgt 'CLAUDE.md') -Force
New-Item -ItemType Directory -Path (Join-Path $dirTgt 'CLAUDE.md') -Force | Out-Null   # managed file → directory
$env:AI_CONFIG_LOCAL_ENV = $dirEnv
try { $dirOut = (& pwsh -NoProfile -File $INSTALL_PS1 --dry-run 2>$null) | Out-String; $dirExit = $LASTEXITCODE }
finally { Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue }
Assert-Eq "--dry-run exits 0 when a managed file is replaced by a directory" "0" ([string]$dirExit)
Assert-Contains "directory-where-a-file-is-expected classified broken" $dirOut "broken:  1"
Assert-Contains "broken list names the directory-occupied path" $dirOut "- CLAUDE.md"

# --- 8) -DryRun needs no write access to the target (builds in a system temp) --
# (cross-model adversarial finding.) Unix-permission scenario — skipped on Windows
# where a read-only directory attribute is advisory and does not block writes.
if ($IsWindows) {
    _Skip 'install-dry-run.test: --dry-run exits 0 against a read-only target' 'Unix perms; n/a on Windows'
    _Skip 'install-dry-run.test: --dry-run reports against a read-only target' 'Unix perms; n/a on Windows'
    _Skip 'install-dry-run.test: --dry-run writes no build dir under a read-only target' 'Unix perms; n/a on Windows'
} else {
    $roTgt = Join-Path $DR_DIR 'tgt4'; New-Item -ItemType Directory -Path $roTgt -Force | Out-Null
    $roEnv = Join-Path $DR_DIR 'local.env4'
    Write-LocalEnvFixture -EnvFile $roEnv -ConfigDir $roTgt -VaultDir (Join-Path $DR_DIR 'v4')
    $env:AI_CONFIG_LOCAL_ENV = $roEnv
    try { & pwsh -NoProfile -File $INSTALL_PS1 --harness claude *>$null } finally { Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue }
    chmod -R a-w $roTgt
    $env:AI_CONFIG_LOCAL_ENV = $roEnv
    try { $roOut = (& pwsh -NoProfile -File $INSTALL_PS1 --dry-run 2>$null) | Out-String; $roExit = $LASTEXITCODE }
    finally { Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue }
    $roBuild = @(Get-ChildItem -LiteralPath $roTgt -Filter '.install-build.*' -Force -ErrorAction SilentlyContinue)
    chmod -R u+w $roTgt     # restore so the final Remove-Item can clean up
    Assert-Eq "--dry-run exits 0 against a read-only target" "0" ([string]$roExit)
    Assert-Contains "--dry-run reports against a read-only target" $roOut "dry-run state"
    Assert-Eq "--dry-run writes no build dir under a read-only target" "0" ([string]$roBuild.Count)
}

Remove-Item -LiteralPath $DR_DIR -Recurse -Force -ErrorAction SilentlyContinue
