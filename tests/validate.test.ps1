#Requires -Version 7
# tests/validate.test.ps1 — Windows-native twin of tests/validate.test.sh.
#
# Forbidden-roots allowlist behavior.
# Tests INJECT.claude/ etc. children into $REPO_ROOT and invoke validate.ps1,
# cleaning up inline.
#
# Mirrors tests/validate.test.sh 1:1.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$VALIDATE_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'validate.ps1'
Assert-File 'validate.test: scripts/validate.ps1 exists' $VALIDATE_PS1

function Get-VtSuffix {
    return ("$PID-" + [Guid]::NewGuid().Guid.Substring(0,4))
}

function Remove-IfEmpty {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
        if ($children.Count -eq 0) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-LfFile {
    param([string]$Path, [string]$Content)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# --- Test 1: baseline ---
Assert-Exit 'validate.test: validate.ps1 passes from $REPO_ROOT' 0 -- pwsh -NoProfile -File $VALIDATE_PS1

# <TEAM>-394: the FAIL-expecting injection tests below run against a hermetic
# tracked-only fixture copy, NOT $REPO_ROOT — in a co-located living home the
# real .claude/.codex are the operator's RECOGNIZED config dirs (and .agents an
# info/exclude-declared workspace), so validate rightly exempts them and an
# injected sentinel can never produce the expected failure there. Mirrors the
# bash twin's VAL_GUARD_FIX.
$VAL_GUARD_FIX = Join-Path ([IO.Path]::GetTempPath()) ('val-guard-' + [Guid]::NewGuid().Guid.Substring(0,8))
Copy-RepoTracked $VAL_GUARD_FIX
$GUARD_VALIDATE = Join-Path $VAL_GUARD_FIX 'scripts' 'validate.ps1'

# --- Test 2: hand-edit-only child rejected ---
$VAL_HAND_EDIT = ".test-t60-hand-edit-$(Get-VtSuffix)"
$claudeDir = Join-Path $VAL_GUARD_FIX '.claude'
New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
Write-LfFile (Join-Path $claudeDir $VAL_HAND_EDIT) "simulated hand-edit`n"
Assert-Exit 'validate.test: validate.ps1 fails on a non-allowlisted child in .claude/' 1 -- pwsh -NoProfile -File $GUARD_VALIDATE
Remove-Item -LiteralPath (Join-Path $claudeDir $VAL_HAND_EDIT) -Force -ErrorAction SilentlyContinue
Remove-IfEmpty $claudeDir
# Tests 3/4 below deliberately stay on $REPO_ROOT — they expect PASS, which
# holds both on a clean clone (allowlist) and in a living home (exemption).
$claudeDir = Join-Path $env:REPO_ROOT '.claude'

# --- Test 3:.claude/worktrees/ as the only child must PASS ---
$wtName = '.test-t60-fake-worktree-' + (Get-VtSuffix)
$wtPath = Join-Path $claudeDir 'worktrees' $wtName
New-Item -ItemType Directory -Path $wtPath -Force | Out-Null
Assert-Exit 'validate.test: validate.ps1 passes when .claude/ has only worktrees/' 0 -- pwsh -NoProfile -File $VALIDATE_PS1
Remove-Item -LiteralPath $wtPath -Recurse -Force -ErrorAction SilentlyContinue
Remove-IfEmpty (Join-Path $claudeDir 'worktrees')
Remove-IfEmpty $claudeDir

# --- Test 4:.claude/settings.local.json as the only child must PASS ---
$settingsLocal = Join-Path $claudeDir 'settings.local.json'
if (Test-Path -LiteralPath $settingsLocal) {
    _Skip 'validate.test: validate.ps1 passes when .claude/ has only settings.local.json' `
        'real settings.local.json present at $REPO_ROOT/.claude/ — refusing to overwrite'
} else {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
    Write-LfFile $settingsLocal "{}`n"
    Assert-Exit 'validate.test: validate.ps1 passes when .claude/ has only settings.local.json' 0 -- pwsh -NoProfile -File $VALIDATE_PS1
    Remove-Item -LiteralPath $settingsLocal -Force -ErrorAction SilentlyContinue
    Remove-IfEmpty $claudeDir
}

# --- Tests 4a-4f: per-project Claude Code convention files must FAIL ---
# Runs in the hermetic guard fixture (<TEAM>-394): no skip-if-real needed, and
# coverage holds even in a co-located living home.
foreach ($ct_base in @('.claude', '.codex', '.agents')) {
    $ct_dir = Join-Path $VAL_GUARD_FIX $ct_base
    foreach ($cc_name in @('CLAUDE.md', 'settings.json')) {
        $cc_target = Join-Path $ct_dir $cc_name
        New-Item -ItemType Directory -Path $ct_dir -Force | Out-Null
        Write-LfFile $cc_target "# test fixture`n"
        $val_he_output = & pwsh -NoProfile -File $GUARD_VALIDATE 2>&1
        $val_he_exit = $LASTEXITCODE
        if ($val_he_output -is [array]) { $val_he_output = $val_he_output -join "`n" }
        Remove-Item -LiteralPath $cc_target -Force -ErrorAction SilentlyContinue
        Remove-IfEmpty $ct_dir
        Assert-Eq "validate.test: validate.ps1 exits 1 when ${ct_base}/ has only $cc_name" `
            '1' "$val_he_exit"
        Assert-Contains "validate.test: validate.ps1 ${ct_base}/$cc_name message says 'hand-edit'" `
            $val_he_output 'hand-edit'
    }
}

# --- Tests 4g-4i: skills/ at repo root rejected with security-flavored message ---
foreach ($ct_base in @('.claude', '.codex', '.agents')) {
    $ct_dir = Join-Path $env:REPO_ROOT $ct_base
    $skillsDir = Join-Path $ct_dir 'skills'
    if (Test-Path -LiteralPath $skillsDir) {
        _Skip "validate.test: validate.ps1 rejects ${ct_base}/skills/ with security message" `
            "real ${ct_base}/skills/ present at `$REPO_ROOT — refusing to overwrite"
        continue
    }
    $fakeSkill = Join-Path $skillsDir (".test-t70-fake-skill-" + (Get-VtSuffix))
    New-Item -ItemType Directory -Path $fakeSkill -Force | Out-Null
    $val_skills_output = & pwsh -NoProfile -File $VALIDATE_PS1 2>&1
    $val_skills_exit = $LASTEXITCODE
    if ($val_skills_output -is [array]) { $val_skills_output = $val_skills_output -join "`n" }
    Remove-Item -LiteralPath $skillsDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-IfEmpty $ct_dir
    Assert-Eq "validate.test: validate.ps1 exits 1 on ${ct_base}/skills/" '1' "$val_skills_exit"
    Assert-Contains "validate.test: validate.ps1 ${ct_base}/skills/ message says 'security'" `
        $val_skills_output 'security'
    Assert-Contains "validate.test: validate.ps1 ${ct_base}/skills/ message names the remediation path" `
        $val_skills_output 'never in a framework repo root'
}

# --- Tests 4j-4l: a CO-LOCATED config dir is recognized, not rejected (<TEAM>-285) ---
# Mirrors validate.test.sh: CLAUDE_CONFIG_DIR pointed at a repo-root .claude/ with
# a skills/ subdir + settings.json must PASS (recognized as the harness's own
# gitignored config dir); the same tree with the config dir ELSEWHERE still FAILS
# with the security message. Skip-if-real: never co-opt a real $REPO_ROOT/.claude.
$coloDir = Join-Path $env:REPO_ROOT '.claude'
if (Test-Path -LiteralPath $coloDir) {
    _Skip 'validate.test: validate.ps1 recognizes a co-located CLAUDE_CONFIG_DIR' `
        'real .claude/ present at $REPO_ROOT — refusing to co-opt as a config target'
} else {
    $coloSkill = Join-Path $coloDir 'skills' ('.test-t285-skill-' + (Get-VtSuffix))
    New-Item -ItemType Directory -Path $coloSkill -Force | Out-Null
    Write-LfFile (Join-Path $coloDir 'settings.json') "{}`n"
    $savedCfg = $env:CLAUDE_CONFIG_DIR
    # (a) config dir IS this .claude/ → recognized → PASS
    $env:CLAUDE_CONFIG_DIR = $coloDir
    Assert-Exit 'validate.test: validate.ps1 recognizes a co-located CLAUDE_CONFIG_DIR (skills/+settings.json PASS)' 0 -- pwsh -NoProfile -File $VALIDATE_PS1
    # (b) config dir is a DIFFERENT existing dir → not recognized → still FAILS
    $coloElse = Join-Path $env:REPO_ROOT ('.test-t285-elsewhere-' + (Get-VtSuffix))
    New-Item -ItemType Directory -Path $coloElse -Force | Out-Null
    $env:CLAUDE_CONFIG_DIR = $coloElse
    $colo_out = & pwsh -NoProfile -File $VALIDATE_PS1 2>&1
    $colo_exit = $LASTEXITCODE
    if ($colo_out -is [array]) { $colo_out = $colo_out -join "`n" }
    $env:CLAUDE_CONFIG_DIR = $savedCfg
    Remove-IfEmpty $coloElse
    Assert-Eq 'validate.test: validate.ps1 still FAILS a foreign repo-root .claude/skills/' '1' "$colo_exit"
    Assert-Contains 'validate.test: validate.ps1 foreign .claude/skills/ keeps the security message' `
        $colo_out 'security'
    Remove-Item -LiteralPath (Join-Path $coloDir 'skills') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $coloDir 'settings.json') -Force -ErrorAction SilentlyContinue
    Remove-IfEmpty $coloDir
}

# --- Test 5: mixed (worktrees/ + hand-edit) must FAIL ---
# Hermetic guard fixture (<TEAM>-394).
$claudeDir = Join-Path $VAL_GUARD_FIX '.claude'
$wtName = '.test-t60-fake-worktree-' + (Get-VtSuffix)
$wtPath = Join-Path $claudeDir 'worktrees' $wtName
New-Item -ItemType Directory -Path $wtPath -Force | Out-Null
$VAL_MIXED_EDIT = ".test-t60-mixed-$(Get-VtSuffix)"
Write-LfFile (Join-Path $claudeDir $VAL_MIXED_EDIT) "mixed hand-edit`n"
Assert-Exit 'validate.test: validate.ps1 fails on mixed .claude/ (worktrees + hand-edit)' 1 -- pwsh -NoProfile -File $GUARD_VALIDATE
Remove-Item -LiteralPath (Join-Path $claudeDir $VAL_MIXED_EDIT) -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $wtPath -Recurse -Force -ErrorAction SilentlyContinue
Remove-IfEmpty (Join-Path $claudeDir 'worktrees')
Remove-IfEmpty $claudeDir

# --- Test 6: failure message surfaces the leaked path ---
New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
$VAL_DIAG_NAME = ".test-t60-diag-$(Get-VtSuffix)"
Write-LfFile (Join-Path $claudeDir $VAL_DIAG_NAME) "diag content`n"
$val_output = & pwsh -NoProfile -File $GUARD_VALIDATE 2>&1
$val_exit = $LASTEXITCODE
if ($val_output -is [array]) { $val_output = $val_output -join "`n" }
Remove-Item -LiteralPath (Join-Path $claudeDir $VAL_DIAG_NAME) -Force -ErrorAction SilentlyContinue
Remove-IfEmpty $claudeDir
Assert-Eq 'validate.test: validate.ps1 exits 1 on diag-name injection' '1' "$val_exit"
Assert-Contains 'validate.test: validate.ps1 failure surfaces leaked path' $val_output $VAL_DIAG_NAME

# --- F-1 amendment: parallel coverage for.codex/ and.agents/ ---
# Hermetic guard fixture (<TEAM>-394): no skip-if-real needed.
foreach ($ct_base in @('.codex', '.agents')) {
    $ct_dir = Join-Path $VAL_GUARD_FIX $ct_base
    $CT_INJECT = ".test-t60-${ct_base}-$(Get-VtSuffix)"
    New-Item -ItemType Directory -Path $ct_dir -Force | Out-Null
    Write-LfFile (Join-Path $ct_dir $CT_INJECT) "simulated hand-edit`n"
    Assert-Exit "validate.test: validate.ps1 fails on hand-edit in ${ct_base}/" 1 -- pwsh -NoProfile -File $GUARD_VALIDATE
    Remove-Item -LiteralPath (Join-Path $ct_dir $CT_INJECT) -Force -ErrorAction SilentlyContinue
    Remove-IfEmpty $ct_dir
}
# Guard-fixture teardown — fixture-scoped injection tests end here; the
# prune tests below target the REAL repo's scan behavior again.
Remove-Item -LiteralPath $VAL_GUARD_FIX -Recurse -Force -ErrorAction SilentlyContinue
$claudeDir = Join-Path $env:REPO_ROOT '.claude'

# --- other scans must prune harness-managed worktrees ---
# Test 7:.DS_Store inside.claude/worktrees/<name>/ must NOT trip validate.
$wtName = '.test-t61-fake-wt-' + (Get-VtSuffix)
$wtPath = Join-Path $claudeDir 'worktrees' $wtName
New-Item -ItemType Directory -Path $wtPath -Force | Out-Null
Write-LfFile (Join-Path $wtPath '.DS_Store') ''
Assert-Exit 'validate.test: validate.ps1 ignores .DS_Store inside .claude/worktrees/' 0 -- pwsh -NoProfile -File $VALIDATE_PS1
Remove-Item -LiteralPath $wtPath -Recurse -Force -ErrorAction SilentlyContinue
Remove-IfEmpty (Join-Path $claudeDir 'worktrees')
Remove-IfEmpty $claudeDir

# Test 8: secret-shaped fixture inside.claude/worktrees/<name>/ must NOT trip.
$secName = '.test-t61-sec-' + (Get-VtSuffix)
$secPath = Join-Path $claudeDir 'worktrees' $secName
New-Item -ItemType Directory -Path $secPath -Force | Out-Null
$val_t61_prefix = 'sk-'
$val_t61_body = 'fakefake1234567890_abcdefghij_test'
Write-LfFile (Join-Path $secPath 'fixture-secret.txt') ($val_t61_prefix + $val_t61_body + "`n")
Assert-Exit 'validate.test: validate.ps1 ignores secret-shaped strings inside .claude/worktrees/' 0 -- pwsh -NoProfile -File $VALIDATE_PS1
Remove-Item -LiteralPath $secPath -Recurse -Force -ErrorAction SilentlyContinue
Remove-IfEmpty (Join-Path $claudeDir 'worktrees')
Remove-IfEmpty $claudeDir

# F-B amendment: parallel coverage for.codex/worktrees/ and.agents/worktrees/.
foreach ($ct_base in @('.codex', '.agents')) {
    $ct_dir = Join-Path $env:REPO_ROOT $ct_base
    if (Test-Path -LiteralPath $ct_dir) {
        _Skip "validate.test: validate.ps1 ignores .DS_Store inside ${ct_base}/worktrees/" `
            "real ${ct_base}/ present at `$REPO_ROOT — refusing to inject"
        _Skip "validate.test: validate.ps1 ignores secret-shaped strings inside ${ct_base}/worktrees/" `
            "real ${ct_base}/ present at `$REPO_ROOT — refusing to inject"
        continue
    }
    $CT_WT_NAME = ".test-t61-fb-wt-${ct_base}-$(Get-VtSuffix)"
    $wtPathLocal = Join-Path $ct_dir 'worktrees' $CT_WT_NAME
    New-Item -ItemType Directory -Path $wtPathLocal -Force | Out-Null
    Write-LfFile (Join-Path $wtPathLocal '.DS_Store') ''
    Assert-Exit "validate.test: validate.ps1 ignores .DS_Store inside ${ct_base}/worktrees/" 0 -- pwsh -NoProfile -File $VALIDATE_PS1
    Remove-Item -LiteralPath $wtPathLocal -Recurse -Force -ErrorAction SilentlyContinue

    $CT_SEC_NAME = ".test-t61-fb-sec-${ct_base}-$(Get-VtSuffix)"
    $secPathLocal = Join-Path $ct_dir 'worktrees' $CT_SEC_NAME
    New-Item -ItemType Directory -Path $secPathLocal -Force | Out-Null
    $val_t61fb_prefix = 'sk-'
    $val_t61fb_body = 'fakefake1234567890_abcdefghij_test'
    Write-LfFile (Join-Path $secPathLocal 'fixture-secret.txt') ($val_t61fb_prefix + $val_t61fb_body + "`n")
    Assert-Exit "validate.test: validate.ps1 ignores secret-shaped strings inside ${ct_base}/worktrees/" 0 -- pwsh -NoProfile -File $VALIDATE_PS1
    Remove-Item -LiteralPath $secPathLocal -Recurse -Force -ErrorAction SilentlyContinue
    Remove-IfEmpty (Join-Path $ct_dir 'worktrees')
    Remove-IfEmpty $ct_dir
}

# --- secret-pattern scan catches a secret in a non-harness
# worktrees/ dir — re-premised on COMMITTABILITY (twin of
# tests/validate.test.sh)..gitignore ignores worktrees/ globally, so an
# untracked fixture there is uncommittable → pruned; the meaningful case is a
# TRACKED (force-added) file, which CAN be committed and MUST be scanned. The
# index is reset in cleanup so the force-added fixture leaves no staged orphan.
$suffix = Get-VtSuffix
$VAL_T66_FA_PARENT = "tests/fixtures/t66-fa-$suffix"
$VAL_T66_FA_DIR = "$VAL_T66_FA_PARENT/worktrees"
$secPath = Join-Path $env:REPO_ROOT $VAL_T66_FA_DIR
New-Item -ItemType Directory -Path $secPath -Force | Out-Null
$val_t66fa_prefix = 'sk-'
$val_t66fa_body = 'fakefake1234567890_abcdefghij_test'
Write-LfFile (Join-Path $secPath 'secret.txt') ($val_t66fa_prefix + $val_t66fa_body + "`n")
& git -C $env:REPO_ROOT add -f "$VAL_T66_FA_DIR/secret.txt" 2>$null | Out-Null
Assert-Exit 'validate.test: validate.ps1 catches secrets in a tracked non-harness worktrees/ dir' 1 -- pwsh -NoProfile -File $VALIDATE_PS1
& git -C $env:REPO_ROOT reset -q -- "$VAL_T66_FA_DIR/secret.txt" 2>$null | Out-Null
Remove-Item -LiteralPath (Join-Path $env:REPO_ROOT $VAL_T66_FA_PARENT) -Recurse -Force -ErrorAction SilentlyContinue

# --- gitignored runtime-artifact dir cross-model-out/ pruned from the
# secret-pattern scan ---
# Twin of tests/validate.test.sh. cross-model-out/ holds cross-model-
# review per-run output; it is gitignored runtime state that can never enter git,
# so validate.ps1 must not scan it for secrets. Sentinel lands in a representative
# non-log cross-model artifact (codex-review.md) to assert the DIRECTORY is pruned
# for ANY file under it (root-anchored exclusion), not just *.log.
# Secret CONSTRUCTED at runtime per [[feedback_self_tripping_test_source]].
$VAL_T244_DIR = "cross-model-out/.test-t244-$(Get-VtSuffix)"
$t244Path = Join-Path $env:REPO_ROOT $VAL_T244_DIR
New-Item -ItemType Directory -Path $t244Path -Force | Out-Null
$val_t244_prefix = 'sk-'
$val_t244_body = 'fakefake1234567890_abcdefghij_test'
Write-LfFile (Join-Path $t244Path 'codex-review.md') ($val_t244_prefix + $val_t244_body + "`n")
Assert-Exit 'validate.test: validate.ps1 ignores secret-shaped strings inside cross-model-out/' 0 -- pwsh -NoProfile -File $VALIDATE_PS1
Remove-Item -LiteralPath $t244Path -Recurse -Force -ErrorAction SilentlyContinue
# Remove cross-model-out/ only if empty — preserve any real one the operator owns.
Remove-IfEmpty (Join-Path $env:REPO_ROOT 'cross-model-out')

# anchoring regression guard (adversarial cross-model finding F3): the
# PS exclusion appends a path separator so it is ROOT-ANCHORED. A COMMITTABLE
# sibling whose name merely STARTS with "cross-model-out" (e.g.
# cross-model-out-archive/) is NOT gitignored and MUST still be scanned — a
# bare StartsWith (no separator) would over-match and skip it (a real blind
# spot). Sentinel constructed at runtime.
$VAL_T244_SIB = "cross-model-out-.test-t244-sib-$(Get-VtSuffix)"
$t244SibPath = Join-Path $env:REPO_ROOT $VAL_T244_SIB
New-Item -ItemType Directory -Path $t244SibPath -Force | Out-Null
$val_t244sib_prefix = 'sk-'
$val_t244sib_body = 'fakefake1234567890_abcdefghij_test'
Write-LfFile (Join-Path $t244SibPath 'secret.txt') ($val_t244sib_prefix + $val_t244sib_body + "`n")
Assert-Exit 'validate.test: validate.ps1 still catches secrets in a cross-model-out* sibling dir' 1 -- pwsh -NoProfile -File $VALIDATE_PS1
Remove-Item -LiteralPath $t244SibPath -Recurse -Force -ErrorAction SilentlyContinue

# --- a TRACKED file whose NAME matches a gitignore rule is still
# scanned.
# git ls-files --cached lists tracked files regardless of.gitignore, so a
# force-added daemon.log /.mcp.json carrying a secret IS in scope; a basename
# --exclude would have skipped them (a false negative). Index reset in cleanup. ---
foreach ($q246name in @("fixture-t246-$(Get-VtSuffix).log", ".test-t246-$(Get-VtSuffix).mcp.json")) {
    $q246prefix = 'sk-'
    $q246body = 'fakefake1234567890_abcdefghij_test'
    Write-LfFile (Join-Path $env:REPO_ROOT $q246name) ($q246prefix + $q246body + "`n")
    & git -C $env:REPO_ROOT add -f $q246name 2>$null | Out-Null
    Assert-Exit "validate.test: validate.ps1 scans a tracked gitignored-name file ($q246name)" 1 -- pwsh -NoProfile -File $VALIDATE_PS1
    & git -C $env:REPO_ROOT reset -q -- $q246name 2>$null | Out-Null
    Remove-Item -LiteralPath (Join-Path $env:REPO_ROOT $q246name) -Force -ErrorAction SilentlyContinue
}

# the committable-set scan still PASSES clean on the live tree — a
# positive guard that the enumeration didn't over-prune into a vacuous pass.
Assert-Exit 'validate.test: validate.ps1 passes clean on the committable set' 0 -- pwsh -NoProfile -File $VALIDATE_PS1

# --- <TEAM>-319: .DS_Store + embedded-.git scans honor the CO-LOCATED config dir
# exemption (twin of validate.test.sh's <TEAM>-319 block) ---
# A co-located install keeps the harness's own gitignored runtime state under the
# repo-root config dir — plugin clones carrying their own .git and Finder
# .DS_Store files. <TEAM>-319 hoists the co-located recognition above the two early
# tree-walk scans so they prune those; the contrast (config dir ELSEWHERE) must
# still FAIL. Inject into $REPO_ROOT/.hermes (skip-if-real) and drive recognition
# via HERMES_HOME so the operator's real .claude/.codex are never touched.
$q319Hermes = Join-Path $env:REPO_ROOT '.hermes'
if (Test-Path -LiteralPath $q319Hermes) {
    _Skip 'validate.test: validate.ps1 exempts embedded .git in a co-located config dir' `
        'real .hermes/ present at $REPO_ROOT — refusing to co-opt as a config target'
    _Skip 'validate.test: validate.ps1 still FAILS embedded .git when config dir is elsewhere' `
        'real .hermes/ present at $REPO_ROOT — refusing to co-opt as a config target'
    _Skip 'validate.test: validate.ps1 exempts .DS_Store in a co-located config dir' `
        'real .hermes/ present at $REPO_ROOT — refusing to co-opt as a config target'
    _Skip 'validate.test: validate.ps1 still FAILS .DS_Store when config dir is elsewhere' `
        'real .hermes/ present at $REPO_ROOT — refusing to co-opt as a config target'
} else {
    $q319Else = Join-Path $env:REPO_ROOT ('.test-q319-elsewhere-' + (Get-VtSuffix))
    New-Item -ItemType Directory -Path $q319Else -Force | Out-Null
    $q319SavedHermes = $env:HERMES_HOME

    # Scenario A — embedded .git (a plugin clone's own .git dir).
    $q319GitDir = Join-Path $q319Hermes 'plugins' ('.test-q319-' + (Get-VtSuffix)) '.git'
    New-Item -ItemType Directory -Path $q319GitDir -Force | Out-Null
    # (a) HERMES_HOME IS this .hermes/ → recognized → pruned → PASS.
    $env:HERMES_HOME = $q319Hermes
    Assert-Exit 'validate.test: validate.ps1 exempts embedded .git in a co-located config dir' 0 -- pwsh -NoProfile -File $VALIDATE_PS1
    # (b) HERMES_HOME elsewhere → not recognized → still FAILS on the embedded .git.
    $env:HERMES_HOME = $q319Else
    $q319_out = & pwsh -NoProfile -File $VALIDATE_PS1 2>&1
    $q319_exit = $LASTEXITCODE
    if ($q319_out -is [array]) { $q319_out = $q319_out -join "`n" }
    Assert-Eq 'validate.test: validate.ps1 still FAILS embedded .git when config dir is elsewhere' '1' "$q319_exit"
    Assert-Contains 'validate.test: validate.ps1 embedded-.git FAIL names the scan' `
        $q319_out 'embedded .git'
    Remove-Item -LiteralPath (Join-Path $q319Hermes 'plugins') -Recurse -Force -ErrorAction SilentlyContinue

    # Scenario B — a Finder .DS_Store directly under the config dir.
    Write-LfFile (Join-Path $q319Hermes '.DS_Store') ''
    # (a) recognized → pruned → PASS.
    $env:HERMES_HOME = $q319Hermes
    Assert-Exit 'validate.test: validate.ps1 exempts .DS_Store in a co-located config dir' 0 -- pwsh -NoProfile -File $VALIDATE_PS1
    # (b) elsewhere → still FAILS on the .DS_Store.
    $env:HERMES_HOME = $q319Else
    $q319b_out = & pwsh -NoProfile -File $VALIDATE_PS1 2>&1
    $q319b_exit = $LASTEXITCODE
    if ($q319b_out -is [array]) { $q319b_out = $q319b_out -join "`n" }
    Assert-Eq 'validate.test: validate.ps1 still FAILS .DS_Store when config dir is elsewhere' '1' "$q319b_exit"
    Assert-Contains 'validate.test: validate.ps1 .DS_Store FAIL names the scan' `
        $q319b_out 'DS_Store'
    # Clear the .hermes artifact before Scenario C so its assertion is unambiguous.
    Remove-Item -LiteralPath (Join-Path $q319Hermes '.DS_Store') -Force -ErrorAction SilentlyContinue
    Remove-IfEmpty $q319Hermes

    # Scenario C — a config var pointing at a NON-harness repo dir must NOT
    # exempt. Recognition is gated on a repo-root harness dir physically equaling
    # the config path — NOT on "any dir a config var points at". This is the
    # exact divergence the cross-model review caught: the first PS cut stored
    # every resolved config path and pruned under it, so a .DS_Store inside the
    # pointed-at non-harness dir wrongly PASSED. Locks bash↔PS parity.
    Write-LfFile (Join-Path $q319Else '.DS_Store') ''
    $env:HERMES_HOME = $q319Else
    $q319c_out = & pwsh -NoProfile -File $VALIDATE_PS1 2>&1
    $q319c_exit = $LASTEXITCODE
    if ($q319c_out -is [array]) { $q319c_out = $q319c_out -join "`n" }
    Assert-Eq 'validate.test: validate.ps1 does NOT exempt a non-harness dir a config var points at' '1' "$q319c_exit"
    Assert-Contains 'validate.test: validate.ps1 non-harness-cfg FAIL names the .DS_Store scan' `
        $q319c_out 'DS_Store'
    Remove-Item -LiteralPath (Join-Path $q319Else '.DS_Store') -Force -ErrorAction SilentlyContinue

    # Restore env + surgical cleanup (skip-if-real guaranteed .hermes/ was absent).
    $env:HERMES_HOME = $q319SavedHermes
    Remove-IfEmpty $q319Else
}

# --- <TEAM>-328 Item B: the .DS_Store + embedded-.git tree-walk scans FAIL
# CLOSED on a directory-enumeration error (twin of validate.test.sh's <TEAM>-328
# block) ---
# Test-DSStore / Test-EmbeddedGit now capture Get-ChildItem traversal errors via
# -ErrorVariable and FAIL closed; a bare -EA SilentlyContinue silently swallowed
# a permission-denied subdir, so an unreadable tree false-PASSed. Provoke a real
# enumeration error with a mode-000 subdir at the repo root: the recursive walk
# errors on it. The .DS_Store scan runs first, so its fail-closed message
# surfaces; the embedded-.git scan applies the identical -ErrorVariable pattern.
#
# Mechanism mirrors the secret-scan non-git fail-closed test in
# validate-ps.test.ps1: chmod 000 + a same-process probe, _Skip when the
# unreadable dir can't be created (running as root, or the Windows chmod no-op —
# so this runs only on a non-root Unix pwsh and SKIPs on the Windows lane).
# try/finally restores perms + removes so an interrupted run never orphans an
# unreadable dir in the live repo root.
$q328Lock = Join-Path $env:REPO_ROOT ('.test-q328-locked-' + (Get-VtSuffix))
if (Test-Path -LiteralPath $q328Lock) {
    _Skip 'validate.test: validate.ps1 tree-walk scan fails closed on a directory-enumeration error' "fixture collision: $q328Lock"
} else {
    try {
        New-Item -ItemType Directory -Path (Join-Path $q328Lock 'sub') -Force | Out-Null
        if (-not $IsWindows) { & chmod 000 $q328Lock 2>$null }
        # Probe in THIS process (same user as the child pwsh): does a -Recurse
        # walk actually error on the locked dir? If not (root / Windows no-op),
        # skip. Probe the locked dir directly, not the whole repo root (a recursive
        # walk of REPO_ROOT would be needlessly slow in a large workspace).
        $q328ProbeErr = $null
        $null = Get-ChildItem -LiteralPath $q328Lock -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable q328ProbeErr
        if (-not $q328ProbeErr -or $q328ProbeErr.Count -eq 0) {
            _Skip 'validate.test: validate.ps1 tree-walk scan fails closed on a directory-enumeration error' 'could not create an unreadable dir (root or Windows chmod no-op)'
        } else {
            $q328_out = & pwsh -NoProfile -File $VALIDATE_PS1 2>&1
            $q328_exit = $LASTEXITCODE
            if ($q328_out -is [array]) { $q328_out = $q328_out -join "`n" }
            if ($q328_exit -eq 1 -and $q328_out -match 'enumeration errored') {
                _Pass 'validate.test: validate.ps1 tree-walk scan fails closed on a directory-enumeration error'
            } else {
                _Fail 'validate.test: validate.ps1 tree-walk scan fails closed on a directory-enumeration error' "expected exit 1 + 'enumeration errored', got exit $q328_exit", $q328_out
            }
        }
    } finally {
        if (-not $IsWindows -and (Test-Path -LiteralPath $q328Lock)) { & chmod 0755 $q328Lock 2>$null }
        Remove-Item -LiteralPath $q328Lock -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- <TEAM>-394: projects/ workspace junk must not trip the junk scans ---
# Twin of the bash case: the shipped .gitignore declares projects/ the
# operator's local project workspace ("never tracked"); a real workspace holds
# whole checkouts, so a nested .git dir or a Finder .DS_Store there is operator
# content, not framework content. Plants junk in the REAL repo's projects/
# (gitignored) and expects validate to stay green.
$vt394 = Join-Path $env:REPO_ROOT 'projects' (".test-t394-" + (Get-VtSuffix))
try {
    New-Item -ItemType Directory -Path (Join-Path $vt394 'nested' '.git') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $vt394 '.DS_Store') -Force | Out-Null
    & pwsh -NoProfile -File $VALIDATE_PS1 *>$null
    Assert-Eq 'validate.test: validate.ps1 ignores .DS_Store + nested .git under projects/ (operator workspace)' `
        '0' "$LASTEXITCODE"
} finally {
    Remove-Item -LiteralPath $vt394 -Recurse -Force -ErrorAction SilentlyContinue
}

# --- <TEAM>-394: .git/info/exclude declares an operator harness workspace ---
# Twin of the bash case: a repo-root .agents/skills with no local declaration
# still trips the finding-#8 guard; adding `.agents/` to the fixture's
# .git/info/exclude flips it to a recognized operator workspace.
$vieFix = Join-Path ([IO.Path]::GetTempPath()) ('vie-' + [Guid]::NewGuid().Guid.Substring(0,8))
try {
    Copy-RepoTracked $vieFix
    & git -C $vieFix init -q . 2>$null
    New-Item -ItemType Directory -Path (Join-Path $vieFix '.agents' 'skills') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $vieFix '.agents' 'skills' 'SKILL.md'), "fixture`n")
    & pwsh -NoProfile -File (Join-Path $vieFix 'scripts' 'validate.ps1') *>$null
    Assert-Eq 'validate.test: validate.ps1 guards a repo-root .agents/skills with no local declaration' `
        '1' "$LASTEXITCODE"
    Add-Content -LiteralPath (Join-Path $vieFix '.git' 'info' 'exclude') -Value '.agents/'
    & pwsh -NoProfile -File (Join-Path $vieFix 'scripts' 'validate.ps1') *>$null
    Assert-Eq 'validate.test: validate.ps1 recognizes an info/exclude-declared harness workspace (.agents)' `
        '0' "$LASTEXITCODE"
    # Panel F2 narrowing: recognition is .agents-ONLY — an info/exclude'd
    # .claude/skills must STILL fail (the actual finding-#8 auto-load surface).
    Remove-Item -LiteralPath (Join-Path $vieFix '.agents') -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path (Join-Path $vieFix '.claude' 'skills') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $vieFix '.claude' 'skills' 'SKILL.md'), "fixture`n")
    Add-Content -LiteralPath (Join-Path $vieFix '.git' 'info' 'exclude') -Value '.claude/'
    & pwsh -NoProfile -File (Join-Path $vieFix 'scripts' 'validate.ps1') *>$null
    Assert-Eq 'validate.test: validate.ps1 still guards .claude/skills even when info/exclude''d (finding #8 kept)' `
        '1' "$LASTEXITCODE"
} finally {
    Remove-Item -LiteralPath $vieFix -Recurse -Force -ErrorAction SilentlyContinue
}
