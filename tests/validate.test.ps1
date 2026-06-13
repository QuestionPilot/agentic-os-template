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

# --- Test 2: hand-edit-only child rejected ---
$VAL_HAND_EDIT = ".test-que60-hand-edit-$(Get-VtSuffix)"
$claudeDir = Join-Path $env:REPO_ROOT '.claude'
New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
Write-LfFile (Join-Path $claudeDir $VAL_HAND_EDIT) "simulated hand-edit`n"
Assert-Exit 'validate.test: validate.ps1 fails on a non-allowlisted child in .claude/' 1 -- pwsh -NoProfile -File $VALIDATE_PS1
Remove-Item -LiteralPath (Join-Path $claudeDir $VAL_HAND_EDIT) -Force -ErrorAction SilentlyContinue
Remove-IfEmpty $claudeDir

# --- Test 3:.claude/worktrees/ as the only child must PASS ---
$wtName = '.test-que60-fake-worktree-' + (Get-VtSuffix)
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
foreach ($ct_base in @('.claude', '.codex', '.agents')) {
    $ct_dir = Join-Path $env:REPO_ROOT $ct_base
    foreach ($cc_name in @('CLAUDE.md', 'settings.json')) {
        $cc_target = Join-Path $ct_dir $cc_name
        if (Test-Path -LiteralPath $cc_target) {
            _Skip "validate.test: validate.ps1 fails when ${ct_base}/ has only $cc_name" `
                "real $cc_name present at `$REPO_ROOT/${ct_base}/ — refusing to overwrite"
            continue
        }
        New-Item -ItemType Directory -Path $ct_dir -Force | Out-Null
        Write-LfFile $cc_target "# test fixture`n"
        $val_he_output = & pwsh -NoProfile -File $VALIDATE_PS1 2>&1
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
    $fakeSkill = Join-Path $skillsDir (".test-que70-fake-skill-" + (Get-VtSuffix))
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
    $coloSkill = Join-Path $coloDir 'skills' ('.test-que285-skill-' + (Get-VtSuffix))
    New-Item -ItemType Directory -Path $coloSkill -Force | Out-Null
    Write-LfFile (Join-Path $coloDir 'settings.json') "{}`n"
    $savedCfg = $env:CLAUDE_CONFIG_DIR
    # (a) config dir IS this .claude/ → recognized → PASS
    $env:CLAUDE_CONFIG_DIR = $coloDir
    Assert-Exit 'validate.test: validate.ps1 recognizes a co-located CLAUDE_CONFIG_DIR (skills/+settings.json PASS)' 0 -- pwsh -NoProfile -File $VALIDATE_PS1
    # (b) config dir is a DIFFERENT existing dir → not recognized → still FAILS
    $coloElse = Join-Path $env:REPO_ROOT ('.test-que285-elsewhere-' + (Get-VtSuffix))
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
$wtName = '.test-que60-fake-worktree-' + (Get-VtSuffix)
$wtPath = Join-Path $claudeDir 'worktrees' $wtName
New-Item -ItemType Directory -Path $wtPath -Force | Out-Null
$VAL_MIXED_EDIT = ".test-que60-mixed-$(Get-VtSuffix)"
Write-LfFile (Join-Path $claudeDir $VAL_MIXED_EDIT) "mixed hand-edit`n"
Assert-Exit 'validate.test: validate.ps1 fails on mixed .claude/ (worktrees + hand-edit)' 1 -- pwsh -NoProfile -File $VALIDATE_PS1
Remove-Item -LiteralPath (Join-Path $claudeDir $VAL_MIXED_EDIT) -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $wtPath -Recurse -Force -ErrorAction SilentlyContinue
Remove-IfEmpty (Join-Path $claudeDir 'worktrees')
Remove-IfEmpty $claudeDir

# --- Test 6: failure message surfaces the leaked path ---
New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
$VAL_DIAG_NAME = ".test-que60-diag-$(Get-VtSuffix)"
Write-LfFile (Join-Path $claudeDir $VAL_DIAG_NAME) "diag content`n"
$val_output = & pwsh -NoProfile -File $VALIDATE_PS1 2>&1
$val_exit = $LASTEXITCODE
if ($val_output -is [array]) { $val_output = $val_output -join "`n" }
Remove-Item -LiteralPath (Join-Path $claudeDir $VAL_DIAG_NAME) -Force -ErrorAction SilentlyContinue
Remove-IfEmpty $claudeDir
Assert-Eq 'validate.test: validate.ps1 exits 1 on diag-name injection' '1' "$val_exit"
Assert-Contains 'validate.test: validate.ps1 failure surfaces leaked path' $val_output $VAL_DIAG_NAME

# --- F-1 amendment: parallel coverage for.codex/ and.agents/ ---
foreach ($ct_base in @('.codex', '.agents')) {
    $ct_dir = Join-Path $env:REPO_ROOT $ct_base
    if (Test-Path -LiteralPath $ct_dir) {
        _Skip "validate.test: validate.ps1 fails on hand-edit in ${ct_base}/" `
            "real ${ct_base}/ present at `$REPO_ROOT — refusing to inject"
        continue
    }
    $CT_INJECT = ".test-que60-${ct_base}-$(Get-VtSuffix)"
    New-Item -ItemType Directory -Path $ct_dir -Force | Out-Null
    Write-LfFile (Join-Path $ct_dir $CT_INJECT) "simulated hand-edit`n"
    Assert-Exit "validate.test: validate.ps1 fails on hand-edit in ${ct_base}/" 1 -- pwsh -NoProfile -File $VALIDATE_PS1
    Remove-Item -LiteralPath (Join-Path $ct_dir $CT_INJECT) -Force -ErrorAction SilentlyContinue
    Remove-IfEmpty $ct_dir
}

# --- other scans must prune harness-managed worktrees ---
# Test 7:.DS_Store inside.claude/worktrees/<name>/ must NOT trip validate.
$wtName = '.test-que61-fake-wt-' + (Get-VtSuffix)
$wtPath = Join-Path $claudeDir 'worktrees' $wtName
New-Item -ItemType Directory -Path $wtPath -Force | Out-Null
Write-LfFile (Join-Path $wtPath '.DS_Store') ''
Assert-Exit 'validate.test: validate.ps1 ignores .DS_Store inside .claude/worktrees/' 0 -- pwsh -NoProfile -File $VALIDATE_PS1
Remove-Item -LiteralPath $wtPath -Recurse -Force -ErrorAction SilentlyContinue
Remove-IfEmpty (Join-Path $claudeDir 'worktrees')
Remove-IfEmpty $claudeDir

# Test 8: secret-shaped fixture inside.claude/worktrees/<name>/ must NOT trip.
$secName = '.test-que61-sec-' + (Get-VtSuffix)
$secPath = Join-Path $claudeDir 'worktrees' $secName
New-Item -ItemType Directory -Path $secPath -Force | Out-Null
$val_que61_prefix = 'sk-'
$val_que61_body = 'fakefake1234567890_abcdefghij_test'
Write-LfFile (Join-Path $secPath 'fixture-secret.txt') ($val_que61_prefix + $val_que61_body + "`n")
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
    $CT_WT_NAME = ".test-que61-fb-wt-${ct_base}-$(Get-VtSuffix)"
    $wtPathLocal = Join-Path $ct_dir 'worktrees' $CT_WT_NAME
    New-Item -ItemType Directory -Path $wtPathLocal -Force | Out-Null
    Write-LfFile (Join-Path $wtPathLocal '.DS_Store') ''
    Assert-Exit "validate.test: validate.ps1 ignores .DS_Store inside ${ct_base}/worktrees/" 0 -- pwsh -NoProfile -File $VALIDATE_PS1
    Remove-Item -LiteralPath $wtPathLocal -Recurse -Force -ErrorAction SilentlyContinue

    $CT_SEC_NAME = ".test-que61-fb-sec-${ct_base}-$(Get-VtSuffix)"
    $secPathLocal = Join-Path $ct_dir 'worktrees' $CT_SEC_NAME
    New-Item -ItemType Directory -Path $secPathLocal -Force | Out-Null
    $val_que61fb_prefix = 'sk-'
    $val_que61fb_body = 'fakefake1234567890_abcdefghij_test'
    Write-LfFile (Join-Path $secPathLocal 'fixture-secret.txt') ($val_que61fb_prefix + $val_que61fb_body + "`n")
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
$VAL_QUE66_FA_PARENT = "tests/fixtures/que66-fa-$suffix"
$VAL_QUE66_FA_DIR = "$VAL_QUE66_FA_PARENT/worktrees"
$secPath = Join-Path $env:REPO_ROOT $VAL_QUE66_FA_DIR
New-Item -ItemType Directory -Path $secPath -Force | Out-Null
$val_que66fa_prefix = 'sk-'
$val_que66fa_body = 'fakefake1234567890_abcdefghij_test'
Write-LfFile (Join-Path $secPath 'secret.txt') ($val_que66fa_prefix + $val_que66fa_body + "`n")
& git -C $env:REPO_ROOT add -f "$VAL_QUE66_FA_DIR/secret.txt" 2>$null | Out-Null
Assert-Exit 'validate.test: validate.ps1 catches secrets in a tracked non-harness worktrees/ dir' 1 -- pwsh -NoProfile -File $VALIDATE_PS1
& git -C $env:REPO_ROOT reset -q -- "$VAL_QUE66_FA_DIR/secret.txt" 2>$null | Out-Null
Remove-Item -LiteralPath (Join-Path $env:REPO_ROOT $VAL_QUE66_FA_PARENT) -Recurse -Force -ErrorAction SilentlyContinue

# --- gitignored runtime-artifact dir cross-model-out/ pruned from the
# secret-pattern scan ---
# Twin of tests/validate.test.sh. cross-model-out/ holds cross-model-
# review per-run output; it is gitignored runtime state that can never enter git,
# so validate.ps1 must not scan it for secrets. Sentinel lands in a representative
# non-log cross-model artifact (codex-review.md) to assert the DIRECTORY is pruned
# for ANY file under it (root-anchored exclusion), not just *.log.
# Secret CONSTRUCTED at runtime per [[feedback_self_tripping_test_source]].
$VAL_QUE244_DIR = "cross-model-out/.test-que244-$(Get-VtSuffix)"
$que244Path = Join-Path $env:REPO_ROOT $VAL_QUE244_DIR
New-Item -ItemType Directory -Path $que244Path -Force | Out-Null
$val_que244_prefix = 'sk-'
$val_que244_body = 'fakefake1234567890_abcdefghij_test'
Write-LfFile (Join-Path $que244Path 'codex-review.md') ($val_que244_prefix + $val_que244_body + "`n")
Assert-Exit 'validate.test: validate.ps1 ignores secret-shaped strings inside cross-model-out/' 0 -- pwsh -NoProfile -File $VALIDATE_PS1
Remove-Item -LiteralPath $que244Path -Recurse -Force -ErrorAction SilentlyContinue
# Remove cross-model-out/ only if empty — preserve any real one the operator owns.
Remove-IfEmpty (Join-Path $env:REPO_ROOT 'cross-model-out')

# anchoring regression guard (adversarial cross-model finding F3): the
# PS exclusion appends a path separator so it is ROOT-ANCHORED. A COMMITTABLE
# sibling whose name merely STARTS with "cross-model-out" (e.g.
# cross-model-out-archive/) is NOT gitignored and MUST still be scanned — a
# bare StartsWith (no separator) would over-match and skip it (a real blind
# spot). Sentinel constructed at runtime.
$VAL_QUE244_SIB = "cross-model-out-.test-que244-sib-$(Get-VtSuffix)"
$que244SibPath = Join-Path $env:REPO_ROOT $VAL_QUE244_SIB
New-Item -ItemType Directory -Path $que244SibPath -Force | Out-Null
$val_que244sib_prefix = 'sk-'
$val_que244sib_body = 'fakefake1234567890_abcdefghij_test'
Write-LfFile (Join-Path $que244SibPath 'secret.txt') ($val_que244sib_prefix + $val_que244sib_body + "`n")
Assert-Exit 'validate.test: validate.ps1 still catches secrets in a cross-model-out* sibling dir' 1 -- pwsh -NoProfile -File $VALIDATE_PS1
Remove-Item -LiteralPath $que244SibPath -Recurse -Force -ErrorAction SilentlyContinue

# --- a TRACKED file whose NAME matches a gitignore rule is still
# scanned.
# git ls-files --cached lists tracked files regardless of.gitignore, so a
# force-added daemon.log /.mcp.json carrying a secret IS in scope; a basename
# --exclude would have skipped them (a false negative). Index reset in cleanup. ---
foreach ($q246name in @("fixture-que246-$(Get-VtSuffix).log", ".test-que246-$(Get-VtSuffix).mcp.json")) {
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
