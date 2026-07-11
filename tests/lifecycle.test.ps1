#Requires -Version 7
# tests/lifecycle.test.ps1 — Windows-native twin of tests/lifecycle.test.sh.
#
# Lifecycle frontmatter convention enforcement. Mirrors the bash twin
# AC-for-AC by invoking scripts/validate.ps1 instead of validate.sh.
#
# Per [[reference_ps_port_traps]] trap #10 the PS twin uses POSIX-style flags
# where applicable; validate.ps1 has no flags here (zero-arg invocation).
#
# Tests INJECT temp.md files into a hermetic tracked-only git fixture
# ($LC_FIX via New-TrackedGitFixture, <TEAM>-432 — never the live repo index),
# git-track them there so the scanner (which walks `git ls-files '*.md'`)
# sees them, and clean up inline.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$VALIDATE_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'validate.ps1'
Assert-File 'lifecycle.test: scripts/validate.ps1 exists' $VALIDATE_PS1

# Helper: write a file LF-only.
function Write-LfFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# Helper: random suffix for sentinel names.
function Get-LcSuffix {
    return "ps-$PID-" + [Guid]::NewGuid().Guid.Substring(0,4)
}

# --- Test 1: baseline — validate passes on the unmodified repo ---
Assert-Exit 'lifecycle.test: validate.ps1 passes on unmodified repo' 0 -- pwsh -NoProfile -File $VALIDATE_PS1

# --- Test 2: every in-scope tracked.md has a valid lifecycle: value ---
$valid_re = '^lifecycle:\s+(experimental|reviewed|shipped|superseded|sunset)\s*$'
$fail = $false
Push-Location $env:REPO_ROOT
try {
    $tracked = & git ls-files
    foreach ($rel in $tracked) {
        $relNorm = $rel -replace '\\', '/'
        $inScope = ($relNorm -like 'docs/plans/*.md') -or
                   ($relNorm -like 'docs/specs/*.md') -or
                   ($relNorm -match '^docs/[^/]+/plans/.*\.md$') -or
                   ($relNorm -match '^docs/[^/]+/specs/.*\.md$') -or
                   ($relNorm -like 'capabilities/*.md') -or
                   ($relNorm -match '^harnesses/[^/]+/capabilities/.*\.md$')
        if (-not $inScope) { continue }
        $file = Join-Path $env:REPO_ROOT $rel
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($file)
        if ($base -eq 'README') { continue }
        # Extract frontmatter block between first --- and second ---.
        $lines = Get-Content -LiteralPath $file
        if ($lines.Count -eq 0 -or $lines[0] -ne '---') {
            [Console]::Error.WriteLine("  FAIL lifecycle scope: $base — missing/empty frontmatter")
            $fail = $true; continue
        }
        $fmLines = New-Object System.Collections.Generic.List[string]
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -cmatch '^---\s*$') { break }
            [void]$fmLines.Add($lines[$i])
        }
        $fm = $fmLines -join "`n"
        if (-not $fm) {
            [Console]::Error.WriteLine("  FAIL lifecycle scope: $base — missing/empty frontmatter")
            $fail = $true; continue
        }
        $hasValid = $false
        foreach ($l in $fmLines) {
            if ($l -cmatch $valid_re) { $hasValid = $true; break }
        }
        if (-not $hasValid) {
            [Console]::Error.WriteLine("  FAIL lifecycle scope: $base — lifecycle: missing or invalid value")
            $fail = $true
        }
    }
} finally {
    Pop-Location
}
if (-not $fail) {
    _Pass 'lifecycle.test: every in-scope tracked .md has a valid lifecycle: value'
} else {
    _Fail 'lifecycle.test: every in-scope tracked .md has a valid lifecycle: value'
}

# Tests 3-11 plant fixtures under docs/plans/ and need the scanner to see them
# as TRACKED files. They run against a hermetic tracked-only GIT fixture
# (New-TrackedGitFixture, <TEAM>-432) — planting in $env:REPO_ROOT and
# `git add -f`-ing into the LIVE index raced any concurrent `git commit` in the
# same checkout (a real commit captured the transient docs/plans/README.md
# fixture mid-suite). validate.ps1 resolves its repo root from its own script
# location, so the fixture's copy scans the fixture tree with the throwaway
# index. Per-test cleanup (`git rm --cached` + Remove-Item) still runs so each
# assertion sees only its own fixture. The public template excludes docs/ from
# its ship-set, so docs/plans/ may be absent from the fixture too; create it
# once here — validate's lifecycle scope is path-pattern based, enforcing
# docs/plans/*.md even when docs/ is otherwise absent.
# NOTE: use the helper's RETURNED (git-canonicalized) path — see the
# New-TrackedGitFixture doc comment for the macOS /var symlink trap.
$LC_FIX = New-TrackedGitFixture (Join-Path ([System.IO.Path]::GetTempPath()) ("lc-fix-$PID-" + [Guid]::NewGuid().Guid.Substring(0,8)))
$VALIDATE_FIX = Join-Path $LC_FIX 'scripts' 'validate.ps1'
New-Item -ItemType Directory -Force -Path (Join-Path $LC_FIX 'docs' 'plans') | Out-Null

# --- Test 3: validate rejects in-scope file with missing lifecycle: ---
$suf = Get-LcSuffix
$LIFECYCLE_MISSING = "docs/plans/.test-t83-missing-lifecycle-$suf.md"
$missingPath = Join-Path $LC_FIX $LIFECYCLE_MISSING
Write-LfFile $missingPath @'
---
title: test fixture — missing lifecycle key
---

# Test fixture body
'@
Push-Location $LC_FIX
try { & git add -f $LIFECYCLE_MISSING 2>$null } finally { Pop-Location }
Assert-Exit 'lifecycle.test: validate.ps1 fails when in-scope file lacks lifecycle:' 1 -- pwsh -NoProfile -File $VALIDATE_FIX
Push-Location $LC_FIX
try { & git rm -f --cached --quiet $LIFECYCLE_MISSING 2>$null } finally { Pop-Location }
Remove-Item -LiteralPath $missingPath -Force -ErrorAction SilentlyContinue

# --- Test 4: validate rejects in-scope file with invalid lifecycle: value ---
$suf = Get-LcSuffix
$LIFECYCLE_INVALID = "docs/plans/.test-t83-invalid-lifecycle-$suf.md"
$invalidPath = Join-Path $LC_FIX $LIFECYCLE_INVALID
Write-LfFile $invalidPath @'
---
lifecycle: bogus-value
---

# Test fixture body
'@
Push-Location $LC_FIX
try { & git add -f $LIFECYCLE_INVALID 2>$null } finally { Pop-Location }
Assert-Exit 'lifecycle.test: validate.ps1 fails when in-scope file has invalid lifecycle: value' 1 -- pwsh -NoProfile -File $VALIDATE_FIX
Push-Location $LC_FIX
try { & git rm -f --cached --quiet $LIFECYCLE_INVALID 2>$null } finally { Pop-Location }
Remove-Item -LiteralPath $invalidPath -Force -ErrorAction SilentlyContinue

# --- Test 5: validate rejects in-scope file with malformed frontmatter ---
$suf = Get-LcSuffix
$LIFECYCLE_MALFORMED = "docs/plans/.test-t83-malformed-lifecycle-$suf.md"
$malformedPath = Join-Path $LC_FIX $LIFECYCLE_MALFORMED
Write-LfFile $malformedPath @'
---
lifecycle: shipped

# Test fixture body (missing closing ---)
'@
Push-Location $LC_FIX
try { & git add -f $LIFECYCLE_MALFORMED 2>$null } finally { Pop-Location }
Assert-Exit 'lifecycle.test: validate.ps1 fails on malformed (unterminated) frontmatter' 1 -- pwsh -NoProfile -File $VALIDATE_FIX
Push-Location $LC_FIX
try { & git rm -f --cached --quiet $LIFECYCLE_MALFORMED 2>$null } finally { Pop-Location }
Remove-Item -LiteralPath $malformedPath -Force -ErrorAction SilentlyContinue

# --- Test 6: validate accepts all five canonical values ---
$fiveFiles = @()
foreach ($v in @('experimental','reviewed','shipped','superseded','sunset')) {
    $suf = Get-LcSuffix
    $f = "docs/plans/.test-t83-value-$v-$suf.md"
    $fp = Join-Path $LC_FIX $f
    Write-LfFile $fp ("---`nlifecycle: $v`n---`n`n# Test fixture body — value=$v`n")
    Push-Location $LC_FIX
    try { & git add -f $f 2>$null } finally { Pop-Location }
    $fiveFiles += @($f, $fp)
}
& pwsh -NoProfile -File $VALIDATE_FIX *>$null
$five_rc = $LASTEXITCODE
# Cleanup before assertion so a fail leaves no junk.
for ($i = 0; $i -lt $fiveFiles.Count; $i += 2) {
    $rel = $fiveFiles[$i]
    $full = $fiveFiles[$i + 1]
    Push-Location $LC_FIX
    try { & git rm -f --cached --quiet $rel 2>$null } finally { Pop-Location }
    Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
}
if ($five_rc -eq 0) {
    _Pass 'lifecycle.test: validate.ps1 accepts all five canonical lifecycle values'
} else {
    _Fail 'lifecycle.test: validate.ps1 accepts all five canonical lifecycle values' "rc=$five_rc"
}

# --- Test 7: out-of-scope paths NOT enforced ---
$suf = Get-LcSuffix
$LIFECYCLE_OOS = "core/.test-t83-out-of-scope-$suf.md"
$oosPath = Join-Path $LC_FIX $LIFECYCLE_OOS
Write-LfFile $oosPath "# Out-of-scope test fixture — no frontmatter, no lifecycle: key`n"
Push-Location $LC_FIX
try { & git add -f $LIFECYCLE_OOS 2>$null } finally { Pop-Location }
Assert-Exit 'lifecycle.test: validate.ps1 passes on out-of-scope file without lifecycle:' 0 -- pwsh -NoProfile -File $VALIDATE_FIX
Push-Location $LC_FIX
try { & git rm -f --cached --quiet $LIFECYCLE_OOS 2>$null } finally { Pop-Location }
Remove-Item -LiteralPath $oosPath -Force -ErrorAction SilentlyContinue

# --- Test 8: capabilities/README.md is excluded from enforcement ---
$readmePath = Join-Path $env:REPO_ROOT 'capabilities' 'README.md'
if (-not (Test-Path -LiteralPath $readmePath)) {
    _Fail 'lifecycle.test: capabilities/README.md is excluded from check_lifecycle'
} else {
    $readmeContent = Get-Content -LiteralPath $readmePath -Raw
    if ($readmeContent -cmatch '(?m)^lifecycle:') {
        _Fail 'lifecycle.test: capabilities/README.md is excluded from check_lifecycle' `
            'README has lifecycle: line so exclusion check is ambiguous'
    } else {
        _Pass 'lifecycle.test: capabilities/README.md is excluded from check_lifecycle'
    }
}

# --- Test 9: core/lifecycle.md has no @@TOKEN@@ placeholders ---
$lcDoc = Join-Path $env:REPO_ROOT 'core' 'lifecycle.md'
if (-not (Test-Path -LiteralPath $lcDoc)) {
    _Fail 'lifecycle.test: core/lifecycle.md contains no install.sh @@TOKEN@@ placeholders' `
        'impl missing'
} else {
    $lcDocContent = Get-Content -LiteralPath $lcDoc -Raw
    if ($lcDocContent -cmatch '@@[A-Z][A-Z0-9_]*@@') {
        _Fail 'lifecycle.test: core/lifecycle.md contains no install.sh @@TOKEN@@ placeholders'
    } else {
        _Pass 'lifecycle.test: core/lifecycle.md contains no install.sh @@TOKEN@@ placeholders'
    }
}

# --- Test 10: duplicate-key coverage ---
$suf = Get-LcSuffix
$LIFECYCLE_DUPLICATE = "docs/plans/.test-t83-duplicate-lifecycle-$suf.md"
$dupPath = Join-Path $LC_FIX $LIFECYCLE_DUPLICATE
Write-LfFile $dupPath @'
---
lifecycle: bogus-value
lifecycle: shipped
---

# Test fixture body
'@
Push-Location $LC_FIX
try { & git add -f $LIFECYCLE_DUPLICATE 2>$null } finally { Pop-Location }
Assert-Exit 'lifecycle.test: validate.ps1 accepts file with a valid lifecycle: line even if a sibling line is bogus' 0 -- pwsh -NoProfile -File $VALIDATE_FIX
Push-Location $LC_FIX
try { & git rm -f --cached --quiet $LIFECYCLE_DUPLICATE 2>$null } finally { Pop-Location }
Remove-Item -LiteralPath $dupPath -Force -ErrorAction SilentlyContinue

# --- Test 11: hypothetical directory README.md is excluded ---
$LIFECYCLE_README_TGT = "docs/plans/README.md"
$readmeTgtPath = Join-Path $LC_FIX $LIFECYCLE_README_TGT
if (Test-Path -LiteralPath $readmeTgtPath) {
    _Pass 'lifecycle.test: docs/plans/README.md exclusion test SKIPPED — pre-existing README'
} else {
    Write-LfFile $readmeTgtPath "# Test fixture — directory README, no lifecycle: key`n"
    Push-Location $LC_FIX
    try { & git add -f $LIFECYCLE_README_TGT 2>$null } finally { Pop-Location }
    Assert-Exit 'lifecycle.test: validate.ps1 skips docs/plans/README.md from check_lifecycle' 0 -- pwsh -NoProfile -File $VALIDATE_FIX
    Push-Location $LC_FIX
    try { & git rm -f --cached --quiet $LIFECYCLE_README_TGT 2>$null } finally { Pop-Location }
    Remove-Item -LiteralPath $readmeTgtPath -Force -ErrorAction SilentlyContinue
}

# Hermetic fixture teardown (<TEAM>-432): the throwaway clone (and its index)
# is the only thing the injection tests touched — remove it.
Remove-Item -Recurse -Force -LiteralPath $LC_FIX -ErrorAction SilentlyContinue
