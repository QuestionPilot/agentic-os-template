#Requires -Version 7
# tests/validate-ps.test.ps1 — prototype scope of scripts/validate.ps1.
#
# Verifies the 6+ checks ported from scripts/validate.sh:
# -.DS_Store scan
# - embedded.git scan
# - forbidden-artifacts list (at repo root, harness-config allowlist)
# - secret-pattern scan
# - capability headers
# - lifecycle frontmatter
# - local.env gitignored
# - harness adapter.md presence
#
# Naming: `validate-ps.test.ps1` (not `validate.test.ps1`) to avoid colliding
# with the bash `tests/validate.test.sh` discovery if the test harnesses ever
# share a glob.

# tests/lib.ps1 is dot-sourced by tests/run.ps1 BEFORE each test file.

$VALIDATE_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'validate.ps1'

# --- AC 1: validate.ps1 exists ---------------------------------------------
Assert-File 'validate-ps.test: scripts/validate.ps1 exists' $VALIDATE_PS1

if (-not (Test-Path -LiteralPath $VALIDATE_PS1 -PathType Leaf)) {
    _Skip 'validate-ps.test: clean repo exit 0' 'validate.ps1 missing'
    _Skip 'validate-ps.test: .DS_Store detection' 'validate.ps1 missing'
    _Skip 'validate-ps.test: embedded .git detection' 'validate.ps1 missing'
    _Skip 'validate-ps.test: forbidden artifact at root' 'validate.ps1 missing'
    _Skip 'validate-ps.test: secret pattern detection' 'validate.ps1 missing'
    return
}

# --- AC 2: clean repo exits 0 -----------------------------------------------
# Run validate.ps1 in-place against the worktree. Counters: this is a smoke
# test of the script's clean-repo path. Captures exit AND output so we can
# see what FAILed (the script prints PASS/FAIL diagnostics).
$cleanOut = & pwsh -NoProfile -File $VALIDATE_PS1 2>&1
$cleanExit = $LASTEXITCODE
if ($cleanExit -eq 0) {
    _Pass 'validate-ps.test: clean repo exit 0'
} else {
    _Fail 'validate-ps.test: clean repo exit 0' "exit=$cleanExit", "output:", ($cleanOut -join "`n")
}

# --- Negative-case tests --------------------------------------------------
# Build a tmp fixture repo with just enough structure to satisfy the harness/
# capability checks, then plant individual offenders to verify each detector
# fires. AC 2 already proved the clean path; these prove the FAIL paths.

# Helper — build a minimal valid fixture repo
function New-FixtureRepo {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("que100-validate-fixture-" + [Guid]::NewGuid().Guid.Substring(0,8))
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    # git init (lifecycle scan + local.env-gitignored need a git repo)
    Push-Location $root
    try {
        & git init -q 2>$null
        & git config user.email 'fixture@example.com'
        & git config user.name 'fixture'
        # Minimal.gitignore that ignores local.env
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $root '.gitignore'), "/local.env`n", $utf8NoBom)

        # Minimal capabilities/ — one well-formed spec
        New-Item -ItemType Directory -Path (Join-Path $root 'capabilities') -Force | Out-Null
        $capContent = @"
---
name: testcap
summary: Test capability used by the validate.ps1 fixture.
triggers: [test]
verification: none
harnesses: [claude]
kind: native
lifecycle: experimental
---

# Test capability

A trivial native capability used to satisfy the validator's capability-headers
check during fixture builds.

lifecycle: experimental added so the fixture passes Test-Lifecycle,
unblocking link-check assertions (AC 7-17) that need a fully-clean fixture
to reach the new Test-InternalLinks detector.
"@
        [System.IO.File]::WriteAllText((Join-Path $root 'capabilities' 'testcap.md'), $capContent, $utf8NoBom)

        # Minimal verification/ — none of the fixture caps need a real gate.

        # Minimal harnesses/claude/ with adapter.md + capabilities/testcap.md
        $cdir = Join-Path $root 'harnesses' 'claude'
        New-Item -ItemType Directory -Path (Join-Path $cdir 'capabilities') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $cdir 'hooks') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $cdir 'adapter.md'), "# Claude harness adapter (fixture)`n", $utf8NoBom)
        # harness-capability realization must carry lifecycle: too
        # because Test-Lifecycle's in-scope glob includes harnesses/*/capabilities/*.md.
        $realContent = @"
---
name: testcap
lifecycle: experimental
---

# Realization
"@
        [System.IO.File]::WriteAllText((Join-Path $cdir 'capabilities' 'testcap.md'), $realContent, $utf8NoBom)

        & git add . 2>$null
        & git commit -q -m 'fixture' 2>$null
    } finally {
        Pop-Location
    }
    return $root
}

# --- AC 3:.DS_Store detection ---------------------------------------------
$ds = New-FixtureRepo
try {
    # Plant a.DS_Store
    [System.IO.File]::WriteAllBytes((Join-Path $ds '.DS_Store'), [byte[]](0,0))
    $out  = & pwsh -NoProfile -File $VALIDATE_PS1 -RepoRoot $ds 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 1) {
        _Pass 'validate-ps.test: .DS_Store detection'
    } else {
        _Fail 'validate-ps.test: .DS_Store detection' "expected exit 1, got $code", ($out -join "`n")
    }
} finally {
    Remove-Item -LiteralPath $ds -Recurse -Force -ErrorAction SilentlyContinue
}

# --- AC 4: embedded.git detection ------------------------------------------
$eg = New-FixtureRepo
try {
    # Plant an embedded.git/ dir (not the repo root's.git/).
    $embed = Join-Path $eg 'sub' '.git'
    New-Item -ItemType Directory -Path $embed -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $embed 'HEAD'), 'ref: refs/heads/x', [System.Text.UTF8Encoding]::new($false))
    $out  = & pwsh -NoProfile -File $VALIDATE_PS1 -RepoRoot $eg 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 1) {
        _Pass 'validate-ps.test: embedded .git detection'
    } else {
        _Fail 'validate-ps.test: embedded .git detection' "expected exit 1, got $code", ($out -join "`n")
    }
} finally {
    Remove-Item -LiteralPath $eg -Recurse -Force -ErrorAction SilentlyContinue
}

# --- AC 5: forbidden artifact at root ---------------------------------------
$fa = New-FixtureRepo
try {
    [System.IO.File]::WriteAllText((Join-Path $fa 'settings.json'), '{}', [System.Text.UTF8Encoding]::new($false))
    $out  = & pwsh -NoProfile -File $VALIDATE_PS1 -RepoRoot $fa 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 1) {
        _Pass 'validate-ps.test: forbidden artifact at root'
    } else {
        _Fail 'validate-ps.test: forbidden artifact at root' "expected exit 1, got $code", ($out -join "`n")
    }
} finally {
    Remove-Item -LiteralPath $fa -Recurse -Force -ErrorAction SilentlyContinue
}

# --- AC 6: secret pattern detection -----------------------------------------
# Build the sentinel from non-matching halves so this test's own source
# doesn't self-trip the worktree's secret scan per [[feedback_self_tripping_test_source]].
$sp = New-FixtureRepo
try {
    $sentinel = 'sk' + '-aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkL'
    [System.IO.File]::WriteAllText((Join-Path $sp 'leaked.md'), "value: $sentinel`n", [System.Text.UTF8Encoding]::new($false))
    $out  = & pwsh -NoProfile -File $VALIDATE_PS1 -RepoRoot $sp 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 1) {
        _Pass 'validate-ps.test: secret pattern detection'
    } else {
        _Fail 'validate-ps.test: secret pattern detection' "expected exit 1, got $code", ($out -join "`n")
    }
} finally {
    Remove-Item -LiteralPath $sp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Test-InternalLinks (PS twin of validate.sh check_internal_links)
#
# AC 7-17 cover a representative subset of the bash twin's 29 link-check
# assertions at tests/links.test.sh. Full 29-assertion parity is 's
# responsibility (tests/links.test.ps1 — 29 _Skips + 1 forced-lift anchor;
# the SKIPs lift in a follow-on after this issue + both merge).
#
# Each AC builds a tmp fixture repo via New-FixtureRepo, plants a tracked.md
# with the test pattern, runs validate.ps1 against the fixture, asserts exit
# code (+ output content for diagnostic AC 12).
# ---------------------------------------------------------------------------

# Helper — plant a tracked.md fixture at $RelPath, git-add it.
#
# Fixture lifecycle: each AC builds a New-FixtureRepo under tmp/que100-
# validate-fixture-<8-hex-guid>, runs the assertion, then Remove-Item
# -Recurse. GUID collisions are practically impossible (8-hex × 2^32) but
# cleanup is best-effort — a crash mid-AC leaves a tmp dir which the OS
# tmp reaper handles.
function Add-MdFixture {
    param(
        [Parameter(Mandatory)][string]$FixtureRoot,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][string]$Content
    )
    $abs = Join-Path $FixtureRoot $RelPath
    $dir = Split-Path -Parent $abs
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($abs, $Content, $utf8NoBom)
    Push-Location $FixtureRoot
    try { & git add -f -- $RelPath 2>$null } finally { Pop-Location }
}

# Helper — invoke validate.ps1 against a fixture, capture exit + output.
function Invoke-ValidateFixture {
    param([Parameter(Mandatory)][string]$FixtureRoot)
    $out = & pwsh -NoProfile -File $VALIDATE_PS1 -RepoRoot $FixtureRoot 2>&1
    return @{ Exit = $LASTEXITCODE; Output = ($out -join "`n") }
}

# --- AC 7: link-check baseline — fixture with no markdown links exits 0 -----
$ac7 = New-FixtureRepo
try {
    $r = Invoke-ValidateFixture -FixtureRoot $ac7
    if ($r.Exit -eq 0 -and $r.Output.Contains('PASS internal markdown links resolve')) {
        _Pass 'validate-ps.test: link-check baseline — clean fixture exit 0'
    } else {
        _Fail 'validate-ps.test: link-check baseline — clean fixture exit 0' "exit=$($r.Exit)", $r.Output
    }
} finally { Remove-Item -LiteralPath $ac7 -Recurse -Force -ErrorAction SilentlyContinue }

# --- AC 8: broken local link rejected ---------------------------
$ac8 = New-FixtureRepo
try {
    Add-MdFixture -FixtureRoot $ac8 -RelPath '.test-broken.md' -Content "# fixture`n`n[broken](does-not-exist-QUE124-SENTINEL.md)`n"
    $r = Invoke-ValidateFixture -FixtureRoot $ac8
    if ($r.Exit -eq 1) {
        _Pass 'validate-ps.test: broken internal markdown link rejected'
    } else {
        _Fail 'validate-ps.test: broken internal markdown link rejected' "expected exit 1, got $($r.Exit)", $r.Output
    }
} finally { Remove-Item -LiteralPath $ac8 -Recurse -Force -ErrorAction SilentlyContinue }

# --- AC 9: vendored/ allowlist permits broken link -----
$ac9 = New-FixtureRepo
try {
    Add-MdFixture -FixtureRoot $ac9 -RelPath 'harnesses/claude/vendored/_test-que124/fixture.md' `
        -Content "# vendored`n`n[broken upstream ref](../../docs/never-copied-QUE124-SENTINEL.md)`n"
    $r = Invoke-ValidateFixture -FixtureRoot $ac9
    if ($r.Exit -eq 0) {
        _Pass 'validate-ps.test: vendored/ allowlist permits broken link'
    } else {
        _Fail 'validate-ps.test: vendored/ allowlist permits broken link' "expected exit 0, got $($r.Exit)", $r.Output
    }
} finally { Remove-Item -LiteralPath $ac9 -Recurse -Force -ErrorAction SilentlyContinue }

# --- AC 10: links inside code fences skipped --------------------
# Single-quote here-string @'...'@ so backticks are literal (PS treats backtick
# as escape char inside @"..."@ but NOT inside @'...'@).
$ac10 = New-FixtureRepo
try {
    $content = @'
# fixture

```markdown
[example only](pretend-fenced-missing-QUE124-SENTINEL.md)
```
'@ + "`n"
    Add-MdFixture -FixtureRoot $ac10 -RelPath '.test-fenced.md' -Content $content
    $r = Invoke-ValidateFixture -FixtureRoot $ac10
    if ($r.Exit -eq 0) {
        _Pass 'validate-ps.test: links inside code fences skipped'
    } else {
        _Fail 'validate-ps.test: links inside code fences skipped' "expected exit 0, got $($r.Exit)", $r.Output
    }
} finally { Remove-Item -LiteralPath $ac10 -Recurse -Force -ErrorAction SilentlyContinue }

# --- AC 11: external schemes + pure anchors + abs paths skipped -
# Covers all 7 external-skip forms from bash twin (validate.sh:606):
# http://*, https://*, mailto:*, ftp://*, file://*, //*, /*
# plus pure anchors `#frag`. Confirmation review C-5 caught the prior
# version only covered https/mailto/anchor/abs — now exercises every form.
$ac11 = New-FixtureRepo
try {
    $content = @'
# fixture

- [https](https://example.com/owner/repo)
- [http](http://example.com/plain)
- [ftp](ftp://ftp.example.com/pub)
- [file](file:///etc/hosts)
- [mailto](mailto:nobody@example.com)
- [protocol-relative](//cdn.example.com/asset.js)
- [absolute](/never-existed-but-absolute)
- [anchor only](#section-x)
'@ + "`n"
    Add-MdFixture -FixtureRoot $ac11 -RelPath '.test-external.md' -Content $content
    $r = Invoke-ValidateFixture -FixtureRoot $ac11
    if ($r.Exit -eq 0) {
        _Pass 'validate-ps.test: external schemes + pure anchors + abs paths skipped'
    } else {
        _Fail 'validate-ps.test: external schemes + pure anchors + abs paths skipped' "expected exit 0, got $($r.Exit)", $r.Output
    }
} finally { Remove-Item -LiteralPath $ac11 -Recurse -Force -ErrorAction SilentlyContinue }

# --- AC 12: failure message names file AND broken target --------
$ac12 = New-FixtureRepo
try {
    Add-MdFixture -FixtureRoot $ac12 -RelPath '.test-diag.md' `
        -Content "# fixture`n`n[diag broken](path-DIAG-SENTINEL.md)`n"
    $r = Invoke-ValidateFixture -FixtureRoot $ac12
    if ($r.Exit -eq 1 -and $r.Output.Contains('.test-diag.md') -and $r.Output.Contains('path-DIAG-SENTINEL.md')) {
        _Pass 'validate-ps.test: failure message names file + target'
    } else {
        _Fail 'validate-ps.test: failure message names file + target' "exit=$($r.Exit)", $r.Output
    }
} finally { Remove-Item -LiteralPath $ac12 -Recurse -Force -ErrorAction SilentlyContinue }

# --- AC 13: inline-code spans skip [link](path) ---------------
$ac13 = New-FixtureRepo
try {
    $content = @'
# fixture

Use `[example](pretend-inline-missing-QUE124-SENTINEL.md)` as the canonical syntax in docs.
'@ + "`n"
    Add-MdFixture -FixtureRoot $ac13 -RelPath '.test-inline.md' -Content $content
    $r = Invoke-ValidateFixture -FixtureRoot $ac13
    if ($r.Exit -eq 0) {
        _Pass 'validate-ps.test: links inside inline-code spans skipped'
    } else {
        _Fail 'validate-ps.test: links inside inline-code spans skipped' "expected exit 0, got $($r.Exit)", $r.Output
    }
} finally { Remove-Item -LiteralPath $ac13 -Recurse -Force -ErrorAction SilentlyContinue }

# --- AC 14: ~~~ tilde-fenced blocks recognized ----------------
$ac14 = New-FixtureRepo
try {
    $content = @'
# fixture

~~~markdown
[example only](pretend-tilde-missing-QUE124-SENTINEL.md)
~~~
'@ + "`n"
    Add-MdFixture -FixtureRoot $ac14 -RelPath '.test-tilde.md' -Content $content
    $r = Invoke-ValidateFixture -FixtureRoot $ac14
    if ($r.Exit -eq 0) {
        _Pass 'validate-ps.test: ~~~ fences recognized'
    } else {
        _Fail 'validate-ps.test: ~~~ fences recognized' "expected exit 0, got $($r.Exit)", $r.Output
    }
} finally { Remove-Item -LiteralPath $ac14 -Recurse -Force -ErrorAction SilentlyContinue }

# --- AC 15: nested 3-backticks inside 4-backtick fence --------
$ac15 = New-FixtureRepo
try {
    $content = @'
# fixture

````markdown
Example:

```
[inside nested](pretend-nested-missing-QUE124-SENTINEL.md)
```

End of nested block.
````
'@ + "`n"
    Add-MdFixture -FixtureRoot $ac15 -RelPath '.test-nested.md' -Content $content
    $r = Invoke-ValidateFixture -FixtureRoot $ac15
    if ($r.Exit -eq 0) {
        _Pass 'validate-ps.test: nested 3-backticks inside 4-backtick fence'
    } else {
        _Fail 'validate-ps.test: nested 3-backticks inside 4-backtick fence' "expected exit 0, got $($r.Exit)", $r.Output
    }
} finally { Remove-Item -LiteralPath $ac15 -Recurse -Force -ErrorAction SilentlyContinue }

# --- AC 16: GitHub-platform skip-list (representative prefixes) ----
# Covers ALL 13 prefixes from validate.sh:607-618 (issues/wiki/pulls/pull/
# releases/tree/blob/labels/milestones/commits/commit/discussions) in both
# bare and /sub forms, plus query + anchor suffix variants. Confirmation
# review C-4 caught the prior fixture omitting `releases` — now included.
# Full matrix lift + MT-2 boundary + MT-3 query/anchor + A-2 singular tests
# live's tests/links.test.ps1 (lifted in a separate follow-on).
$ac16 = New-FixtureRepo
try {
    $content = @'
# fixture

- [issue tracker](../../issues)
- [specific issue](../../issues/123)
- [wiki](../../wiki)
- [wiki page](../../wiki/Some-Page)
- [pulls](../../pulls)
- [singular pull](../../pull/45)
- [releases](../../releases)
- [release tag](../../releases/tag/v1.0.0)
- [commit (sha)](../../commit/abcdef1234567890)
- [commits](../../commits/main)
- [discussions](../../discussions)
- [tree](../../tree/main)
- [blob](../../blob/main/README.md)
- [labels](../../labels)
- [milestones](../../milestones/1)
- [bare tree](../../tree)
- [bare blob](../../blob)
- [issues with query](../../issues?q=is:open)
- [discussion anchor](../../discussions/7#discussioncomment-123)
'@ + "`n"
    Add-MdFixture -FixtureRoot $ac16 -RelPath '.test-que105.md' -Content $content
    $r = Invoke-ValidateFixture -FixtureRoot $ac16
    if ($r.Exit -eq 0) {
        _Pass 'validate-ps.test: GitHub-platform skip-list (representative prefixes)'
    } else {
        _Fail 'validate-ps.test: GitHub-platform skip-list (representative prefixes)' "expected exit 0, got $($r.Exit)", $r.Output
    }
} finally { Remove-Item -LiteralPath $ac16 -Recurse -Force -ErrorAction SilentlyContinue }

# --- AC 17: negative regression — near-prefixes STILL fail ---------
# `../../issues-old/...` resembles `../../issues/...` but is NOT in the skip-
# list — must still trip the gate. Guards against an over-broad skip-list
# pattern (e.g. `../../issues*` prefix-match instead of bare + `/`).
$ac17 = New-FixtureRepo
try {
    Add-MdFixture -FixtureRoot $ac17 -RelPath '.test-que105-neg.md' `
        -Content "# fixture`n`n[broken near-prefix](../../issues-old/QUE105-NEAR-SENTINEL.md)`n"
    $r = Invoke-ValidateFixture -FixtureRoot $ac17
    if ($r.Exit -eq 1) {
        _Pass 'validate-ps.test: negative regression — near-prefix still rejected'
    } else {
        _Fail 'validate-ps.test: negative regression — near-prefix still rejected' "expected exit 1, got $($r.Exit)", $r.Output
    }
} finally { Remove-Item -LiteralPath $ac17 -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# secret scan: fail-closed on unreadable files + root-exact README
#
# These inject into the REAL $env:REPO_ROOT worktree (a genuine git repo),
# mirroring the bash twin tests/validate.test.sh, rather than an ephemeral
# New-FixtureRepo. New-FixtureRepo trees live under the OS temp dir, which on
# macOS is the /var -> /private/var symlink: validate.ps1's Resolve-Path-based
# git detection does not canonicalize that symlink (git --show-toplevel does),
# so it misclassifies the fixture as non-git and takes the filesystem-walk
# fallback — which cannot see a deleted-but-listed file and exercises the wrong
# README branch. The real worktree is unsymlinked, so the git-enumeration branch
# (the production path) runs on every platform. (The /var detection divergence
# is pre-existing and shared with the bash twin's pwd -P handling; out of scope
# here.) Index resets in cleanup so no staged orphan survives.
# ---------------------------------------------------------------------------

# cut 1: secret scan FAILS CLOSED on a listed-but-unreadable file. A tracked file
# removed from the worktree stays in --cached (LISTED) but is absent on disk ->
# Select-String -EA Stop throws -> the new read-error flag fails closed. Pre-
# -EA SilentlyContinue silently skipped it (failed OPEN). Non-.md
# extension isolates the failure to the secret scan.
$Q248_DEL = Join-Path $env:REPO_ROOT (".test-que248-unreadable-" + ([Guid]::NewGuid().Guid.Substring(0,8)) + ".txt")
if (Test-Path -LiteralPath $Q248_DEL) {
    _Skip 'validate-ps.test: secret scan fails closed on an unreadable listed file' "fixture collision: $Q248_DEL"
} else {
    [System.IO.File]::WriteAllText($Q248_DEL, "placeholder`n", [System.Text.UTF8Encoding]::new($false))
    & git -C $env:REPO_ROOT add -f -- $Q248_DEL 2>&1 | Out-Null
    Remove-Item -LiteralPath $Q248_DEL -Force -ErrorAction SilentlyContinue
    $out = & pwsh -NoProfile -File $VALIDATE_PS1 -RepoRoot $env:REPO_ROOT 2>&1
    $code = $LASTEXITCODE
    & git -C $env:REPO_ROOT reset -q -- $Q248_DEL 2>&1 | Out-Null
    if ($code -eq 1) {
        _Pass 'validate-ps.test: secret scan fails closed on an unreadable listed file'
    } else {
        _Fail 'validate-ps.test: secret scan fails closed on an unreadable listed file' "expected exit 1, got $code", ($out -join "`n")
    }
}

# cut 2: a nested README.md IS scanned (root-exact, not basename). Pre-fix the
# scan excluded README.md by basename (Split-Path -Leaf / $_.Name), blinding every
# README anywhere. Sentinel built from non-matching halves per
# [[feedback_self_tripping_test_source]] so this source doesn't self-trip. The
# force-added fixture's unstage+remove is wrapped in try/finally so it ALWAYS
# runs — even if validate throws or the run is interrupted — otherwise an
# interrupted run orphans the fixture in the index + on disk.
$Q248_NEST_DIR = Join-Path $env:REPO_ROOT (Join-Path 'tests' (Join-Path 'fixtures' ("que248-nested-" + ([Guid]::NewGuid().Guid.Substring(0,8)))))
$Q248_NEST = Join-Path $Q248_NEST_DIR 'README.md'
try {
    New-Item -ItemType Directory -Path $Q248_NEST_DIR -Force | Out-Null
    $sentinel = 'sk' + '-bCdEfGhIjKlMnOpQrStUvWxYzAbCdEfGhIjKl'
    [System.IO.File]::WriteAllText($Q248_NEST, "value: $sentinel`n", [System.Text.UTF8Encoding]::new($false))
    & git -C $env:REPO_ROOT add -f -- $Q248_NEST 2>&1 | Out-Null
    $out = & pwsh -NoProfile -File $VALIDATE_PS1 -RepoRoot $env:REPO_ROOT 2>&1
    $code = $LASTEXITCODE
} finally {
    & git -C $env:REPO_ROOT reset -q -- $Q248_NEST 2>&1 | Out-Null
    Remove-Item -LiteralPath $Q248_NEST_DIR -Recurse -Force -ErrorAction SilentlyContinue
}
if ($code -eq 1) {
    _Pass 'validate-ps.test: nested README.md is scanned for secrets'
} else {
    _Fail 'validate-ps.test: nested README.md is scanned for secrets' "expected exit 1, got $code", ($out -join "`n")
}

# cut 2: the ROOT README.md remains excepted (documented example key shapes). A
# secret-shaped line appended to the repo-root README must NOT fail the scan.
# The mutate-and-restore is wrapped in try/finally so the `git checkout --`
# restore ALWAYS runs — even if validate throws or the run is interrupted —
# because a leaked sentinel in the tracked README.md would make this test _Skip
# forever (the guard below requires a clean README.md). Guarded on the file being
# clean first so a dirty tree is never clobbered.
& git -C $env:REPO_ROOT diff --quiet -- README.md 2>$null
if ($LASTEXITCODE -eq 0) {
    $sentinel2 = 'sk' + '-cDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkLm'
    try {
        Add-Content -LiteralPath (Join-Path $env:REPO_ROOT 'README.md') -Value "value: $sentinel2"
        $out = & pwsh -NoProfile -File $VALIDATE_PS1 -RepoRoot $env:REPO_ROOT 2>&1
        $code = $LASTEXITCODE
    } finally {
        & git -C $env:REPO_ROOT checkout -- README.md 2>&1 | Out-Null
    }
    if ($code -eq 0) {
        _Pass 'validate-ps.test: ROOT README secret-shaped example is excepted'
    } else {
        _Fail 'validate-ps.test: ROOT README secret-shaped example is excepted' "expected exit 0, got $code", ($out -join "`n")
    }
} else {
    _Skip 'validate-ps.test: ROOT README secret-shaped example is excepted' 'README.md not clean'
}

# cut 1 parity (Codex finding 1): the README exception is case-SENSITIVE — a root
# readme.md / ReadMe.md is NOT the exempt README and MUST be scanned. PS `-eq` and
# OrdinalIgnoreCase were case-insensitive and opened a PS-only leak bypass for case
# variants that the byte-exact bash twin (`["$secret_f" = "README.md" ]`) scans;
# fixed to -ceq (git branch) / Ordinal (non-git branch). Uses an ephemeral fixture
# (no README.md, so the lowercase readme.md is collision-free even on a
# case-insensitive FS); on Linux CI it hits the git branch, on macOS the non-git
# branch. Sentinel from non-matching halves per [[feedback_self_tripping_test_source]].
$q248cs = New-FixtureRepo
try {
    $sentinel = 'sk' + '-dEfGhIjKlMnOpQrStUvWxYzAbCdEfGhIjKlMn'
    Add-MdFixture -FixtureRoot $q248cs -RelPath 'readme.md' -Content "value: $sentinel`n"
    $r = Invoke-ValidateFixture -FixtureRoot $q248cs
    if ($r.Exit -eq 1) {
        _Pass 'validate-ps.test: root readme.md case-variant is scanned, not excepted'
    } else {
        _Fail 'validate-ps.test: root readme.md case-variant is scanned, not excepted' "expected exit 1, got $($r.Exit)", $r.Output
    }
} finally { Remove-Item -LiteralPath $q248cs -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# NON-GIT fallback fails closed on an unreadable DIRECTORY
#
# An earlier fix closed the unreadable-FILE gap (Select-String -EA Stop -> read-
# error flag). Its sibling gap lives in the NON-GIT branch: the
# `Get-ChildItem -Recurse -Force -EA SilentlyContinue` walk SILENTLY swallows a
# permission-denied DIRECTORY, so its files are never enumerated -> a secret
# inside hides and the scan fails OPEN. The bash twin's `grep -r` returns exit 2
# on such a dir -> fails closed; this restores parity by capturing the
# enumeration error (-ErrorVariable) and failing closed. Triggers ONLY on a
# non-git plain-copy staging/export tree (CI/local always take the git ls-files
# branch).
#
# Drive the non-git branch deterministically on EVERY platform by stripping the
# fixture's .git (no .git -> `git --show-toplevel` fails -> filesystem-walk
# branch), then planting a 000 subdir. Assert on the DISTINCTIVE fail message,
# not just the exit code: a non-git fixture can exit 1 for unrelated downstream
# reasons, so the message is what proves the dir-enumeration fail-closed actually
# fired. _Skip when the unreadable dir can't be created (running as root; Windows
# chmod no-op).
# ---------------------------------------------------------------------------
$nongit = New-FixtureRepo
try {
    Remove-Item -LiteralPath (Join-Path $nongit '.git') -Recurse -Force -ErrorAction SilentlyContinue
    $nongitLocked = Join-Path $nongit 'locked-sub'
    New-Item -ItemType Directory -Path $nongitLocked -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $nongitLocked 'would-be-scanned.txt'), "placeholder`n", [System.Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) { & chmod 000 $nongitLocked 2>$null }
    # Probe in THIS process (same user as the child pwsh): does a -Recurse walk
    # actually error on the dir? If not (root / Windows no-op), the gap can't be
    # exercised -> skip.
    $nongitProbeErr = $null
    $null = Get-ChildItem -LiteralPath $nongit -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable nongitProbeErr
    if (-not $nongitProbeErr -or $nongitProbeErr.Count -eq 0) {
        _Skip 'validate-ps.test: non-git secret scan fails closed on an unreadable directory' 'could not create an unreadable dir (root or Windows chmod no-op)'
    } else {
        $r = Invoke-ValidateFixture -FixtureRoot $nongit
        if ($r.Exit -eq 1 -and $r.Output -match 'directory enumeration errored') {
            _Pass 'validate-ps.test: non-git secret scan fails closed on an unreadable directory'
        } else {
            _Fail 'validate-ps.test: non-git secret scan fails closed on an unreadable directory' "expected exit 1 + 'directory enumeration errored', got exit $($r.Exit)", $r.Output
        }
    }
} finally {
    $nongitLocked = Join-Path $nongit 'locked-sub'
    if (-not $IsWindows -and (Test-Path -LiteralPath $nongitLocked)) { & chmod 755 $nongitLocked 2>$null }
    Remove-Item -LiteralPath $nongit -Recurse -Force -ErrorAction SilentlyContinue
}
