#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tiering: scan-heavy — runs the full scripts/validate.sh against a
# staged fixture once per assertion (~30 whole-repo scans). Skipped by
# `make test-fast`.
# test-tier: slow
# tests/links.test.sh — internal markdown link integrity.
#
# scripts/validate.sh's new check_internal_links must:
# 1. PASS on the unmodified repo (baseline — every tracked link resolves).
# 2. FAIL when a tracked.md contains a broken relative link.
# 3. PASS when the broken link is inside an allowlisted path (vendored/).
# 4. PASS when the "link" is actually inside a code-fenced example.
# 5. PASS for external schemes (http, mailto) and pure anchors (#section).
# 6. Failure messages must name BOTH the file and the broken target so an
# engineer can fix without re-running with -x.
#
# Tests INJECT temp.md files into a hermetic tracked-only git fixture
# ($LK_FIX via make_tracked_git_fixture, <TEAM>-432 — never the live repo
# index), git-track them there so the scanner (which walks `git ls-files
# '*.md'`) sees them, and clean up inline (no trap EXIT — tests/run.sh sources
# files, traps would leak across siblings). Planting in $REPO_ROOT and
# `git add -f`-ing into the LIVE index raced any concurrent `git commit` in
# the same checkout. validate.sh resolves its repo root from its own script
# location, so the fixture's copy scans the fixture tree with the throwaway
# index. Sentinel names include $$-${RANDOM:-x} to avoid collisions across
# parallel runs and obvious.test-t53- prefixes to make stragglers easy to find.

# --- Test 1: baseline — validate passes on the unmodified repo ---
# Regression guard: if any pre-existing tracked.md has a broken internal link
# the C7 scanner would catch, this fails RED and forces fix-before-merge.
# Deliberately runs against the LIVE repo — this is the one assertion whose
# subject is the operator's actual tree, and it is read-only.
assert_exit "validate.sh passes on unmodified repo" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"

# Hermetic injection fixture for every test below (<TEAM>-432).
LK_FIX="$(mktemp -d)"
make_tracked_git_fixture "$LK_FIX"

# --- Test 2: broken internal link rejected ---
# A tracked.md outside the vendored allowlist with [text](missing.md) must
# trigger a FAIL from check_internal_links.
LINK_BROKEN=".test-t53-links-broken-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_BROKEN" <<'MD'
# Test fixture
This points to a [missing file](does-not-exist-anywhere.md) on purpose.
MD
git -C "$LK_FIX" add -f "$LINK_BROKEN"
assert_exit "validate.sh fails on broken internal markdown link" 1 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_BROKEN"
rm -f "$LK_FIX/$LINK_BROKEN"

# --- Test 3: broken link inside vendored/ allowlist is permitted ---
# Vendored snapshots are immutable. A broken ref inside
# harnesses/<h>/vendored/** must NOT trip the check.
LINK_VENDORED_DIR="harnesses/claude/vendored/_test-t53-$$-${RANDOM:-x}"
LINK_VENDORED_FILE="$LINK_VENDORED_DIR/fixture.md"
mkdir -p "$LK_FIX/$LINK_VENDORED_DIR"
cat > "$LK_FIX/$LINK_VENDORED_FILE" <<'MD'
# Vendored fixture
[Broken upstream ref](../../docs/never-copied.md) — allowlisted.
MD
git -C "$LK_FIX" add -f "$LINK_VENDORED_FILE"
assert_exit "validate.sh allows broken links inside vendored/" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_VENDORED_FILE"
rm -rf "$LK_FIX/$LINK_VENDORED_DIR"

# --- Test 4: links inside code fences are skipped ---
# A ```fenced block``` containing [foo](missing.md) is documentation, not a
# real link. The scanner must not false-positive.
LINK_FENCED=".test-t53-links-fenced-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_FENCED" <<'MD'
# Test fixture
Here is a code example:

```markdown
[example only](pretend-missing.md)
```

End of file.
MD
git -C "$LK_FIX" add -f "$LINK_FENCED"
assert_exit "validate.sh ignores links inside code fences" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_FENCED"
rm -f "$LK_FIX/$LINK_FENCED"

# --- Test 5: external schemes and pure anchors are skipped ---
# [foo](https://...), [foo](mailto:...), [foo](#section) must not be checked.
LINK_EXTERNAL=".test-t53-links-external-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_EXTERNAL" <<'MD'
# Test fixture
- [Example](https://example.com/owner/repo)
- [Email](mailto:nobody@example.com)
- [Anchor](#section-x)
MD
git -C "$LK_FIX" add -f "$LINK_EXTERNAL"
assert_exit "validate.sh ignores external schemes + pure anchors" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_EXTERNAL"
rm -f "$LK_FIX/$LINK_EXTERNAL"

# --- Test 6: failure message surfaces the broken link (diagnostic) ---
# When the check fails, the message must name the file AND the broken target,
# so an engineer can fix it without re-running with -x.
# Uses assert_contains (the only public string-assertion helper in tests/lib.sh)
# split across two assertions — file path AND target each verified independently.
LINK_DIAG=".test-t53-links-diag-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_DIAG" <<'MD'
# Test fixture
[diagnostic broken](path-DIAG-SENTINEL.md)
MD
git -C "$LK_FIX" add -f "$LINK_DIAG"
diag_out="$(bash "$LK_FIX/scripts/validate.sh" 2>&1 || true)"
assert_contains "validate.sh failure message names the file" \
  "$diag_out" "$LINK_DIAG"
assert_contains "validate.sh failure message names the broken target" \
  "$diag_out" "path-DIAG-SENTINEL.md"
git -C "$LK_FIX" rm -f --quiet "$LINK_DIAG"
rm -f "$LK_FIX/$LINK_DIAG"

# =============================================================================
# fence + inline-code parser improvements
# =============================================================================
# Filed from the 2026-05-23 cross-model review (F-2/F-3/F-4). The C7
# scanner works on the unmodified repo but has parser weaknesses that produce
# false-positives in future docs. These 7 tests cover the fixes and pin
# documented limitations.

# --- Test 7: inline-code spans containing [link](path) are skipped ---
# A non-fenced line containing `[text](pretend-missing.md)` between single
# backticks is documentation, not a real link. Pre-fix: false-fails because
# the scanner doesn't strip inline-code spans before extraction. Post-fix:
# inline `…` spans are stripped, so example links inside backtick prose pass.
LINK_INLINE_CODE=".test-t63-links-inline-code-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_INLINE_CODE" <<'MD'
# Test fixture

Use `[example](pretend-inline-missing.md)` as the canonical syntax in docs.
MD
git -C "$LK_FIX" add -f "$LINK_INLINE_CODE"
assert_exit "validate.sh skips links inside inline-code spans" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_INLINE_CODE"
rm -f "$LK_FIX/$LINK_INLINE_CODE"

# --- Test 8: tilde-fenced code blocks are recognized ---
# A ~~~-delimited fence is a CommonMark code block, equivalent to ```. The
# pre-fix awk toggle only matches backtick fences; ~~~ contents leak into
# the scan. Post-fix: the parser tracks fence char + length and recognizes
# both delimiters.
LINK_TILDE_FENCE=".test-t63-links-tilde-fence-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_TILDE_FENCE" <<'MD'
# Test fixture

~~~markdown
[example only](pretend-tilde-missing.md)
~~~
MD
git -C "$LK_FIX" add -f "$LINK_TILDE_FENCE"
assert_exit "validate.sh recognizes ~~~ fences" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_TILDE_FENCE"
rm -f "$LK_FIX/$LINK_TILDE_FENCE"

# --- Test 9: fences indented 1-3 spaces are recognized ---
# Per CommonMark, code fences may be indented up to 3 spaces. The pre-fix
# regex requires fence at column 1 (^```), so an indented fence is not
# recognized and its contents leak into the scan.
LINK_INDENTED_FENCE=".test-t63-links-indented-fence-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_INDENTED_FENCE" <<'MD'
# Test fixture

   ```markdown
   [example only](pretend-indented-missing.md)
   ```
MD
git -C "$LK_FIX" add -f "$LINK_INDENTED_FENCE"
assert_exit "validate.sh recognizes fences indented 1-3 spaces" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_INDENTED_FENCE"
rm -f "$LK_FIX/$LINK_INDENTED_FENCE"

# --- Test 10: nested triple-backticks inside outer 4-backtick
# fence don't prematurely close ---
# The plan-doc case. Per CommonMark, the closing fence must use the
# same character AND be at least as long as the opening, so a 3-backtick line
# inside a 4-backtick fence is content, not a close. Pre-fix: naive
# ^```/ toggle treats the 3-backtick line as a close, leaking the rest of
# the file into scan.
LINK_NESTED_FENCE=".test-t63-links-nested-fence-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_NESTED_FENCE" <<'MD'
# Test fixture

````markdown
Example:

```
[inside nested](pretend-nested-missing.md)
```

End of nested block.
````
MD
git -C "$LK_FIX" add -f "$LINK_NESTED_FENCE"
assert_exit "validate.sh handles nested triple-backticks inside 4-backtick fence" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_NESTED_FENCE"
rm -f "$LK_FIX/$LINK_NESTED_FENCE"

# --- Test 11: reference-style links are NOT checked ---
# The scanner only extracts inline links of the form [text](target). Reference-
# style links [text][ref] with separate [ref]: target definitions are NOT
# tracked. This test pins that behavior — a broken reference-style link does
# NOT trip the gate. Documenting this prevents future "obvious bug" reports
# and signals the limitation to operators.
LINK_REFSTYLE=".test-t63-links-ref-style-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_REFSTYLE" <<'MD'
# Test fixture

See [the example][ex] for details.

[ex]: pretend-ref-missing.md
MD
git -C "$LK_FIX" add -f "$LINK_REFSTYLE"
assert_exit "validate.sh does not check reference-style links" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_REFSTYLE"
rm -f "$LK_FIX/$LINK_REFSTYLE"

# --- Test 12: escaped parens in destinations ---
# CommonMark allows [text](foo\(bar\).md) where \(and \) are escaped parens
# in the link destination. The scanner's [^)]+ extraction stops at the first
#) — escaped or not — producing a truncated target like "foo\(bar\". The
# truncated target won't exist on disk, so the gate FAILs. Pin this current
# behavior; a future enhancement could parse balanced/escaped parens.
LINK_ESC_PAREN=".test-t63-links-esc-paren-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_ESC_PAREN" <<'MD'
# Test fixture

This uses [escaped parens](foo\(bar\).md) in the destination.
MD
git -C "$LK_FIX" add -f "$LINK_ESC_PAREN"
assert_exit "validate.sh treats escaped-paren destinations as broken" 1 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_ESC_PAREN"
rm -f "$LK_FIX/$LINK_ESC_PAREN"

# --- Test 13: broken links under docs/plans/ are caught after
# allowlist narrowing ---
# Pre-fix: docs/plans/** was blanket-allowlisted because the fence parser
# couldn't handle nested triple-backticks or inline-code link syntax in plan
# docs (false positives forced the exclusion). Post-fix + F-2 + F-3: the
# parser handles those correctly, so the allowlist is narrowed/removed. This
# test plants a genuinely broken link in a temp plan file and confirms it IS
# caught.
LINK_PLAN_BROKEN="docs/plans/.test-t63-plan-broken-$$-${RANDOM:-x}.md"
mkdir -p "$LK_FIX/docs/plans"
cat > "$LK_FIX/$LINK_PLAN_BROKEN" <<'MD'
# Test fixture

This plan references a [genuinely missing target](does-not-exist-PLAN-SENTINEL.md).
MD
git -C "$LK_FIX" add -f "$LINK_PLAN_BROKEN"
assert_exit "validate.sh catches broken links under docs/plans/ after allowlist narrowing" 1 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_PLAN_BROKEN"
rm -f "$LK_FIX/$LINK_PLAN_BROKEN"

# =============================================================================
# cross-model review amendments (Codex + Gemini, 2026-05-24)
# =============================================================================
# Cross-model review of the initial fix flagged three substantive issues:
# (1) mixed-character closing fences should not close; (2) multi-backtick
# inline-code spans bypassed the single-backtick gsub; (3) regression
# safety after a fenced block. These tests pin the amendments.

# --- Test 14 (Codex+Gemini agreed): mixed-character fence-like lines do
# NOT close the active fence ---
# CommonMark requires the closing fence to consist entirely of the same
# character as the opening. A line mixing tildes + backticks (e.g.
# "``~~") inside a tilde fence must NOT close it. The pre-amendment
# close-regex [`~]+ accepted any mix of fence chars. After: opening AND
# closing patterns use the same ("```\`*"|"~~~~*") alternation that
# enforces homogeneous fence character, plus a manual scan that counts
# only consecutive same-character chars from the start.
LINK_MIXED_CLOSE=".test-t63-links-mixed-close-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_MIXED_CLOSE" <<'MD'
# Test fixture

~~~markdown
[example only](pretend-mixed-missing.md)
``~~
[also inside fence](still-pretend-mixed.md)
~~~
MD
git -C "$LK_FIX" add -f "$LINK_MIXED_CLOSE"
assert_exit "validate.sh treats mixed-char fence-like lines as content" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_MIXED_CLOSE"
rm -f "$LK_FIX/$LINK_MIXED_CLOSE"

# --- Test 15 (Codex+Gemini agreed): multi-backtick inline-code spans
# are stripped ---
# CommonMark allows double- and triple-backtick inline-code spans
# (used to enclose content that contains backticks of OTHER lengths).
# The pre-amendment gsub was single-backtick-only; double-backtick spans
# containing link syntax (e.g. ``[link](path)``) leaked their content
# to the link extractor. After: three longest-first gsub passes strip
# triple, double, and single-backtick spans.
LINK_MULTI_INLINE=".test-t63-links-multi-inline-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_MULTI_INLINE" <<'MD'
# Test fixture

Both forms should be stripped: ``[double-tick link](pretend-double-missing.md)`` and `[single-tick link](pretend-single-missing.md)`.
MD
git -C "$LK_FIX" add -f "$LINK_MULTI_INLINE"
assert_exit "validate.sh strips multi-backtick inline-code spans" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_MULTI_INLINE"
rm -f "$LK_FIX/$LINK_MULTI_INLINE"

# --- Test 16 (Codex regression): real broken links AFTER a fenced block
# are still detected ---
# Regression coverage: a parser bug that mis-closes the fence and treats
# subsequent content as "inside fence" would hide real broken links. This
# test plants a clean fenced block followed by a genuinely broken link
# and confirms the broken link IS caught (exit 1).
LINK_AFTER_FENCE=".test-t63-links-after-fence-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_AFTER_FENCE" <<'MD'
# Test fixture

```bash
example_command
```

This line has a [genuinely broken link](does-not-exist-AFTER-FENCE-SENTINEL.md).
MD
git -C "$LK_FIX" add -f "$LINK_AFTER_FENCE"
assert_exit "validate.sh detects real broken links after a fenced block" 1 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_AFTER_FENCE"
rm -f "$LK_FIX/$LINK_AFTER_FENCE"

# =============================================================================
# GNU awk / BSD awk portability
# =============================================================================
# The original fence regex `(```\`*|~~~~*)` carried a redundant `\\` escape
# in the backtick alternative. BSD awk treats `\\\`` as a literal-backtick
# atom (so `\\\`*` = "0+ backticks"), but POSIX ERE leaves backslash-before-
# non-special implementation-defined and GNU gawk parses it as "literal
# backslash + literal backtick" (two atoms; `*` applies to only the second),
# requiring a literal `\` in the input that real markdown fences never
# contain. Symptom: 12+ false-positive "broken internal link" errors on
# Linux CI from links INSIDE 4-backtick code fences in the
# plan files. Fix: drop the `\\` from both OPEN and CLOSE patterns so every
# POSIX awk parses `````*` the same way ("3+ backticks"); also force
# LC_ALL=C on the awk invocation so locale-misconfigured envs don't break
# the inline-code gsub passes (locale-blank gawk on macOS silently no-ops
# gsub).
#
# These tests re-run the existing assertions under AWK=gawk + AWK=mawk
# whenever those engines are on PATH so a future regression in either
# direction trips locally before CI.

# --- Test 17: validate.sh passes on the clean fixture under GNU awk ---
# Direct port of Test 1 with AWK=gawk. RED-state on pre-fix main: the
# plan's 4-backtick fence content leaks into link extraction, producing 12+
# false-positive broken-link errors. Skips silently when gawk isn't on PATH
# (typical on minimal macOS installs; install via `brew install gawk`).
if command -v gawk >/dev/null 2>&1; then
  assert_exit "validate.sh passes on the clean fixture under GNU awk" 0 -- \
    env AWK=gawk bash "$LK_FIX/scripts/validate.sh"
else
  _skip "validate.sh passes on the clean fixture under GNU awk" "gawk not on PATH (brew install gawk)"
fi

# --- Test 18: validate.sh passes on the clean fixture under mawk ---
# Direct port of Test 1 with AWK=mawk. mawk is the default `awk` on
# Ubuntu/Debian; this test pins parity with the CI default-awk lane on
# macOS where /usr/bin/awk is BSD awk. Skips silently when mawk isn't on
# PATH.
if command -v mawk >/dev/null 2>&1; then
  assert_exit "validate.sh passes on the clean fixture under mawk" 0 -- \
    env AWK=mawk bash "$LK_FIX/scripts/validate.sh"
else
  _skip "validate.sh passes on unmodified repo under mawk (clean fixture)" "mawk not on PATH (brew install mawk)"
fi

# --- Test 19: nested 4-backtick fence under GNU awk ---
# Narrow regression pin on the specific failure mode closed. Same
# fixture shape as Test 10, but explicitly under AWK=gawk. If a future
# parser change re-introduces a GNU-awk fence-detection divergence on
# 4-backtick fences, this fails first with a clearly-named assertion.
if command -v gawk >/dev/null 2>&1; then
  LINK_GAWK_4TICK=".test-t88-gawk-4tick-fence-$$-${RANDOM:-x}.md"
  cat > "$LK_FIX/$LINK_GAWK_4TICK" <<'MD'
# Test fixture

````markdown
Example:

```
[inside nested](pretend-gawk-nested-missing.md)
```

End of nested block.
````
MD
  git -C "$LK_FIX" add -f "$LINK_GAWK_4TICK"
  assert_exit "validate.sh handles nested 4-backtick fence under GNU awk" 0 -- \
    env AWK=gawk bash "$LK_FIX/scripts/validate.sh"
  git -C "$LK_FIX" rm -f --quiet "$LINK_GAWK_4TICK"
  rm -f "$LK_FIX/$LINK_GAWK_4TICK"
else
  _skip "validate.sh handles nested 4-backtick fence under GNU awk" "gawk not on PATH"
fi

# --- Test 20: inline-code span containing a link, under GNU awk ---
# Narrow regression pin on the second bug: gawk under a blank locale
# silently no-ops `gsub(/`[^`]+`/,...)`, leaking inline-code link literals
# into the broken-link scan. The validate.sh fix forces LC_ALL=C on the
# awk invocation; this test pins that fix by deliberately blanking LANG /
# LC_ALL / LC_CTYPE before invoking validate.sh.
if command -v gawk >/dev/null 2>&1; then
  LINK_GAWK_INLINE=".test-t88-gawk-inline-code-$$-${RANDOM:-x}.md"
  cat > "$LK_FIX/$LINK_GAWK_INLINE" <<'MD'
# Test fixture

This prose mentions `[example](pretend-gawk-inline-missing.md)` as a syntax
demo. The inline-code span must be stripped before link extraction or the
broken-link scan false-positives under GNU awk in misconfigured locales.
MD
  git -C "$LK_FIX" add -f "$LINK_GAWK_INLINE"
  assert_exit "validate.sh strips inline-code spans under GNU awk in blank locale" 0 -- \
    env AWK=gawk LANG= LC_ALL= LC_CTYPE= bash "$LK_FIX/scripts/validate.sh"
  git -C "$LK_FIX" rm -f --quiet "$LINK_GAWK_INLINE"
  rm -f "$LK_FIX/$LINK_GAWK_INLINE"
else
  _skip "validate.sh strips inline-code spans under GNU awk in blank locale" "gawk not on PATH"
fi

# =============================================================================
# GitHub-platform relative links recognized as external
# =============================================================================
# `[issue tracker](../../issues)` and similar `../../<github-platform-segment>`
# markdown links resolve at GitHub-render time (relative URL routing on
# github.com) but NOT on the local filesystem. Pre-fix validate.sh
# treated them as local-filesystem relatives and FAILed with "broken internal
# link". This forced to use plain text instead of markdown links in
# SECURITY.md / CODE_OF_CONDUCT.md as a workaround. The actual fix extends
# validate.sh's external-scheme skip-list with the known GitHub-platform
# path prefixes. See [[feedback_github_relative_links_trip_validate]].
#
# Counterpart in validate.ps1: the PS twin does NOT
# currently port `check_internal_links` at all (intentionally narrow scope
# per the prototype spec, G-4 in
# `docs/superpowers/specs/2026-05-27-windows-native-prototype.md`); the full
# port is deferred to (Issue 5B-c — Windows-native tests ports).
# Once that port lands, the same skip-list must be mirrored in validate.ps1.

# --- Test 21: `[text](../../issues)` is treated as external ---
# Plant a tracked.md with the canonical GitHub-platform issue-tracker
# link. Pre-fix: FAIL (link check resolves `../../issues` as a local path
# and finds nothing). Post-fix: PASS (case glob skips the prefix).
LINK_GH_ISSUES=".test-t105-gh-issues-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_GH_ISSUES" <<'MD'
# Test fixture

Open an [issue](../../issues) on this repository.
MD
git -C "$LK_FIX" add -f "$LINK_GH_ISSUES"
assert_exit "validate.sh recognizes ../../issues as a GitHub-platform link" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_GH_ISSUES"
rm -f "$LK_FIX/$LINK_GH_ISSUES"

# --- Test 22: `../../issues/123` (specific issue) is external ---
# The `/*` suffix glob must catch numbered sub-paths the same way.
LINK_GH_ISSUE_N=".test-t105-gh-issue-n-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_GH_ISSUE_N" <<'MD'
# Test fixture

See [the broken-link bug](../../issues/123) for the full incident write-up.
MD
git -C "$LK_FIX" add -f "$LINK_GH_ISSUE_N"
assert_exit "validate.sh recognizes ../../issues/123 as a GitHub-platform link" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_GH_ISSUE_N"
rm -f "$LK_FIX/$LINK_GH_ISSUE_N"

# --- Test 23: `../../wiki`, `../../pulls`, `../../releases` are external ---
# Bundle the remaining canonical GitHub-platform prefixes in one fixture so
# a regression in any one of them surfaces a single named assertion.
LINK_GH_MISC=".test-t105-gh-misc-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_GH_MISC" <<'MD'
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
MD
git -C "$LK_FIX" add -f "$LINK_GH_MISC"
assert_exit "validate.sh recognizes all canonical GitHub-platform prefixes" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_GH_MISC"
rm -f "$LK_FIX/$LINK_GH_MISC"

# --- Test 24: regular broken local links STILL fail (negative regression) ---
# Critical negative test: the new skip-list MUST NOT swallow regular broken
# relative links. A `[text](does-not-exist.md)` in a tracked.md must still
# trigger a FAIL exactly as before. If this fails GREEN it means the
# skip-list is over-broad and we've lost the gate's value.
LINK_T105_BROKEN=".test-t105-still-broken-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_T105_BROKEN" <<'MD'
# Test fixture

This is a [genuinely broken local link](does-not-exist-T105-SENTINEL.md).
MD
git -C "$LK_FIX" add -f "$LINK_T105_BROKEN"
assert_exit "validate.sh still rejects regular broken local links" 1 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_T105_BROKEN"
rm -f "$LK_FIX/$LINK_T105_BROKEN"

# --- Test 25: broken local link with `../` prefix STILL fails ---
# Specifically guard against a regression where the skip-list pattern
# over-matches plain `../`-prefixed local paths. `../does-not-exist.md`
# from a tracked.md must still fail — only the listed GitHub-platform
# segments are skipped.
LINK_T105_PARENT="docs/.test-t105-parent-broken-$$-${RANDOM:-x}.md"
mkdir -p "$LK_FIX/docs"
cat > "$LK_FIX/$LINK_T105_PARENT" <<'MD'
# Test fixture

See [parent ref](../never-existed-T105-PARENT-SENTINEL.md) for details.
MD
git -C "$LK_FIX" add -f "$LINK_T105_PARENT"
assert_exit "validate.sh still rejects ../ broken local links" 1 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_T105_PARENT"
rm -f "$LK_FIX/$LINK_T105_PARENT"

# --- Test 26: bare `../../tree` and `../../blob` ---
# Codex confirmation review F-1 (cross-model, 2026-05-27): the initial
# patch matched `../../tree/*` / `../../blob/*` but NOT bare `../../tree`
# or `../../blob` — a near-miss with the comment that claims "canonical
# segments including tree / blob". GitHub renders `/tree` (no ref) as the
# default-branch tree view; `/blob` is less common as a bare path but
# included for symmetry. The case-arm was widened to also match the
# bare segment. This test pins both forms.
LINK_GH_TREE_BLOB_BARE=".test-t105-gh-tree-blob-bare-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_GH_TREE_BLOB_BARE" <<'MD'
# Test fixture

- [Default branch tree](../../tree)
- [Default branch blob](../../blob)
MD
git -C "$LK_FIX" add -f "$LINK_GH_TREE_BLOB_BARE"
assert_exit "validate.sh recognizes bare ../../tree and ../../blob" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_GH_TREE_BLOB_BARE"
rm -f "$LK_FIX/$LINK_GH_TREE_BLOB_BARE"

# --- Test 27: near-prefix boundary check ---
# Codex confirmation review MT-2 (cross-model, 2026-05-27): explicitly
# prove that near-prefixes (suffix-character that turns the segment into
# a different identifier) are NOT swallowed by the skip-list — they
# fall through to the local-resolution branch and FAIL the gate. Guards
# against a future regression that switches the case-arm from
# `../../issues|../../issues/*` to `../../issues*` (with `*` suffix,
# which WOULD swallow `issues-old` / `issuesfoo`).
#
# Three near-prefix shapes verified in a single fixture (`-` separator,
# bare-suffix, and a different-segment near-prefix). All three must
# trigger the broken-link failure — the gate only fails once if ANY
# is unresolved, so this verifies the overall behavior; per-shape
# coverage would require three separate fixtures.
LINK_GH_NEAR_PREFIX=".test-t105-gh-near-prefix-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_GH_NEAR_PREFIX" <<'MD'
# Test fixture

These near-prefixes should each be treated as a local-resolution attempt:
- [broken with dash suffix](../../issues-old/T105-NEAR-SENTINEL.md)
- [broken with bare suffix](../../wikifoo/T105-NEAR-SENTINEL.md)
- [broken with bare suffix on plural](../../pullsbar/T105-NEAR-SENTINEL.md)
MD
git -C "$LK_FIX" add -f "$LINK_GH_NEAR_PREFIX"
assert_exit "validate.sh still rejects GitHub-platform near-prefixes" 1 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_GH_NEAR_PREFIX"
rm -f "$LK_FIX/$LINK_GH_NEAR_PREFIX"

# --- Test 28: query + anchor variants ---
# Codex confirmation review MT-3 (cross-model, 2026-05-27): pin the
# interaction with the pre-existing query (`?q=...`) and anchor (`#...`)
# strip steps at scripts/validate.sh:571-572. Query + anchor are stripped
# BEFORE the case-arm runs, so `../../issues?q=is:open` becomes
# `../../issues` and matches the GH_ISSUES skip-list. This test pins
# that the two strip steps + the new skip-list compose correctly.
LINK_GH_QUERY_ANCHOR=".test-t105-gh-query-anchor-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_GH_QUERY_ANCHOR" <<'MD'
# Test fixture

- [Open issues](../../issues?q=is:open)
- [Specific discussion comment](../../discussions/7#discussioncomment-123)
- [Branch tree at anchor](../../tree/main#section)
MD
git -C "$LK_FIX" add -f "$LINK_GH_QUERY_ANCHOR"
assert_exit "validate.sh recognizes GitHub-platform links with query/anchor" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_GH_QUERY_ANCHOR"
rm -f "$LK_FIX/$LINK_GH_QUERY_ANCHOR"

# --- Test 29: singular pull/N + commit/SHA ---
# Codex adversarial review A-2 (cross-model, 2026-05-27): GitHub's canonical
# detail routes for a specific PR or specific commit use the SINGULAR
# segment, while the plural forms (`/pulls`, `/commits`) are list views.
# The initial patch only covered the plurals;../../pull/123 and
# ./../commit/<sha> are legitimate GitHub-platform links that this gate
# was incorrectly rejecting. Case-arm widened to cover both singular and
# plural forms; this test pins the new coverage.
LINK_GH_SINGULAR=".test-t105-gh-singular-$$-${RANDOM:-x}.md"
cat > "$LK_FIX/$LINK_GH_SINGULAR" <<'MD'
# Test fixture

- [Specific PR (singular)](../../pull/123)
- [Specific PR with hash anchor](../../pull/123#issuecomment-789)
- [Specific commit (singular)](../../commit/abcdef1234567890)
- [Bare pull listing fallback](../../pull)
- [Bare commit listing fallback](../../commit)
MD
git -C "$LK_FIX" add -f "$LINK_GH_SINGULAR"
assert_exit "validate.sh recognizes singular ../../pull/N and ../../commit/SHA" 0 -- \
  bash "$LK_FIX/scripts/validate.sh"
git -C "$LK_FIX" rm -f --quiet "$LINK_GH_SINGULAR"
rm -f "$LK_FIX/$LINK_GH_SINGULAR"

# --- T-T89: explicit existence of the Setup pages ---
# linear-setup.md, obsidian/vault-guide.md.
# Pinned explicitly so a future delete/rename breaks with a named assertion,
# not just a generic broken-link sweep.
assert_file "Setup page exists: linear/linear-setup.md" \
  "$REPO_ROOT/linear/linear-setup.md"
assert_file "Setup page exists: obsidian/vault-guide.md" \
  "$REPO_ROOT/obsidian/vault-guide.md"

# Hermetic fixture teardown (<TEAM>-432): the throwaway clone (and its index)
# is the only thing the injection tests touched — remove it. No trap EXIT (see
# header); inline removal is the cleanup contract, same as the per-test rm -f.
rm -rf "$LK_FIX"
unset LK_FIX
