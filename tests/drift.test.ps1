#Requires -Version 7
# tests/drift.test.ps1 — Windows-native twin of tests/drift.test.sh.
#
# Manifest-drift detection for check-drift.ps1, plus
# scan regression coverage.
#
# Tests INJECT files into $REPO_ROOT and invoke check-drift.ps1, cleaning up
# inline. Mirrors tests/drift.test.sh 1:1 — uses pwsh-built target (via
# install.ps1) instead of bash install.sh.
#
# Note on install.ps1 codex unsupported: tests/drift.test.sh tests both the
# claude build and codex build. install.ps1 currently supports only the claude
# harness; this PS twin uses the claude target for manifest-drift assertions.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$INSTALL_PS1     = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$CHECK_DRIFT_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'check-drift.ps1'

Assert-File 'drift.test: scripts/install.ps1 exists' $INSTALL_PS1
Assert-File 'drift.test: scripts/check-drift.ps1 exists' $CHECK_DRIFT_PS1

function Write-LfFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function New-DriftTarget {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('drift-tgt-' + [Guid]::NewGuid().Guid.Substring(0,8))
    $out = Join-Path $tmp 'target'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $envFile = Join-Path $tmp 'local.env'
    Write-LocalEnvFixture -EnvFile $envFile -ConfigDir $out -VaultDir (Join-Path $tmp 'vault')
    $env:AI_CONFIG_LOCAL_ENV = $envFile
    try {
        & pwsh -NoProfile -File $INSTALL_PS1 --harness claude *>$null
    } finally {
        Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
    }
    return @{ Root = $tmp; Out = $out }
}

# --- Build a clean target ---
$dr = New-DriftTarget

# Clean target: drift check passes.
Assert-Exit 'drift.test: drift check passes on a clean build' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $dr.Out

# Hand-edit a generated skill file: drift check must fail.
# Codex F-2 (MEDIUM): use AppendAllText + UTF8NoBOM for byte-deterministic
# append on Windows (Add-Content may use CRLF on Windows pwsh).
[System.IO.File]::AppendAllText((Join-Path $dr.Out 'skills' 'session-agent' 'SKILL.md'), "`nHAND EDIT`n", [System.Text.UTF8Encoding]::new($false))
Assert-Exit 'drift.test: drift check fails after a generated file is hand-edited' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $dr.Out

Remove-Item -LiteralPath $dr.Root -Recurse -Force -ErrorAction SilentlyContinue

# --- --manifest flags untracked file in generated tree ---
$dr2 = New-DriftTarget

Assert-Exit 'drift.test: drift check passes a clean build (extra-file check)' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $dr2.Out

# untracked file INSIDE manifest-managed skill subdir.
Write-LfFile (Join-Path $dr2.Out 'skills' 'session-agent' 'intruder.md') "rogue`n"
Assert-Exit 'drift.test: drift check fails on an untracked file in a managed skill' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $dr2.Out
Remove-Item -LiteralPath (Join-Path $dr2.Out 'skills' 'session-agent' 'intruder.md') -Force

# untracked subdir under skills/ — Shape C exemption.
New-Item -ItemType Directory -Path (Join-Path $dr2.Out 'skills' 'shape-c-fixture') -Force | Out-Null
Write-LfFile (Join-Path $dr2.Out 'skills' 'shape-c-fixture' 'SKILL.md') "---`nname: shape-c-fixture`ndescription: Shape C drift exemption fixture`n---`n# body`n"
Assert-Exit 'drift.test: drift check passes with an unmanaged Shape C skill subdir' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $dr2.Out
Remove-Item -LiteralPath (Join-Path $dr2.Out 'skills' 'shape-c-fixture') -Recurse -Force

# Untracked file directly under hooks/ must still fail.
Write-LfFile (Join-Path $dr2.Out 'hooks' 'intruder.sh') "#!/bin/bash`n"
Assert-Exit 'drift.test: drift check fails on an untracked hook' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $dr2.Out
Remove-Item -LiteralPath (Join-Path $dr2.Out 'hooks' 'intruder.sh') -Force

# F-2: file directly under skills/ (no subdir) is not Shape C — drift.
Write-LfFile (Join-Path $dr2.Out 'skills' 'rogue.md') "rogue at top`n"
Assert-Exit 'drift.test: drift check fails on a file directly under skills/ (no subdir)' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $dr2.Out
Remove-Item -LiteralPath (Join-Path $dr2.Out 'skills' 'rogue.md') -Force

Remove-Item -LiteralPath $dr2.Root -Recurse -Force -ErrorAction SilentlyContinue

# --- portability scan must not false-positive on regex code ---
Assert-Exit 'drift.test: check-drift.ps1 portability scan passes on the repo' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1

# --- Operator personal-naming denylist is enforced (operator-private) ---
# Guarded on the operator-private fragment's presence, mirroring check-drift.ps1's
# own conditional dot-source: a public-template adopter has no operator handle to
# defend against (the fragment is excluded from the public ship-set), so the check
# is vestigial there and skips. The sentinel handle is constructed at runtime from
# non-matching halves so this test SOURCE carries no operator literal.
$opNaming = Join-Path $env:REPO_ROOT 'scripts/lib/operator-naming-check.ps1'
if (Test-Path -LiteralPath $opNaming) {
    $handle = 'Hen' + 'do'
    $HV_INJECT = Join-Path $env:REPO_ROOT '.test-operator-naming-injection.md'
    Write-LfFile $HV_INJECT "sentinel: $handle Vault appears here`n"
    Assert-Exit "drift.test: check-drift.ps1 fails when the operator handle is reintroduced" 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
    Remove-Item -LiteralPath $HV_INJECT -Force -ErrorAction SilentlyContinue

    # Lowercase form (proves -i / IgnoreCase working).
    $handleLc = 'hen' + 'do'
    $HV_LOWER_INJECT = Join-Path $env:REPO_ROOT '.test-operator-naming-lower-injection.md'
    Write-LfFile $HV_LOWER_INJECT "sentinel: $handleLc-vault/template appears here`n"
    Assert-Exit "drift.test: check-drift.ps1 fails when the lowercase operator handle is reintroduced" 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
    Remove-Item -LiteralPath $HV_LOWER_INJECT -Force -ErrorAction SilentlyContinue
} else {
    _Skip 'drift.test: check-drift.ps1 fails when the operator handle is reintroduced' 'operator-naming-check.ps1 absent (public-template adopter)'
    _Skip 'drift.test: check-drift.ps1 fails when the lowercase operator handle is reintroduced' 'operator-naming-check.ps1 absent (public-template adopter)'
}

# ---.mcp.json excluded ---
$mcpPath = Join-Path $env:REPO_ROOT '.mcp.json'
if (Test-Path -LiteralPath $mcpPath) {
    _Skip 'drift.test: check-drift.ps1 skips .mcp.json' `
        'real .mcp.json present at $REPO_ROOT — refusing to overwrite'
} else {
    $mcp_prefix = '/U'
    $mcp_path_body = 'sers/h'
    $mcp_user_a = 'end'
    $mcp_user_b = 'ohome'
    $mcp_tail = '/.local/bin/sentinel-tool'
    $mcp_full = $mcp_prefix + $mcp_path_body + $mcp_user_a + $mcp_user_b + $mcp_tail
    Write-LfFile $mcpPath ('{ "command": "' + $mcp_full + '" }' + "`n")
    Assert-Exit 'drift.test: check-drift.ps1 skips .mcp.json' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
    Remove-Item -LiteralPath $mcpPath -Force -ErrorAction SilentlyContinue
}

# --- a home path inside harness gitlink does NOT false-trip ---
$DR_T66_FAKE_WT = Join-Path $env:REPO_ROOT '.claude' 'worktrees' (".test-t66-c1-fake-wt-" + [Guid]::NewGuid().Guid.Substring(0,4))
if (Test-Path -LiteralPath $DR_T66_FAKE_WT) {
    _Skip 'drift.test: check-drift.ps1 skips /Users/ inside harness gitlink' `
        'collision with real worktree path — refusing to overwrite'
} else {
    New-Item -ItemType Directory -Path $DR_T66_FAKE_WT -Force | Out-Null
    $c1_prefix = '/U'
    $c1_path_body = 'sers/test-t66-c1/.test-claude-config/repo.git/worktrees/branch'
    $c1_full = $c1_prefix + $c1_path_body
    Write-LfFile (Join-Path $DR_T66_FAKE_WT '.git') ('gitdir: ' + $c1_full + "`n")
    Assert-Exit 'drift.test: check-drift.ps1 skips /Users/ inside harness gitlink' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
    Remove-Item -LiteralPath $DR_T66_FAKE_WT -Recurse -Force -ErrorAction SilentlyContinue
    $worktreesDir = Join-Path $env:REPO_ROOT '.claude' 'worktrees'
    if ((Test-Path -LiteralPath $worktreesDir -PathType Container) -and `
        (@(Get-ChildItem -LiteralPath $worktreesDir -Force -ErrorAction SilentlyContinue).Count -eq 0)) {
        Remove-Item -LiteralPath $worktreesDir -Force
    }
    $claudeDirCleanup = Join-Path $env:REPO_ROOT '.claude'
    if ((Test-Path -LiteralPath $claudeDirCleanup -PathType Container) -and `
        (@(Get-ChildItem -LiteralPath $claudeDirCleanup -Force -ErrorAction SilentlyContinue).Count -eq 0)) {
        Remove-Item -LiteralPath $claudeDirCleanup -Force
    }
}

# --- positive + negative regex coverage ---
function Get-DrSuffix { return ("$PID-" + [Guid]::NewGuid().Guid.Substring(0,4)) }

# Positive: mac home prefix + user + trailing path.
$DR_C1_POS_M = Join-Path $env:REPO_ROOT (".test-t66-c1-mac-pos-" + (Get-DrSuffix) + ".md")
$c1_p = '/Us'; $c1_b = 'ers/test-t66-c1-pos/path'
Write-LfFile $DR_C1_POS_M ($c1_p + $c1_b + "`n")
Assert-Exit 'drift.test: check-drift catches mac home prefix + user + path' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
Remove-Item -LiteralPath $DR_C1_POS_M -Force -ErrorAction SilentlyContinue

# Positive: linux home prefix + user + trailing path.
$DR_C1_POS_L = Join-Path $env:REPO_ROOT (".test-t66-c1-linux-pos-" + (Get-DrSuffix) + ".md")
$c1_p = '/h'; $c1_b = 'ome/test-t66-c1-pos/path'
Write-LfFile $DR_C1_POS_L ($c1_p + $c1_b + "`n")
Assert-Exit 'drift.test: check-drift catches linux home prefix + user + path' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
Remove-Item -LiteralPath $DR_C1_POS_L -Force -ErrorAction SilentlyContinue

# Positive: mac home prefix + user, no trailing slash.
$DR_C1_POS_NS = Join-Path $env:REPO_ROOT (".test-t66-c1-no-trail-" + (Get-DrSuffix) + ".md")
$c1_p = '/Us'; $c1_b = 'ers/test-t66-c1-no-trail'
Write-LfFile $DR_C1_POS_NS ($c1_p + $c1_b + "`n")
Assert-Exit 'drift.test: check-drift catches mac home prefix + user with no trailing slash' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
Remove-Item -LiteralPath $DR_C1_POS_NS -Force -ErrorAction SilentlyContinue

# Positive: Windows drive home prefix.
$DR_C1_POS_W = Join-Path $env:REPO_ROOT (".test-t66-c1-win-pos-" + (Get-DrSuffix) + ".md")
$c1_drive = 'C:'; $c1_p = '\Us'; $c1_b = 'ers\test-t66-c1-pos\path'
Write-LfFile $DR_C1_POS_W ($c1_drive + $c1_p + $c1_b + "`n")
Assert-Exit 'drift.test: check-drift catches Windows drive home prefix + user + path' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
Remove-Item -LiteralPath $DR_C1_POS_W -Force -ErrorAction SilentlyContinue

# Negative: bare home prefix without user segment.
$DR_C1_NEG_M = Join-Path $env:REPO_ROOT (".test-t66-c1-bare-mac-neg-" + (Get-DrSuffix) + ".md")
$c1_p = '/Us'; $c1_b = 'ers/'
Write-LfFile $DR_C1_NEG_M ($c1_p + $c1_b + "`n")
Assert-Exit 'drift.test: check-drift skips bare mac home with no user segment' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
Remove-Item -LiteralPath $DR_C1_NEG_M -Force -ErrorAction SilentlyContinue

# --- portability scan catches concrete paths in tracked plans ---
# docs/ is excluded from the public template ship-set, so docs/plans/ may not
# exist on a fresh template clone — create it so the fixture can be planted.
New-Item -ItemType Directory -Force -Path (Join-Path $env:REPO_ROOT 'docs' 'plans') | Out-Null
$H6_INJECT = Join-Path $env:REPO_ROOT 'docs' 'plans' 'test-t52-h6-leak.md'
$h6_prefix = '/U'; $h6_body = 'sers/test-t52-h6/sentinel'
Write-LfFile $H6_INJECT ($h6_prefix + $h6_body + "`n")
Assert-Exit 'drift.test: check-drift.ps1 catches concrete-home-prefix path in docs/plans/' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
Remove-Item -LiteralPath $H6_INJECT -Force -ErrorAction SilentlyContinue

# --- cross-model-out/ runtime artifacts are pruned ---
$DR_T87_DIR = Join-Path $env:REPO_ROOT 'cross-model-out' (".test-t87-leak-" + (Get-DrSuffix))
if (Test-Path -LiteralPath $DR_T87_DIR) {
    _Skip 'drift.test: check-drift.ps1 prunes cross-model-out/ runtime artifacts' `
        "fixture collision: $DR_T87_DIR exists"
} else {
    New-Item -ItemType Directory -Path $DR_T87_DIR -Force | Out-Null
    $cmr_prefix = '/U'; $cmr_body = 'sers/test-t87/Claude - Local/agentic-os-template'
    $hd_a = 'Hen'; $hd_b = 'do'
    $body = ('workdir: ' + $cmr_prefix + $cmr_body + "`nmodel: gpt-5.5`n`n") +
            ('# Review repo by ' + $hd_a + $hd_b + "`n")
    Write-LfFile (Join-Path $DR_T87_DIR 'codex-review.md') $body
    Assert-Exit 'drift.test: check-drift.ps1 prunes cross-model-out/ runtime artifacts' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
    Remove-Item -LiteralPath $DR_T87_DIR -Recurse -Force -ErrorAction SilentlyContinue
}

# --- the broad content scans enumerate the COMMITTABLE set
# (git ls-files --cached --others --exclude-standard), so GITIGNORED runtime
# artifacts are pruned while tracked + untracked-not-ignored content is still
# scanned. The machine-path sentinel is assembled at runtime from non-matching
# halves so this test source does not self-trip the scan (per
# feedback_self_tripping_test_source). Each fixture asserts its gitignore
# precondition before the behavioral assertion. ---
$q213_prefix = '/U'; $q213_body = 'sers/test-t213/Projects/foo/bar.js'
$q213_home = $q213_prefix + $q213_body

# (a) a gitignored.codegraph/*.log carrying an absolute home path (the field
# case: codegraph's.codegraph/daemon.log) is PRUNED -> exit 0. Unique filename
# remove-if-created so a real codegraph install's state is never touched.
$DR_Q213_IGN_DIR = Join-Path $env:REPO_ROOT '.codegraph'
$DR_Q213_IGN = Join-Path $DR_Q213_IGN_DIR (".test-t213-daemon-" + (Get-DrSuffix) + ".log")
$DR_Q213_MADE_DIR = $false
if (-not (Test-Path -LiteralPath $DR_Q213_IGN_DIR)) {
    New-Item -ItemType Directory -Path $DR_Q213_IGN_DIR -Force | Out-Null
    $DR_Q213_MADE_DIR = $true
}
if (Test-Path -LiteralPath $DR_Q213_IGN) {
    _Skip 'drift.test: check-drift.ps1 prunes gitignored .codegraph runtime log' "fixture collision: $DR_Q213_IGN"
} else {
    Write-LfFile $DR_Q213_IGN ('indexed at ' + $q213_home + "`n")
    & git -C $env:REPO_ROOT check-ignore -q -- $DR_Q213_IGN
    if ($LASTEXITCODE -eq 0) {
        Assert-Exit 'drift.test: check-drift.ps1 prunes gitignored .codegraph runtime log' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
    } else {
        _Fail 'drift.test: check-drift.ps1 prunes gitignored .codegraph runtime log' "precondition failed: fixture not gitignored: $DR_Q213_IGN"
    }
    Remove-Item -LiteralPath $DR_Q213_IGN -Force -ErrorAction SilentlyContinue
}
if ($DR_Q213_MADE_DIR) { Remove-Item -LiteralPath $DR_Q213_IGN_DIR -Force -ErrorAction SilentlyContinue }

# (b) a gitignored *.log anywhere proves it is the.gitignore decision, not a
# hardcoded.codegraph special-case -> exit 0.
$DR_Q213_LOG = Join-Path $env:REPO_ROOT (".test-t213-stray-" + (Get-DrSuffix) + ".log")
if (Test-Path -LiteralPath $DR_Q213_LOG) {
    _Skip 'drift.test: check-drift.ps1 prunes a gitignored *.log file' "fixture collision: $DR_Q213_LOG"
} else {
    Write-LfFile $DR_Q213_LOG ('wrote ' + $q213_home + "`n")
    & git -C $env:REPO_ROOT check-ignore -q -- $DR_Q213_LOG
    if ($LASTEXITCODE -eq 0) {
        Assert-Exit 'drift.test: check-drift.ps1 prunes a gitignored *.log file' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
    } else {
        _Fail 'drift.test: check-drift.ps1 prunes a gitignored *.log file' 'precondition failed: *.log not gitignored'
    }
    Remove-Item -LiteralPath $DR_Q213_LOG -Force -ErrorAction SilentlyContinue
}

# (c) REGRESSION GUARD: an untracked-but-NOT-ignored (committable) file with the
# same machine path is STILL caught -> exit 1. Pins that narrowed the scan
# to gitignored-only; a future "tracked-only" switch would false-PASS here.
$DR_Q213_COMMIT = Join-Path $env:REPO_ROOT (".test-t213-committable-" + (Get-DrSuffix) + ".md")
if (Test-Path -LiteralPath $DR_Q213_COMMIT) {
    _Skip 'drift.test: check-drift.ps1 still catches a committable machine path' "fixture collision: $DR_Q213_COMMIT"
} else {
    Write-LfFile $DR_Q213_COMMIT ('leak at ' + $q213_home + "`n")
    & git -C $env:REPO_ROOT check-ignore -q -- $DR_Q213_COMMIT
    if ($LASTEXITCODE -eq 0) {
        _Skip 'drift.test: check-drift.ps1 still catches a committable machine path' 'unexpected: .md fixture is gitignored'
    } else {
        Assert-Exit 'drift.test: check-drift.ps1 still catches a committable machine path' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
    }
    Remove-Item -LiteralPath $DR_Q213_COMMIT -Force -ErrorAction SilentlyContinue
}

# (d) AC literal + Codex adversarial F4: a TRACKED file with the machine path is
# STILL caught -> exit 1. Staged via `git add -f`, then unstaged + removed
# immediately so no orphan survives. Runs in CI (fresh clone) / isolated worktree.
$DR_Q213_TRACKED = Join-Path $env:REPO_ROOT (".test-t213-tracked-" + (Get-DrSuffix) + ".md")
if (Test-Path -LiteralPath $DR_Q213_TRACKED) {
    _Skip 'drift.test: check-drift.ps1 catches a TRACKED machine path' "fixture collision: $DR_Q213_TRACKED"
} else {
    Write-LfFile $DR_Q213_TRACKED ('leak at ' + $q213_home + "`n")
    & git -C $env:REPO_ROOT add -f -- $DR_Q213_TRACKED 2>&1 | Out-Null
    Assert-Exit 'drift.test: check-drift.ps1 catches a TRACKED machine path' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
    & git -C $env:REPO_ROOT reset -q -- $DR_Q213_TRACKED 2>&1 | Out-Null
    Remove-Item -LiteralPath $DR_Q213_TRACKED -Force -ErrorAction SilentlyContinue
}

# --- content scans FAIL CLOSED on a listed-but-unreadable file -------
# A committable file `git ls-files` enumerates but Test-ScanPath cannot read must
# FAIL, never be silently skipped. Pre-fix the ReadLines try/catch{} swallowed
# the error and failed OPEN. Modeled as a tracked file removed from the worktree:
# still in --cached (LISTED), absent on disk -> ReadLines throws -> the new catch
# fails closed to match the bash twin (grep exit-2). Parity sibling of
# drift.test.sh. Content carries no machine path so the unreadable file is the
# sole failure cause. Index reset in cleanup; runs in CI / isolated worktree.
$DR_Q248 = Join-Path $env:REPO_ROOT (".test-t248-unreadable-" + (Get-DrSuffix) + ".md")
if (Test-Path -LiteralPath $DR_Q248) {
    _Skip 'drift.test: check-drift.ps1 fails closed on an unreadable listed file' "fixture collision: $DR_Q248"
} else {
    Write-LfFile $DR_Q248 "placeholder`n"
    & git -C $env:REPO_ROOT add -f -- $DR_Q248 2>&1 | Out-Null
    Remove-Item -LiteralPath $DR_Q248 -Force -ErrorAction SilentlyContinue
    Assert-Exit 'drift.test: check-drift.ps1 fails closed on an unreadable listed file' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1
    & git -C $env:REPO_ROOT reset -q -- $DR_Q248 2>&1 | Out-Null
}

# --- NON-GIT fallback fails closed on an unreadable DIRECTORY -----------------
# Sibling of the unreadable-FILE test above, for the directory-traversal gap. In
# Test-ScanPath's non-git branch the
# `Get-ChildItem -Recurse -Force -EA SilentlyContinue` walk silently swallows a
# permission-denied DIRECTORY, so its files are never scanned and the scan fails
# OPEN; the bash twin's `grep -r` returns exit 2 -> fails closed. The fix captures
# the enumeration error (-ErrorVariable) and fails closed to match.
#
# check-drift.ps1 has no -RepoRoot override (it derives $repoRoot from
# $PSScriptRoot's parent), so drive the non-git branch by running a COPY of the
# WORKING-TREE script from a non-git fixture's scripts/ dir: $PSScriptRoot/.. is
# then the fixture (no .git) -> Test-ScanPath takes the filesystem-walk fallback.
# No --manifest -> scans-only mode. The fixture stubs the files check-drift.ps1
# requires present BEFORE its first scan (the $requiredCore/$requiredPlaybooks/
# $requiredVerification lists + AGENTS/CLAUDE entrypoints referencing README.md +
# core/) so execution REACHES the machine-path scan, whose Test-ScanPath walk over
# the fixture root hits locked-sub and fails closed first (before operator-naming-
# check.ps1's conditional dot-source, which is absent anyway). If that required
# set grows, this stub list must grow too — the test then fails LOUDLY with
# "missing required ...", not silently. Assert the DISTINCTIVE message; _Skip when
# the unreadable dir can't be made (root / Windows chmod no-op).
function New-NonGitDriftFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('drift-nongit-' + (Get-DrSuffix))
    foreach ($f in @(
        'core/operating-system.md', 'core/self-improvement.md', 'core/memory-model.md',
        'core/verification.md', 'core/tool-use.md',
        'playbooks/harness-entrypoints.md', 'playbooks/data-readiness-map.md', 'playbooks/goal-run.md',
        'verification/process-memory.md', 'verification/data-readiness.md'
    )) { Write-LfFile (Join-Path $root $f) "# stub`n" }
    # Entrypoints must reference README.md AND core/ (machine-path-free).
    Write-LfFile (Join-Path $root 'AGENTS.md')  "# entrypoint`nSee README.md and core/operating-system.md`n"
    Write-LfFile (Join-Path $root 'CLAUDE.md')  "# entrypoint`nSee README.md and core/operating-system.md`n"
    New-Item -ItemType Directory -Path (Join-Path $root 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath $CHECK_DRIFT_PS1 -Destination (Join-Path $root 'scripts' 'check-drift.ps1') -Force
    return $root
}
$DR_NG_ROOT = New-NonGitDriftFixture
$DR_NG_LOCKED = $null
try {
    $DR_NG_LOCKED = Join-Path $DR_NG_ROOT 'locked-sub'
    New-Item -ItemType Directory -Path $DR_NG_LOCKED -Force | Out-Null
    Write-LfFile (Join-Path $DR_NG_LOCKED 'would-be-scanned.md') "placeholder`n"
    if (-not $IsWindows) { & chmod 000 $DR_NG_LOCKED 2>$null }
    $DR_NG_PROBE = $null
    $null = Get-ChildItem -LiteralPath $DR_NG_ROOT -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable DR_NG_PROBE
    if (-not $DR_NG_PROBE -or $DR_NG_PROBE.Count -eq 0) {
        _Skip 'drift.test: check-drift.ps1 non-git scan fails closed on an unreadable directory' 'could not create an unreadable dir (root or Windows chmod no-op)'
    } else {
        $DR_NG_OUT = & pwsh -NoProfile -File (Join-Path $DR_NG_ROOT 'scripts' 'check-drift.ps1') 2>&1
        $DR_NG_CODE = $LASTEXITCODE
        $DR_NG_MSG = ($DR_NG_OUT -join "`n")
        if ($DR_NG_CODE -eq 1 -and $DR_NG_MSG -match 'directory enumeration errored') {
            _Pass 'drift.test: check-drift.ps1 non-git scan fails closed on an unreadable directory'
        } else {
            _Fail 'drift.test: check-drift.ps1 non-git scan fails closed on an unreadable directory' "expected exit 1 + 'directory enumeration errored', got exit $DR_NG_CODE", $DR_NG_MSG
        }
    }
} finally {
    if ($DR_NG_LOCKED -and -not $IsWindows -and (Test-Path -LiteralPath $DR_NG_LOCKED)) { & chmod 755 $DR_NG_LOCKED 2>$null }
    Remove-Item -LiteralPath $DR_NG_ROOT -Recurse -Force -ErrorAction SilentlyContinue
}

# --- parity: unreadable dir UNDER an EXCLUDED dir does NOT fail closed --------
# The bash twin's scan_path passes `--exclude-dir` for .git + every $ExcludeDirs
# name, so it never enters (nor errors on) those dirs; the PS fail-closed must
# prune the same traversal errors or it would fail where bash passes (false
# positive + parity break) — for zero security gain, since those dirs' files are
# excluded from the scan anyway. Place the 000 dir under cross-model-out/ (an
# $ExcludeDirs name for both the machine-path + retired scans) and assert the scan
# PASSES (exit 0, NO enumeration failure), matching bash. _Skip when the
# unreadable dir can't be made.
$DR_NGX_ROOT = New-NonGitDriftFixture
$DR_NGX_LOCKED = $null
try {
    $DR_NGX_LOCKED = Join-Path $DR_NGX_ROOT 'cross-model-out' 'locked'
    New-Item -ItemType Directory -Path $DR_NGX_LOCKED -Force | Out-Null
    Write-LfFile (Join-Path $DR_NGX_LOCKED 'hidden.md') "placeholder`n"
    if (-not $IsWindows) { & chmod 000 $DR_NGX_LOCKED 2>$null }
    $DR_NGX_PROBE = $null
    $null = Get-ChildItem -LiteralPath $DR_NGX_ROOT -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable DR_NGX_PROBE
    if (-not $DR_NGX_PROBE -or $DR_NGX_PROBE.Count -eq 0) {
        _Skip 'drift.test: check-drift.ps1 non-git scan tolerates an unreadable EXCLUDED dir (bash parity)' 'could not create an unreadable dir (root or Windows chmod no-op)'
    } else {
        $DR_NGX_OUT = & pwsh -NoProfile -File (Join-Path $DR_NGX_ROOT 'scripts' 'check-drift.ps1') 2>&1
        $DR_NGX_CODE = $LASTEXITCODE
        $DR_NGX_MSG = ($DR_NGX_OUT -join "`n")
        if ($DR_NGX_CODE -eq 0 -and $DR_NGX_MSG -notmatch 'directory enumeration errored') {
            _Pass 'drift.test: check-drift.ps1 non-git scan tolerates an unreadable EXCLUDED dir (bash parity)'
        } else {
            _Fail 'drift.test: check-drift.ps1 non-git scan tolerates an unreadable EXCLUDED dir (bash parity)' "expected exit 0 (no enumeration failure), got exit $DR_NGX_CODE", $DR_NGX_MSG
        }
    }
} finally {
    if ($DR_NGX_LOCKED -and -not $IsWindows -and (Test-Path -LiteralPath $DR_NGX_LOCKED)) { & chmod 755 $DR_NGX_LOCKED 2>$null }
    Remove-Item -LiteralPath $DR_NGX_ROOT -Recurse -Force -ErrorAction SilentlyContinue
}
