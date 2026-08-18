#Requires -Version 7
# tests/lib.ps1 — assertion helpers for the Windows-native acceptance suite.
# Dot-sourced by tests/run.ps1 and each tests/*.test.ps1 file. Mirrors the
# semantics of tests/lib.sh.
#
# Each Assert-* prints PASS/FAIL and increments the script-scoped counters
# $script:TESTS_RUN / $script:TESTS_FAILED so tests/run.ps1 can emit a summary.
#
# The PS counter-pattern matches the bash one — counters live in the runner's
# scope, helpers update them from there. PowerShell's `$script:` scope refers
# to the file that called `. lib.ps1`, so when run.ps1 dot-sources lib.ps1
# AND each.test.ps1 file, all three share counters.

$script:TESTS_RUN    = 0
$script:TESTS_FAILED = 0

# ---------------------------------------------------------------------------
# Internal helpers (mirror bash _pass / _fail / _skip)
# ---------------------------------------------------------------------------

function _Pass {
    param([string]$Label)
    $script:TESTS_RUN++
    Write-Host "  PASS $Label"
}

function _Fail {
    param(
        [string]   $Label,
        [string[]] $ExtraLines = @()
    )
    $script:TESTS_RUN++
    $script:TESTS_FAILED++
    [Console]::Error.WriteLine("  FAIL $Label")
    foreach ($line in $ExtraLines) {
        [Console]::Error.WriteLine("       $line")
    }
}

function _Skip {
    param(
        [string]$Label,
        [string]$Reason = 'not applicable'
    )
    $script:TESTS_RUN++
    Write-Host "  SKIP $Label ($Reason)"
}

# ---------------------------------------------------------------------------
# Assert-Eq <label> <expected> <actual>
#
# Case-sensitive string comparison (-ceq). Bash `[["$a" == "$b" ]]` is
# byte-comparison; -ceq matches that.
# ---------------------------------------------------------------------------

function Assert-Eq {
    param(
        [string]$Label,
        [string]$Expected,
        [string]$Actual
    )
    if ($Expected -ceq $Actual) {
        _Pass $Label
    } else {
        _Fail $Label "expected: [$Expected]", "actual:   [$Actual]"
    }
}

# ---------------------------------------------------------------------------
# Assert-Exit <label> <expected-code> -- <command...>
#
# Runs <command...> with stdout+stderr suppressed, captures exit code.
# The `--` separator mirrors bash's shift-3 convention. PS consumes `--`
# end-of-parameters marker before the function sees it, so the command
# tokens arrive in $Rest via ValueFromRemainingArguments. A leading '--'
# element is stripped if present, making the call form
# `Assert-Exit <label> <want> -- cmd arg arg` work identically.
# ---------------------------------------------------------------------------

function Assert-Exit {
    param(
        [Parameter(Position = 0)] [string]   $Label,
        [Parameter(Position = 1)] [int]      $Want,
        [Parameter(ValueFromRemainingArguments)] [string[]] $Rest
    )
    if ($Rest.Count -gt 0 -and $Rest[0] -eq '--') {
        $cmd = $Rest[1..($Rest.Count - 1)]
    } else {
        $cmd = $Rest
    }
    # Run via &, redirect stdout+stderr to $null, capture LASTEXITCODE.
    & $cmd[0] @($cmd[1..($cmd.Count - 1)]) *>$null
    $got = $LASTEXITCODE
    if ($got -eq $Want) {
        _Pass $Label
    } else {
        _Fail $Label "expected exit $Want, got $got"
    }
}

# ---------------------------------------------------------------------------
# Assert-Contains <label> <haystack> <needle>
# ---------------------------------------------------------------------------

function Assert-Contains {
    param(
        [string]$Label,
        [string]$Haystack,
        [string]$Needle
    )
    if ($Haystack.Contains($Needle)) {
        _Pass $Label
    } else {
        _Fail $Label "string does not contain: [$Needle]"
    }
}

# ---------------------------------------------------------------------------
# Assert-NotContains <label> <haystack> <needle>
# ---------------------------------------------------------------------------

function Assert-NotContains {
    param(
        [string]$Label,
        [string]$Haystack,
        [string]$Needle
    )
    if ($Haystack.Contains($Needle)) {
        _Fail $Label "string unexpectedly contains: [$Needle]"
    } else {
        _Pass $Label
    }
}

# ---------------------------------------------------------------------------
# Assert-File <label> <path>
# ---------------------------------------------------------------------------

function Assert-File {
    param(
        [string]$Label,
        [string]$Path
    )
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        _Pass $Label
    } else {
        _Fail $Label "file not found: $Path"
    }
}

# ---------------------------------------------------------------------------
# Fixture helpers (mirror bash make_local_env / make_codex_env / make_stub_cli)
# ---------------------------------------------------------------------------

# Write-LocalEnvFixture <env-file> <config-dir> [vault-dir]
#
# Writes a minimal but complete local.env for `install.ps1 --harness claude`
# test builds. install.ps1 (and install.sh) source local.env and reference
# OBSIDIAN_VAULT_PATH inside the entrypoint template — a build fixture must
# supply that var or the build fails on the empty-placeholder gate.
#
# Mirrors `make_local_env` in tests/lib.sh.
#
# uses [System.IO.File]::WriteAllText with explicit "`n" and a
# no-BOM UTF-8 encoding instead of Set-Content. Set-Content's default
# encoding includes CRLF line endings AND (on Windows PowerShell 5.x) a
# UTF-8 BOM, both of which break parity with the bash path that reads/writes
# this file. See [[feedback_powershell_set_content_crlf]].
function Write-LocalEnvFixture {
    param(
        [Parameter(Mandatory)][string]$EnvFile,
        [Parameter(Mandatory)][string]$ConfigDir,
        [string]$VaultDir = '/tmp/test-vault'
    )
    $lines = @(
        "CLAUDE_CONFIG_DIR=`"$ConfigDir`"",
        "OBSIDIAN_VAULT_PATH=`"$VaultDir`""
    )
    $content = ($lines -join "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($EnvFile, $content, $utf8NoBom)
}

# Copy-RepoTracked <dest>
# Hermetic repo fixture (<TEAM>-394) — PS twin of tests/lib.sh
# copy_repo_tracked: copy only git-TRACKED files (their working-tree versions)
# into <dest>. A recursive whole-dir copy drags every gitignored artifact
# around a living checkout into the fixture (co-located harness homes, the
# operator's projects/ workspace, local.env), making fixture behavior depend
# on operator machine state. Tracked files are exactly what a clean clone
# contains (minus .git). Fails loudly if git enumeration fails.
function Copy-RepoTracked {
    param([Parameter(Mandatory)][string]$Dest)
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    $files = @(& git -C $env:REPO_ROOT ls-files)
    if ($LASTEXITCODE -ne 0) { throw "Copy-RepoTracked: git ls-files failed in $env:REPO_ROOT" }
    foreach ($f in $files) {
        $src = Join-Path $env:REPO_ROOT $f
        $dst = Join-Path $Dest $f
        $dir = Split-Path -Parent $dst
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
}

# New-TrackedGitFixture <dest> -> canonical fixture root (string)
# Hermetic GIT fixture (<TEAM>-432) — PS twin of tests/lib.sh
# make_tracked_git_fixture: Copy-RepoTracked + a throwaway `git init` +
# `git add -f -A`, so the fixture carries its OWN index tracking exactly the
# copied set — the same committable enumeration a clean CI clone sees. Tests
# that pin index-dependent behavior used to `git add -f` into the LIVE repo
# index and unstage afterwards; any concurrent `git commit` in the same
# checkout raced those transients. validate.ps1 + check-drift.ps1 resolve
# their repo root from their own script location, so running the FIXTURE's
# copy scans the fixture tree with the fixture index — zero writes to the
# operator's checkout. No commit is made (nothing needs HEAD), so no git
# identity is required. init.defaultBranch is pinned to keep git's
# unset-branch-name hint off stderr regardless of machine config.
#
# RETURNS the git-CANONICALIZED fixture root (`rev-parse --show-toplevel`),
# and callers must use the returned path, not $Dest. On macOS the OS temp dir
# sits behind the /var -> /private/var symlink; the scripts' Resolve-Path-based
# git detection does not canonicalize that symlink while git does, so a script
# invoked via the symlinked path misclassifies the fixture as non-git and
# falls back to the filesystem walk — silently exercising the wrong branch
# (the trap validate-ps.test.ps1 documented when it avoided temp fixtures).
# Invoking through git's own canonical path keeps the git-enumeration branch
# (the production path) live on every platform.
function New-TrackedGitFixture {
    param([Parameter(Mandatory)][string]$Dest)
    Copy-RepoTracked $Dest
    & git -C $Dest -c init.defaultBranch=main init -q
    if ($LASTEXITCODE -ne 0) { throw "New-TrackedGitFixture: git init failed in $Dest" }
    & git -C $Dest add -f -A
    if ($LASTEXITCODE -ne 0) { throw "New-TrackedGitFixture: git add failed in $Dest" }
    $canon = (& git -C $Dest rev-parse --show-toplevel 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or -not $canon) { throw "New-TrackedGitFixture: rev-parse --show-toplevel failed in $Dest" }
    return $canon
}

# Write-CodexEnvFixture <env-file> <codex-home> [vault-dir]
#
# Mirrors `make_codex_env` in tests/lib.sh. (Not exercised by the
# prototype — claude is the picked harness — but ported for parity so the
# Issue 5B full port doesn't need to revisit the test lib.)
function Write-CodexEnvFixture {
    param(
        [Parameter(Mandatory)][string]$EnvFile,
        [Parameter(Mandatory)][string]$CodexHome,
        [string]$VaultDir = '/tmp/test-vault'
    )
    $lines = @(
        "CODEX_HOME=`"$CodexHome`"",
        "OBSIDIAN_VAULT_PATH=`"$VaultDir`""
    )
    $content = ($lines -join "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($EnvFile, $content, $utf8NoBom)
}

# Write-HermesEnvFixture <env-file> <hermes-home> [vault-dir]
#
# Mirrors `make_hermes_env` in tests/lib.sh. install.ps1 resolves the hermes build
# target from HERMES_HOME; the generated SOUL.md references OBSIDIAN_VAULT_PATH, so
# a fixture must supply it or the build fails on the empty-placeholder gate.
function Write-HermesEnvFixture {
    param(
        [Parameter(Mandatory)][string]$EnvFile,
        [Parameter(Mandatory)][string]$HermesHome,
        [string]$VaultDir = '/tmp/test-vault'
    )
    $lines = @(
        "HERMES_HOME=`"$HermesHome`"",
        "OBSIDIAN_VAULT_PATH=`"$VaultDir`""
    )
    $content = ($lines -join "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($EnvFile, $content, $utf8NoBom)
}

# Write-CursorEnvFixture <env-file> <cursor-config-dir> [vault-dir]
#
# Mirrors `make_cursor_env` in tests/lib.sh. install.ps1 resolves the cursor
# build target from CURSOR_CONFIG_DIR; the generated AGENTS.md references
# OBSIDIAN_VAULT_PATH, so a fixture must supply it or the build fails on the
# empty-placeholder gate.
function Write-CursorEnvFixture {
    param(
        [Parameter(Mandatory)][string]$EnvFile,
        [Parameter(Mandatory)][string]$CursorConfigDir,
        [string]$VaultDir = '/tmp/test-vault'
    )
    $lines = @(
        "CURSOR_CONFIG_DIR=`"$CursorConfigDir`"",
        "OBSIDIAN_VAULT_PATH=`"$VaultDir`""
    )
    $content = ($lines -join "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($EnvFile, $content, $utf8NoBom)
}

# ---------------------------------------------------------------------------
# Test tiering — mirrors tests/lib.sh _test_tier_of / _tier_should_run.
#
# A test file opts into the SLOW tier with a marker comment line:
# # test-tier: slow
# Unmarked files are FAST. The runner consults $env:TEST_TIER (default 'full'):
# 'fast' runs only fast-tier files; any other value runs everything. The marker
# is anchored to ^# and matched case-sensitively so it stays byte-parity with
# the bash `grep -E` path and a reference to the marker inside a test body does
# not misclassify that file. See tests/TIERS.md.
#
# Whitespace is an explicit ASCII class `[\t\f\v\r]` rather than `\s` —.NET
# `\s` also matches Unicode whitespace (NBSP, etc.), which POSIX `[[:space:]]`
# (the bash side) does not; the explicit class keeps the two detectors
# byte-identical. \r is included so a CRLF-authored marker line still matches.
# ---------------------------------------------------------------------------

$script:TierMarkerRe = '^#[ \t\f\v\r]*test-tier:[ \t\f\v\r]*slow[ \t\f\v\r]*$'

# Get-TestTier <path> — 'slow' if <path> carries the slow marker, else 'fast'.
function Get-TestTier {
    param([Parameter(Mandatory)][string]$Path)
    if (Select-String -LiteralPath $Path -Pattern $script:TierMarkerRe -CaseSensitive -Quiet -ErrorAction SilentlyContinue) {
        'slow'
    } else {
        'fast'
    }
}

# Test-TierShouldRun <path> — $true if <path> runs under the current $env:TEST_TIER.
function Test-TierShouldRun {
    param([Parameter(Mandatory)][string]$Path)
    $tier = $env:TEST_TIER
    if (-not $tier) { $tier = 'full' }
    if ($tier -eq 'fast') {
        return (Get-TestTier -Path $Path) -eq 'fast'
    }
    return $true
}
