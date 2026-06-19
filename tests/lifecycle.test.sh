#!/usr/bin/env bash
# tests/lifecycle.test.sh — lifecycle: frontmatter convention enforcement.
#
# scripts/validate.sh's new check_lifecycle must:
# 1. PASS on the unmodified repo (every in-scope artifact carries a valid lifecycle:).
# 2. FAIL when an in-scope tracked.md lacks lifecycle: in its frontmatter.
# 3. FAIL when an in-scope tracked.md has an invalid lifecycle: value.
# 4. FAIL when an in-scope tracked.md has malformed frontmatter (unterminated ---).
# 5. ACCEPT the five canonical values: experimental | reviewed | shipped | superseded | sunset.
# 6. Skip out-of-scope paths (core/*.md, README.md, harness templates, etc).
#
# Tests INJECT temp.md files into $REPO_ROOT, git-track them so the scanner
# (which walks `git ls-files '*.md'` or the in-scope globs) sees them, and clean
# up inline (no trap EXIT — tests/run.sh sources files, traps would leak across
# siblings). Sentinel names include $$-${RANDOM:-x} to avoid collisions across
# parallel runs and obvious.test-t83- prefixes to make stragglers easy to find.
#
# Per reference_shell_grep_overlay: use /usr/bin/grep explicitly where POSIX
# regex semantics matter. Per reference_awk_portability: wrap awk in LC_ALL=C.
# Per feedback_self_tripping_test_source: split sentinel strings so this test
# file's own content doesn't trip other scanners.

# --- Test 1: baseline — validate passes on the unmodified repo ---
# Regression guard: if any in-scope tracked.md lacks lifecycle: this fails RED
# and forces fix-before-merge.
assert_exit "validate.sh passes on unmodified repo" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"

# --- Test 2: every in-scope tracked.md has a valid lifecycle: value ---
# Walks the same globs check_lifecycle enforces and asserts each file's
# frontmatter contains `lifecycle: <one of five>`. Complements the baseline
# assertion: the baseline catches validate.sh failing, this catches a file
# slipping past validate.sh without one of the five values (e.g. typo'd
# value that some loose regex might accept).
_test_lifecycle_values_inscope() {
  local valid_re='^lifecycle:[[:space:]]+(experimental|reviewed|shipped|superseded|sunset)[[:space:]]*$'
  local fail=0 rel file base fm
  # Mirror check_lifecycle in validate.sh: enumerate tracked.md via
  # git ls-files (so dotfile sentinels in the test suite are picked up too,
  # consistent with the validator) + filter by in-scope path predicates.
  while IFS= read -r rel; do
    case "$rel" in
      docs/plans/*.md) ;;
      docs/specs/*.md) ;;
      docs/*/plans/*.md) ;;
      docs/*/specs/*.md) ;;
      capabilities/*.md) ;;
      harnesses/*/capabilities/*.md) ;;
      *) continue ;;
    esac
    file="$REPO_ROOT/$rel"
    [ -e "$file" ] || continue
    base="$(basename "$file" .md)"
    [ "$base" = "README" ] && continue
    # Extract frontmatter block (between first --- and second ---).
    fm="$(LC_ALL=C awk 'NR==1{if($0!="---")exit; next} /^---[[:space:]]*$/{exit} {print}' "$file")"
    if [ -z "$fm" ]; then
      printf '  FAIL %s\n' "lifecycle scope: $base — missing/empty frontmatter" >&2
      fail=1
      continue
    fi
    if ! printf '%s\n' "$fm" | /usr/bin/grep -qE "$valid_re"; then
      printf '  FAIL %s\n' "lifecycle scope: $base — lifecycle: missing or invalid value" >&2
      fail=1
    fi
  done < <(git -C "$REPO_ROOT" ls-files)
  return $fail
}
if _test_lifecycle_values_inscope; then
  _pass "every in-scope tracked .md has a valid lifecycle: value"
else
  _fail "every in-scope tracked .md has a valid lifecycle: value"
fi

# Tests 3-11 plant fixtures under docs/plans/. The public template excludes docs/
# from its ship-set, so on a fresh template clone docs/plans/ holds only the
# fixture — and a plain `git rm` would then remove the emptied directory, breaking
# the next test. Create the directory once here, and unstage fixtures with
# `git rm --cached` (index only — the paired `rm -f` removes the working file) so
# the directory survives between tests. validate's lifecycle scope is path-pattern
# based (docs/plans/*.md), so it enforces these even when docs/ is otherwise absent.
mkdir -p "$REPO_ROOT/docs/plans"

# --- Test 3: validate rejects in-scope file with missing lifecycle: ---
# Inject a docs/plans/.test-t83-*.md with frontmatter but no lifecycle key.
# Validate must exit non-zero.
LIFECYCLE_MISSING="docs/plans/.test-t83-missing-lifecycle-$$-${RANDOM:-x}.md"
cat > "$REPO_ROOT/$LIFECYCLE_MISSING" <<'MD'
---
title: test fixture — missing lifecycle key
---

# Test fixture body
MD
git -C "$REPO_ROOT" add -f "$LIFECYCLE_MISSING"
assert_exit "validate.sh fails when in-scope file lacks lifecycle:" 1 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
git -C "$REPO_ROOT" rm -f --cached --quiet "$LIFECYCLE_MISSING"
rm -f "$REPO_ROOT/$LIFECYCLE_MISSING"

# --- Test 4: validate rejects in-scope file with invalid lifecycle: value ---
LIFECYCLE_INVALID="docs/plans/.test-t83-invalid-lifecycle-$$-${RANDOM:-x}.md"
cat > "$REPO_ROOT/$LIFECYCLE_INVALID" <<'MD'
---
lifecycle: bogus-value
---

# Test fixture body
MD
git -C "$REPO_ROOT" add -f "$LIFECYCLE_INVALID"
assert_exit "validate.sh fails when in-scope file has invalid lifecycle: value" 1 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
git -C "$REPO_ROOT" rm -f --cached --quiet "$LIFECYCLE_INVALID"
rm -f "$REPO_ROOT/$LIFECYCLE_INVALID"

# --- Test 5: validate rejects in-scope file with malformed (unterminated) frontmatter ---
LIFECYCLE_MALFORMED="docs/plans/.test-t83-malformed-lifecycle-$$-${RANDOM:-x}.md"
cat > "$REPO_ROOT/$LIFECYCLE_MALFORMED" <<'MD'
---
lifecycle: shipped

# Test fixture body (missing closing ---)
MD
git -C "$REPO_ROOT" add -f "$LIFECYCLE_MALFORMED"
assert_exit "validate.sh fails on malformed (unterminated) frontmatter" 1 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
git -C "$REPO_ROOT" rm -f --cached --quiet "$LIFECYCLE_MALFORMED"
rm -f "$REPO_ROOT/$LIFECYCLE_MALFORMED"

# --- Test 6: validate accepts all five canonical values ---
# Inject five separate files, one per value. Each must pass on its own AND
# the suite must remain GREEN with all five present.
_test_all_five_values_accepted() {
  local v files=()
  local fail=0
  for v in experimental reviewed shipped superseded sunset; do
    local f="docs/plans/.test-t83-value-${v}-$$-${RANDOM:-x}.md"
    cat > "$REPO_ROOT/$f" <<MD
---
lifecycle: $v
---

# Test fixture body — value=$v
MD
    git -C "$REPO_ROOT" add -f "$f" 2>/dev/null
    files+=("$f")
  done
  if ! bash "$REPO_ROOT/scripts/validate.sh" >/dev/null 2>&1; then
    fail=1
  fi
  for f in "${files[@]}"; do
    git -C "$REPO_ROOT" rm -f --cached --quiet "$f" 2>/dev/null
    rm -f "$REPO_ROOT/$f"
  done
  return $fail
}
if _test_all_five_values_accepted; then
  _pass "validate.sh accepts all five canonical lifecycle values"
else
  _fail "validate.sh accepts all five canonical lifecycle values"
fi

# --- Test 7: out-of-scope paths are NOT enforced ---
# Inject a tracked.md under an out-of-scope path with NO lifecycle: frontmatter.
# validate.sh must still exit 0 — proving the scope is narrow.
# core/ is out-of-scope per core/lifecycle.md applicability matrix.
LIFECYCLE_OOS="core/.test-t83-out-of-scope-$$-${RANDOM:-x}.md"
cat > "$REPO_ROOT/$LIFECYCLE_OOS" <<'MD'
# Out-of-scope test fixture — no frontmatter, no lifecycle: key
MD
git -C "$REPO_ROOT" add -f "$LIFECYCLE_OOS"
assert_exit "validate.sh passes on out-of-scope file without lifecycle:" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
git -C "$REPO_ROOT" rm -f --cached --quiet "$LIFECYCLE_OOS"
rm -f "$REPO_ROOT/$LIFECYCLE_OOS"

# --- Test 8: capabilities/README.md is excluded from enforcement ---
# README is the conventional directory README; check_lifecycle skips it per
# the same pattern as check_capabilities. Confirm by reading the file and
# asserting it does NOT contain lifecycle: AND that baseline (Test 1) still
# passes.
_test_readme_excluded() {
  if [ ! -f "$REPO_ROOT/capabilities/README.md" ]; then
    return 1
  fi
  if /usr/bin/grep -qE '^lifecycle:' "$REPO_ROOT/capabilities/README.md"; then
    return 1  # README has lifecycle: but Test 1 passes — exclusion is real
  fi
  return 0
}
if _test_readme_excluded; then
  _pass "capabilities/README.md is excluded from check_lifecycle"
else
  _fail "capabilities/README.md is excluded from check_lifecycle"
fi

# --- Test 9: regression guard — core/lifecycle.md does NOT contain
# install.sh placeholder tokens of the form @@TOKEN@@.
#
# PR #29 caught a global-substitution bug where the literal `@@CAPABILITY_CATALOG@@`
# in canonical-source-pointer prose got substituted by install.sh's
# compile_entrypoint global substring substitution. core/lifecycle.md's
# scaffold-template examples must NOT include literal `@@<UPPER>@@`
# placeholder syntax — the scaffolds use plain YAML, no install.sh tokens.
#
# Codex review of suggested broadening this scan to all framework
# prose files. That broader version was tested and found over-broad: tracked
# plans + spec docs + adapter docs legitimately DISCUSS @@TOKEN@@ as a
# documentation topic (e.g. install.sh substitution mechanic). The PR #29
# trap was specific to TEMPLATE INPUTS (harnesses/*/*.template.md) where a
# literal @@KNOWN_TOKEN@@ gets substituted unintentionally. install.sh's own
# build-output check (line 517: `unresolved @@PLACEHOLDER@@ tokens in build
# output`) catches the SUCCESS case at build time; this test is a defense
# for the NEW file core/lifecycle.md to prevent re-introducing the same trap
# in the canonical lifecycle vocab. A separate follow-on issue could explore
# a smarter template-input-only scan if the class re-surfaces.
_test_no_install_sh_placeholders_in_lifecycle_doc() {
  if [ ! -f "$REPO_ROOT/core/lifecycle.md" ]; then
    return 1  # impl missing
  fi
  if /usr/bin/grep -qE '@@[A-Z][A-Z0-9_]*@@' "$REPO_ROOT/core/lifecycle.md"; then
    return 1  # placeholder syntax present — install.sh global-substring would substitute
  fi
  return 0
}
if _test_no_install_sh_placeholders_in_lifecycle_doc; then
  _pass "core/lifecycle.md contains no install.sh @@TOKEN@@ placeholders"
else
  _fail "core/lifecycle.md contains no install.sh @@TOKEN@@ placeholders"
fi

# --- Test 10: duplicate-key coverage ---
# A frontmatter block with BOTH `lifecycle: bogus` AND `lifecycle: shipped`
# currently passes because the regex only needs one valid line. Per Codex
# review missing-test: pin this behavior with an explicit assertion.
#
# Decision: ACCEPT-AND-DOCUMENT — duplicate keys are a YAML degenerate case;
# the standard YAML parsing behavior is "last value wins". Our regex-based
# check (multi-line: ^lifecycle:[[:space:]]+VALID...$) is anchored per-line
# and grep -q exits 0 on first match — so the LAST line listed first wins
# in terms of detection but ANY valid line allows pass. Validate.sh's
# behavior matches "any valid lifecycle: line present = pass" which is
# documented here. If this becomes a real-world problem, the fix is to use
# a YAML parser (yq/awk-state-machine) instead of regex.
LIFECYCLE_DUPLICATE="docs/plans/.test-t83-duplicate-lifecycle-$$-${RANDOM:-x}.md"
cat > "$REPO_ROOT/$LIFECYCLE_DUPLICATE" <<'MD'
---
lifecycle: bogus-value
lifecycle: shipped
---

# Test fixture body
MD
git -C "$REPO_ROOT" add -f "$LIFECYCLE_DUPLICATE"
# Decision documented above: the regex-based check accepts the file IF any
# line is valid. Pin this behavior so a future "strict YAML parser" change is
# a conscious decision, not a silent regression.
assert_exit "validate.sh accepts file with a valid lifecycle: line even if a sibling line is bogus" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
git -C "$REPO_ROOT" rm -f --cached --quiet "$LIFECYCLE_DUPLICATE"
rm -f "$REPO_ROOT/$LIFECYCLE_DUPLICATE"

# --- Test 11: hypothetical directory README.md is excluded from enforcement ---
# Per Codex review missing-test: confirm the README skip applies to ANY
# in-scope dir, not just capabilities/. Inject docs/plans/README.md without
# lifecycle: → validate.sh must still pass.
LIFECYCLE_README="docs/plans/README.md.test-t83-$$-${RANDOM:-x}"
# Bypass the existing-README check by using a unique sentinel name, then
# rename to README.md transiently for the test.
LIFECYCLE_README_TGT="docs/plans/README.md"
if [ -f "$REPO_ROOT/$LIFECYCLE_README_TGT" ]; then
  # If a real README.md exists, skip this test — would clobber it.
  _pass "docs/plans/README.md exclusion test SKIPPED — pre-existing README"
else
  cat > "$REPO_ROOT/$LIFECYCLE_README_TGT" <<'MD'
# Test fixture — directory README, no lifecycle: key
MD
  git -C "$REPO_ROOT" add -f "$LIFECYCLE_README_TGT"
  assert_exit "validate.sh skips docs/plans/README.md from check_lifecycle" 0 -- \
    bash "$REPO_ROOT/scripts/validate.sh"
  git -C "$REPO_ROOT" rm -f --cached --quiet "$LIFECYCLE_README_TGT"
  rm -f "$REPO_ROOT/$LIFECYCLE_README_TGT"
fi
