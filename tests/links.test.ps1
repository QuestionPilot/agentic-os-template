#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tiering: scan-heavy — twin of the slow-marked.sh. Skipped by the
# fast tier ($env:TEST_TIER='fast').
# test-tier: slow
# tests/links.test.ps1 — Windows-native twin of tests/links.test.sh.
#
# Internal markdown link integrity.
#
# lifted the 26 deferred _Skip placeholders to live assertions mirroring
# the bash twin 1:1 (real-worktree-injection pattern). The remaining 4 _Skips
# are the GNU-awk / mawk / locale-blank tests, which are MOOT in the
# PowerShell port —.NET regex has no engine-variant divergence (gawk vs BSD
# awk vs mawk) and no locale-dependent gsub behavior. The four assertions stay
# SKIP-with-rationale to preserve the bash-twin AC count + carry the moot
# rationale for future maintainers.
#
# Per [[runtime_cross_model_review_artifacts]] dual-pass C-1: PS string
# operators are case-INsensitive by default; bash POSIX `case` is case-
# sensitive. The PS port uses `-cmatch` / `-ceq` / `[StringComparison]::Ordinal`
# so `[x](HTTPS://example.com)` falls through to local resolution exactly as
# bash treats it (broken link → FAIL). Some `links.test.sh` assertions use
# upper-case content; the PS twin mirrors bash treatment.
#
# Hermetic-fixture-injection pattern (same as bash twin, <TEAM>-432):
# plant a temp.md inside a hermetic tracked-only git fixture ($LK_FIX via
# New-TrackedGitFixture — never the live repo index) → git-add there → run the
# FIXTURE's validate.ps1 (it resolves repo root from its own script location) →
# assert exit code / output → git-rm + delete the temp file. Injecting into
# $env:REPO_ROOT and force-adding into the LIVE index raced any concurrent
# `git commit` in the same checkout. No inline-trap cleanup (per the bash-twin
# pattern); cleanups inline immediately after each assertion to minimize
# orphan-fixture risk per [[feedback_orphan_staged_fixtures]].
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$VALIDATE_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'validate.ps1'
Assert-File 'links.test: scripts/validate.ps1 exists' $VALIDATE_PS1

# Anchor: confirm validate.ps1 implements Test-InternalLinks. Original
# anchor was a forced-lift signal that fired when the function landed;
# lifted the SKIPs as part of the same merge, so the anchor flips role to a
# regression sentinel — if Test-InternalLinks ever disappears, the anchor
# fails first with a clearly-named assertion.
$validatePs1 = Get-Content -LiteralPath $VALIDATE_PS1 -Raw
if ($validatePs1 -match 'function Test-InternalLinks') {
    _Pass 'links.test: anchor — validate.ps1 implements Test-InternalLinks'
} else {
    _Fail 'links.test: anchor — validate.ps1 implements Test-InternalLinks' `
        'Test-InternalLinks missing from validate.ps1; restore the function or revert the lifted assertions in this file'
}

# ---------------------------------------------------------------------------
# Helpers — fixture inject / assert / cleanup (real-worktree pattern mirror
# of tests/links.test.sh).
# ---------------------------------------------------------------------------

# Make a per-test sentinel name; embed PID + 8-hex GUID so concurrent test
# runs do not collide (bash twin uses `$$-${RANDOM:-x}`).
function _LinkSentinel {
    param([Parameter(Mandatory)][string]$Slug)
    "${Slug}-$PID-$([guid]::NewGuid().Guid.Substring(0,8))"
}

# Inject $Content at $RelPath inside the $LK_FIX fixture, git-add THERE, run
# the fixture's validate.ps1, Assert-Exit, then git-rm + delete the file.
# Mirrors the bash twin's Test 2+ pattern (<TEAM>-432 hermetic fixture).
function _LinkFixture {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][int]   $Want,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][string]$Content
    )
    $abs = Join-Path $LK_FIX $RelPath
    $dir = Split-Path -Parent $abs
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($abs, $Content, $utf8)
    Push-Location $LK_FIX
    try {
        & git add -f -- $RelPath 2>$null
        Assert-Exit $Label $Want -- pwsh -NoProfile -File $VALIDATE_FIX
    } finally {
        & git rm -f --quiet -- $RelPath 2>$null
        Pop-Location
    }
    Remove-Item -LiteralPath $abs -Force -ErrorAction SilentlyContinue
}

# Two-assertion diagnostic: capture stdout once, assert both file path and
# target path appear in the FAIL message. Mirrors bash twin Test 6 + 7.
function _LinkDiag {
    param(
        [Parameter(Mandatory)][string]$LabelFile,
        [Parameter(Mandatory)][string]$LabelTarget,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$ExpectedTarget
    )
    $abs = Join-Path $LK_FIX $RelPath
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($abs, $Content, $utf8)
    Push-Location $LK_FIX
    try {
        & git add -f -- $RelPath 2>$null
        $out  = & pwsh -NoProfile -File $VALIDATE_FIX 2>&1
        $full = ($out -join "`n")
        Assert-Contains $LabelFile   $full $RelPath
        Assert-Contains $LabelTarget $full $ExpectedTarget
    } finally {
        & git rm -f --quiet -- $RelPath 2>$null
        Pop-Location
    }
    Remove-Item -LiteralPath $abs -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Tests 1-17 — baseline + core fence parser + inline-code + amendments
# ---------------------------------------------------------------------------

# --- Test 1: validate.ps1 passes on unmodified repo ----
# Deliberately runs against the LIVE repo — this is the one assertion whose
# subject is the operator's actual tree, and it is read-only.
Assert-Exit 'links.test: validate.ps1 passes on unmodified repo' 0 -- `
    pwsh -NoProfile -File $VALIDATE_PS1

# Hermetic injection fixture for every test below (<TEAM>-432). Use the
# helper's RETURNED (git-canonicalized) path — see the New-TrackedGitFixture
# doc comment for the macOS /var symlink trap.
$LK_FIX = New-TrackedGitFixture (Join-Path ([System.IO.Path]::GetTempPath()) ("lk-fix-$PID-" + [Guid]::NewGuid().Guid.Substring(0,8)))
$VALIDATE_FIX = Join-Path $LK_FIX 'scripts' 'validate.ps1'

# --- Test 2: broken internal link rejected ---------------------------------
$rel = (_LinkSentinel 't53-links-broken') + '.md'
_LinkFixture 'links.test: validate.ps1 fails on broken internal markdown link' 1 `
    ".test-$rel" (@'
# Test fixture
This points to a [missing file](does-not-exist-anywhere.md) on purpose.
'@ + "`n")

# --- Test 3: broken link inside vendored/ permitted ------------------------
$vendDir = 'harnesses/claude/vendored/_test-' + (_LinkSentinel 't53')
_LinkFixture 'links.test: validate.ps1 allows broken links inside vendored/' 0 `
    "$vendDir/fixture.md" (@'
# Vendored fixture
[Broken upstream ref](../../docs/never-copied.md) — allowlisted.
'@ + "`n")
# Cleanup the synthetic vendored dir (the.md was removed by _LinkFixture).
Remove-Item -LiteralPath (Join-Path $LK_FIX $vendDir) -Recurse -Force -ErrorAction SilentlyContinue

# --- Test 4: links inside code fences skipped ------------------------------
_LinkFixture 'links.test: validate.ps1 ignores links inside code fences' 0 `
    (".test-" + (_LinkSentinel 't53-links-fenced') + '.md') (@'
# Test fixture
Here is a code example:

```markdown
[example only](pretend-missing.md)
```

End of file.
'@ + "`n")

# --- Test 5: external schemes + pure anchors skipped -----------------------
_LinkFixture 'links.test: validate.ps1 ignores external schemes + pure anchors' 0 `
    (".test-" + (_LinkSentinel 't53-links-external') + '.md') (@'
# Test fixture
- [Example](https://example.com/owner/repo)
- [Email](mailto:nobody@example.com)
- [Anchor](#section-x)
'@ + "`n")

# --- Tests 6 + 7: failure message names the file AND the broken target -----
$diagRel = ".test-" + (_LinkSentinel 't53-links-diag') + '.md'
_LinkDiag `
    'links.test: validate.ps1 failure message names the file' `
    'links.test: validate.ps1 failure message names the broken target' `
    $diagRel (@'
# Test fixture
[diagnostic broken](path-DIAG-SENTINEL.md)
'@ + "`n") `
    'path-DIAG-SENTINEL.md'

# --- Test 8: inline-code spans containing [link](path) skipped -
_LinkFixture 'links.test: validate.ps1 skips links inside inline-code spans' 0 `
    (".test-" + (_LinkSentinel 't63-links-inline-code') + '.md') (@'
# Test fixture

Use `[example](pretend-inline-missing.md)` as the canonical syntax in docs.
'@ + "`n")

# --- Test 9: tilde-fenced code blocks recognized --------------
_LinkFixture 'links.test: validate.ps1 recognizes ~~~ fences' 0 `
    (".test-" + (_LinkSentinel 't63-links-tilde-fence') + '.md') (@'
# Test fixture

~~~markdown
[example only](pretend-tilde-missing.md)
~~~
'@ + "`n")

# --- Test 10: fences indented 1-3 spaces recognized -----------
_LinkFixture 'links.test: validate.ps1 recognizes fences indented 1-3 spaces' 0 `
    (".test-" + (_LinkSentinel 't63-links-indented-fence') + '.md') (@'
# Test fixture

   ```markdown
   [example only](pretend-indented-missing.md)
   ```
'@ + "`n")

# --- Test 11: nested 3-backticks inside 4-backtick fence ------
_LinkFixture 'links.test: validate.ps1 handles nested triple-backticks inside 4-backtick fence' 0 `
    (".test-" + (_LinkSentinel 't63-links-nested-fence') + '.md') (@'
# Test fixture

````markdown
Example:

```
[inside nested](pretend-nested-missing.md)
```

End of nested block.
````
'@ + "`n")

# --- Test 12: reference-style links not checked --------
_LinkFixture 'links.test: validate.ps1 does not check reference-style links' 0 `
    (".test-" + (_LinkSentinel 't63-links-ref-style') + '.md') (@'
# Test fixture

See [the example][ex] for details.

[ex]: pretend-ref-missing.md
'@ + "`n")

# --- Test 13: escaped parens treated as broken ---------
_LinkFixture 'links.test: validate.ps1 treats escaped-paren destinations as broken' 1 `
    (".test-" + (_LinkSentinel 't63-links-esc-paren') + '.md') (@'
# Test fixture

This uses [escaped parens](foo\(bar\).md) in the destination.
'@ + "`n")

# --- Test 14: broken links under docs/plans/ ------------------
$planRel = "docs/plans/.test-" + (_LinkSentinel 't63-plan-broken') + '.md'
_LinkFixture 'links.test: validate.ps1 catches broken links under docs/plans/ after allowlist narrowing' 1 `
    $planRel (@'
---
lifecycle: experimental
---

# Test fixture

This plan references a [genuinely missing target](does-not-exist-PLAN-SENTINEL.md).
'@ + "`n")

# --- Test 15: mixed-character fence-like lines = content -
_LinkFixture 'links.test: validate.ps1 treats mixed-char fence-like lines as content' 0 `
    (".test-" + (_LinkSentinel 't63-links-mixed-close') + '.md') (@'
# Test fixture

~~~markdown
[example only](pretend-mixed-missing.md)
``~~
[also inside fence](still-pretend-mixed.md)
~~~
'@ + "`n")

# --- Test 16: multi-backtick inline-code spans stripped --
_LinkFixture 'links.test: validate.ps1 strips multi-backtick inline-code spans' 0 `
    (".test-" + (_LinkSentinel 't63-links-multi-inline') + '.md') (@'
# Test fixture

Both forms should be stripped: ``[double-tick link](pretend-double-missing.md)`` and `[single-tick link](pretend-single-missing.md)`.
'@ + "`n")

# --- Test 17: real broken links AFTER a fenced block ---
_LinkFixture 'links.test: validate.ps1 detects real broken links after a fenced block' 1 `
    (".test-" + (_LinkSentinel 't63-links-after-fence') + '.md') (@'
# Test fixture

```bash
example_command
```

This line has a [genuinely broken link](does-not-exist-AFTER-FENCE-SENTINEL.md).
'@ + "`n")

# ---------------------------------------------------------------------------
# Tests 18-21 — GNU awk / mawk / locale-blank — MOOT IN PS PORT
#
# Bash twin runs these conditionally if gawk/mawk are on PATH; the assertions
# guard against AWK regex-engine divergence (BSD vs gawk vs mawk) + the gawk-
# locale-blank gsub no-op. The PowerShell port uses.NET regex which has NO
# engine variation and NO locale-dependent gsub behavior — neither failure
# mode is reachable. Keep the 4 _Skip calls with that rationale so the AC
# count matches the bash twin + future maintainers see why.
# ---------------------------------------------------------------------------

$mootReason = 'moot in .NET regex — no BSD/GNU/mawk engine variation; no LC_ALL=C-dependent gsub no-op'

_Skip 'links.test: validate.ps1 passes on unmodified repo under GNU awk' $mootReason
_Skip 'links.test: validate.ps1 passes on unmodified repo under mawk' $mootReason
_Skip 'links.test: validate.ps1 handles nested 4-backtick fence under GNU awk' $mootReason
_Skip 'links.test: validate.ps1 strips inline-code spans under GNU awk in blank locale' $mootReason

# ---------------------------------------------------------------------------
# Tests 22-30 — GitHub-platform skip-list (full matrix)
# ---------------------------------------------------------------------------

# --- Test 22: `../../issues` treated as external -----------------
_LinkFixture 'links.test: validate.ps1 recognizes ../../issues as a GitHub-platform link' 0 `
    (".test-" + (_LinkSentinel 't105-gh-issues') + '.md') (@'
# Test fixture

Open an [issue](../../issues) on this repository.
'@ + "`n")

# --- Test 23: `../../issues/123` sub-path also external ----------
_LinkFixture 'links.test: validate.ps1 recognizes ../../issues/123 as a GitHub-platform link' 0 `
    (".test-" + (_LinkSentinel 't105-gh-issue-n') + '.md') (@'
# Test fixture

See [the broken-link bug](../../issues/123) for the full incident write-up.
'@ + "`n")

# --- Test 24: all 13 canonical prefixes recognized ---------------
_LinkFixture 'links.test: validate.ps1 recognizes all canonical GitHub-platform prefixes' 0 `
    (".test-" + (_LinkSentinel 't105-gh-misc') + '.md') (@'
# Test fixture

- [Wiki home](../../wiki)
- [Wiki page](../../wiki/Some-Page)
- [Pull requests](../../pulls)
- [Pull #5](../../pulls/5)
- [Releases](../../releases)
- [Release tag](../../releases/tag/v1.0.0)
- [Source tree](../../tree/main)
- [File blob](../../blob/main/README.md)
- [Labels](../../labels)
- [Specific label](../../labels/bug)
- [Milestones](../../milestones)
- [Milestone #1](../../milestones/1)
- [Commits](../../commits)
- [Branch commits](../../commits/main)
- [Discussions](../../discussions)
- [Discussion #7](../../discussions/7)
'@ + "`n")

# --- Test 25: regular broken local links still fail -----
_LinkFixture 'links.test: validate.ps1 still rejects regular broken local links' 1 `
    (".test-" + (_LinkSentinel 't105-still-broken') + '.md') (@'
# Test fixture

This is a [genuinely broken local link](does-not-exist-T105-SENTINEL.md).
'@ + "`n")

# --- Test 26:../ broken local links still fail ---------
$parentRel = "docs/.test-" + (_LinkSentinel 't105-parent-broken') + '.md'
_LinkFixture 'links.test: validate.ps1 still rejects ../ broken local links' 1 `
    $parentRel (@'
# Test fixture

See [parent ref](../never-existed-T105-PARENT-SENTINEL.md) for details.
'@ + "`n")

# --- Test 27: bare `../../tree` and `../../blob` -------------
_LinkFixture 'links.test: validate.ps1 recognizes bare ../../tree and ../../blob' 0 `
    (".test-" + (_LinkSentinel 't105-gh-tree-blob-bare') + '.md') (@'
# Test fixture

- [Default branch tree](../../tree)
- [Default branch blob](../../blob)
'@ + "`n")

# --- Test 28: near-prefixes still fail -------------
_LinkFixture 'links.test: validate.ps1 still rejects GitHub-platform near-prefixes' 1 `
    (".test-" + (_LinkSentinel 't105-gh-near-prefix') + '.md') (@'
# Test fixture

These near-prefixes should each be treated as a local-resolution attempt:
- [broken with dash suffix](../../issues-old/T105-NEAR-SENTINEL.md)
- [broken with bare suffix](../../wikifoo/T105-NEAR-SENTINEL.md)
- [broken with bare suffix on plural](../../pullsbar/T105-NEAR-SENTINEL.md)
'@ + "`n")

# --- Test 29: GitHub-platform links with query + anchor -----
_LinkFixture 'links.test: validate.ps1 recognizes GitHub-platform links with query/anchor' 0 `
    (".test-" + (_LinkSentinel 't105-gh-query-anchor') + '.md') (@'
# Test fixture

- [Open issues](../../issues?q=is:open)
- [Specific discussion comment](../../discussions/7#discussioncomment-123)
- [Branch tree at anchor](../../tree/main#section)
'@ + "`n")

# --- Test 30: singular `pull/N` + `commit/<sha>` -------------
_LinkFixture 'links.test: validate.ps1 recognizes singular ../../pull/N and ../../commit/SHA' 0 `
    (".test-" + (_LinkSentinel 't105-gh-singular') + '.md') (@'
# Test fixture

- [Specific PR (singular)](../../pull/123)
- [Specific PR with hash anchor](../../pull/123#issuecomment-789)
- [Specific commit (singular)](../../commit/abcdef1234567890)
- [Bare pull listing fallback](../../pull)
- [Bare commit listing fallback](../../commit)
'@ + "`n")

# Hermetic fixture teardown (<TEAM>-432): the throwaway clone (and its index)
# is the only thing the injection tests touched — remove it.
Remove-Item -Recurse -Force -LiteralPath $LK_FIX -ErrorAction SilentlyContinue
