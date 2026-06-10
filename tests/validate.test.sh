#!/usr/bin/env bash
# tests/validate.test.sh — forbidden-roots allowlist behavior.
#
# scripts/validate.sh's forbidden-roots scan must:
# 1. PASS when.claude/,.codex/,.agents/ are absent (baseline).
# 2. PASS when one of those dirs contains ONLY allowlisted children
# (worktrees/, settings.local.json) — Claude Code's EnterWorktree writes
# to.claude/worktrees/<name>/; a hard-reject false-positives every
# worktree-using session and forces gates to run from inside a worktree
# only, masking real failures.
# 3. FAIL with a clear message when one contains a hand-edited child outside
# the allowlist (the bug this issue closes).
#
# Tests INJECT into $REPO_ROOT/.claude/ with uniquely-suffixed sentinel names
# and clean up inline (NOT trap EXIT — tests/run.sh sources files, so traps
# would persist across siblings). The rmdir-on-empty-dir pattern preserves
# any pre-existing $REPO_ROOT/.claude/ content the harness owns (worktrees
# the test runner is itself inside, settings.local.json, etc.).

# --- Test 1: baseline — validate passes from $REPO_ROOT with no.claude/ ---
# Inside the worktree, $REPO_ROOT/.claude/ does not exist (the harness
# state lives in the MAIN repo's.claude/, above the worktree). This is a
# clean baseline of "no harness-config dir present".
assert_exit "validate.sh passes from \$REPO_ROOT" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"

# --- Test 2: hand-edit-only child rejected ---
# Differentiator under current code: validate FAILs because.claude/ exists at
# all. After the fix: validate FAILs because the sentinel is not in the
# allowlist. Both exit 1 — this test catches regressions, not the bug.
VAL_HAND_EDIT=".test-que60-hand-edit-$$-${RANDOM:-x}"
mkdir -p "$REPO_ROOT/.claude"
printf 'simulated hand-edit\n' > "$REPO_ROOT/.claude/$VAL_HAND_EDIT"
assert_exit "validate.sh fails on a non-allowlisted child in .claude/" 1 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
rm -f "$REPO_ROOT/.claude/$VAL_HAND_EDIT"
rmdir "$REPO_ROOT/.claude" 2>/dev/null || true

# --- Test 3:.claude/worktrees/ as the only child must PASS (KEY BUG FIX) ---
# Before the fix: validate FAILs (existence is enough to reject) — RED.
# After the fix: worktrees/ is allowlisted → PASS — GREEN.
mkdir -p "$REPO_ROOT/.claude/worktrees/.test-que60-fake-worktree"
assert_exit "validate.sh passes when .claude/ has only worktrees/" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
rm -rf "$REPO_ROOT/.claude/worktrees/.test-que60-fake-worktree"
rmdir "$REPO_ROOT/.claude/worktrees" 2>/dev/null || true
rmdir "$REPO_ROOT/.claude" 2>/dev/null || true

# --- Test 4:.claude/settings.local.json as the only child must PASS ---
# Before the fix: FAIL. After: PASS (settings.local.json allowlisted). RED→GREEN.
# F-2 amendment (cross-model review, Gemini): settings.local.json is a real
# harness-managed file. If a real one exists at $REPO_ROOT/.claude/, skip
# rather than overwrite-and-delete it — the inline `rm -f` cleanup would
# silently destroy genuine local-override config otherwise.
if [ -e "$REPO_ROOT/.claude/settings.local.json" ]; then
  _skip "validate.sh passes when .claude/ has only settings.local.json" \
    "real settings.local.json present at \$REPO_ROOT/.claude/ — refusing to overwrite"
else
  mkdir -p "$REPO_ROOT/.claude"
  printf '{}\n' > "$REPO_ROOT/.claude/settings.local.json"
  assert_exit "validate.sh passes when .claude/ has only settings.local.json" 0 -- \
    bash "$REPO_ROOT/scripts/validate.sh"
  rm -f "$REPO_ROOT/.claude/settings.local.json"
  rmdir "$REPO_ROOT/.claude" 2>/dev/null || true
fi

# --- Tests 4a-4f: per-project Claude Code convention files must FAIL ---
# narrows the allowlist back from 4 entries to 2: only worktrees/ and
# settings.local.json (framework-development workflow state) are permitted at
# the agentic-os-template repo root. Per-project Claude Code conventions like CLAUDE.md
# and settings.json represent OPERATOR state — they belong in
# $CLAUDE_CONFIG_DIR (or $CODEX_HOME for.codex/), never in a framework repo
# root. PR #10's widening (which allowed them) was a workaround for an
# operator-tool's install path issue (historical context — codegraph,
# unwired from the framework; the boundary rationale is harness-
# agnostic and stands independently). This block expects FAIL across all
# three harness dirs to enforce the boundary uniformly.
#
# Skip-if-real preserves the F-2 discipline: never overwrite real
# operator-managed state. (After Task 2's one-time stray-file cleanup,
# claude/CLAUDE.md + settings.json should be absent and tests will run.)
for ct_dir in "$REPO_ROOT/.claude" "$REPO_ROOT/.codex" "$REPO_ROOT/.agents"; do
  ct_base="$(basename "$ct_dir")"
  for cc_name in "CLAUDE.md" "settings.json"; do
    cc_target="$ct_dir/$cc_name"
    if [ -e "$cc_target" ]; then
      _skip "validate.sh fails when ${ct_base}/ has only $cc_name" \
        "real $cc_name present at \$REPO_ROOT/${ct_base}/ — refusing to overwrite"
      continue
    fi
    mkdir -p "$ct_dir"
    printf '# test fixture\n' > "$cc_target"
    # F-1 (cross-model review, Codex): assert both exit + message content.
    # The spec's behavior matrix says these scenarios FAIL "with hand-edit
    # message" — a regression that changed validate.sh's stderr text but
    # kept exit=1 would silently violate that. Pattern mirrors Tests 4g-4i.
    val_he_output="$(bash "$REPO_ROOT/scripts/validate.sh" 2>&1)" \
      && val_he_exit=0 || val_he_exit=$?
    rm -f "$cc_target"
    rmdir "$ct_dir" 2>/dev/null || true
    assert_eq "validate.sh exits 1 when ${ct_base}/ has only $cc_name" \
      "1" "$val_he_exit"
    assert_contains "validate.sh ${ct_base}/$cc_name message says 'hand-edit'" \
      "$val_he_output" "hand-edit"
  done
done

# --- Tests 4g-4i: skills/ at repo root rejected with security-flavored
# message ---
# claude/skills/ is the auto-load attack surface finding #8
# (see reference_clone_time_claude_skills): a.claude/skills/ subtree
# present in Claude Code's cwd is silently loaded into the session
# without prompting. Letting it pass validation would weaken that
# defense. The precheck fires BEFORE the generic hand-edit branch
# so the operator sees the security framing.
#
# Same skip-if-real discipline as Tests 4a-4f — real-state preservation
# > test coverage.
for ct_dir in "$REPO_ROOT/.claude" "$REPO_ROOT/.codex" "$REPO_ROOT/.agents"; do
  ct_base="$(basename "$ct_dir")"
  if [ -e "$ct_dir/skills" ]; then
    _skip "validate.sh rejects ${ct_base}/skills/ with security message" \
      "real ${ct_base}/skills/ present at \$REPO_ROOT — refusing to overwrite"
    continue
  fi
  mkdir -p "$ct_dir/skills/.test-que70-fake-skill-$$-${RANDOM:-x}"
  val_skills_output="$(bash "$REPO_ROOT/scripts/validate.sh" 2>&1)" \
    && val_skills_exit=0 || val_skills_exit=$?
  rm -rf "$ct_dir/skills"
  rmdir "$ct_dir" 2>/dev/null || true
  assert_eq "validate.sh exits 1 on ${ct_base}/skills/" \
    "1" "$val_skills_exit"
  assert_contains "validate.sh ${ct_base}/skills/ message says 'security'" \
    "$val_skills_output" "security"
  assert_contains "validate.sh ${ct_base}/skills/ message names the remediation path" \
    "$val_skills_output" "never in a framework repo root"
done

# --- Test 5: mixed (worktrees/ + hand-edit) must FAIL ---
# Regression: both pre and post fix → FAIL.
mkdir -p "$REPO_ROOT/.claude/worktrees/.test-que60-fake-worktree"
VAL_MIXED_EDIT=".test-que60-mixed-$$-${RANDOM:-x}"
printf 'mixed hand-edit\n' > "$REPO_ROOT/.claude/$VAL_MIXED_EDIT"
assert_exit "validate.sh fails on mixed .claude/ (worktrees + hand-edit)" 1 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
rm -f "$REPO_ROOT/.claude/$VAL_MIXED_EDIT"
rm -rf "$REPO_ROOT/.claude/worktrees/.test-que60-fake-worktree"
rmdir "$REPO_ROOT/.claude/worktrees" 2>/dev/null || true
rmdir "$REPO_ROOT/.claude" 2>/dev/null || true

# --- Test 6: failure message surfaces the leaked path (diagnostic) ---
# Before the fix: message is "forbidden local or legacy artifact present:
# path/.claude" — no per-child detail. After: message lists the actual
# hand-edited path so the operator knows what to move/delete.
mkdir -p "$REPO_ROOT/.claude"
VAL_DIAG_NAME=".test-que60-diag-$$-${RANDOM:-x}"
printf 'diag content\n' > "$REPO_ROOT/.claude/$VAL_DIAG_NAME"
val_output="$(bash "$REPO_ROOT/scripts/validate.sh" 2>&1)" && val_exit=0 || val_exit=$?
rm -f "$REPO_ROOT/.claude/$VAL_DIAG_NAME"
rmdir "$REPO_ROOT/.claude" 2>/dev/null || true
assert_eq "validate.sh exits 1 on diag-name injection" "1" "$val_exit"
assert_contains "validate.sh failure surfaces leaked path" "$val_output" "$VAL_DIAG_NAME"

# --- F-1 amendment (cross-model review, Gemini+Codex agreed): coverage for
# codex/ and.agents/ ---
# scripts/validate.sh loops over all three harness-config dirs identically.
# The.claude/ branch is exhaustively covered above; the other two are
# textually equivalent but should at least have a hand-edit-reject test to
# catch a regression that affects only their loop iteration. Skip-if-real
# mirrors the F-2 discipline: real-state preservation > test coverage.
for ct_dir in "$REPO_ROOT/.codex" "$REPO_ROOT/.agents"; do
  ct_base="$(basename "$ct_dir")"
  if [ -e "$ct_dir" ]; then
    _skip "validate.sh fails on hand-edit in ${ct_base}/" \
      "real ${ct_base}/ present at \$REPO_ROOT — refusing to inject"
    continue
  fi
  CT_INJECT=".test-que60-${ct_base}-$$-${RANDOM:-x}"
  mkdir -p "$ct_dir"
  printf 'simulated hand-edit\n' > "$ct_dir/$CT_INJECT"
  assert_exit "validate.sh fails on hand-edit in ${ct_base}/" 1 -- \
    bash "$REPO_ROOT/scripts/validate.sh"
  rm -f "$ct_dir/$CT_INJECT"
  rmdir "$ct_dir" 2>/dev/null || true
done

# --- other scans must prune harness-managed worktrees ---
# After the forbidden-roots check allowlists.claude/worktrees/, but
# the earlier.DS_Store scan (validate.sh:9-13) and the recursive secret-
# pattern scan (validate.sh:71-73) still walked into the worktree subtree. A
# real worktree can contain.DS_Store (macOS Finder writes one in any opened
# dir) or test fixtures whose strings match the secret regex (e.g., sk-...
# mock data inside an unrelated worktree). Each scan must prune the
# {claude,codex,agents}/worktrees/ subtree. Sentinel-named injections live
# inside an explicit.test-que61-* dir so they cannot collide with a real
# worktree even when the test runs from main.

# Test 7:.DS_Store inside.claude/worktrees/<name>/ must NOT trip validate.
VAL_QUE61_WT=".test-que61-fake-wt-$$-${RANDOM:-x}"
mkdir -p "$REPO_ROOT/.claude/worktrees/$VAL_QUE61_WT"
touch "$REPO_ROOT/.claude/worktrees/$VAL_QUE61_WT/.DS_Store"
assert_exit "validate.sh ignores .DS_Store inside .claude/worktrees/" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
rm -rf "$REPO_ROOT/.claude/worktrees/$VAL_QUE61_WT"
rmdir "$REPO_ROOT/.claude/worktrees" 2>/dev/null || true
rmdir "$REPO_ROOT/.claude" 2>/dev/null || true

# Test 8: secret-shaped fixture inside.claude/worktrees/<name>/ must NOT
# trip the secret-pattern scan. The planted file matches validate.sh's
# regex; it lives inside worktree-managed (non-framework) content where a
# real fixture might legitimately exist. The secret is CONSTRUCTED at
# runtime — never written as a literal in the source — so this test file
# itself does not match validate.sh's grep when validate scans tests/.
VAL_QUE61_SEC=".test-que61-sec-$$-${RANDOM:-x}"
mkdir -p "$REPO_ROOT/.claude/worktrees/$VAL_QUE61_SEC"
val_que61_prefix='sk-'
val_que61_body='fakefake1234567890_abcdefghij_test'
printf '%s%s\n' "$val_que61_prefix" "$val_que61_body" > \
  "$REPO_ROOT/.claude/worktrees/$VAL_QUE61_SEC/fixture-secret.txt"
unset val_que61_prefix val_que61_body
assert_exit "validate.sh ignores secret-shaped strings inside .claude/worktrees/" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
rm -rf "$REPO_ROOT/.claude/worktrees/$VAL_QUE61_SEC"
rmdir "$REPO_ROOT/.claude/worktrees" 2>/dev/null || true
rmdir "$REPO_ROOT/.claude" 2>/dev/null || true

# F-B amendment (cross-model review, Codex+Gemini agreed): parallel coverage
# for.codex/worktrees/ and.agents/worktrees/. scripts/validate.sh's
# DS_Store + secret scans exclude all three harness-managed worktree
# subtrees (.claude,.codex,.agents) — tests above exercise the.claude
# branch exhaustively; this loop adds skip-if-real.DS_Store + secret
# coverage for the sibling branches. Mirrors the F-1 F-1 amendment
# discipline (lines 92-113): real-state preservation > test coverage.
for ct_dir in "$REPO_ROOT/.codex" "$REPO_ROOT/.agents"; do
  ct_base="$(basename "$ct_dir")"
  if [ -e "$ct_dir" ]; then
    _skip "validate.sh ignores .DS_Store inside ${ct_base}/worktrees/" \
      "real ${ct_base}/ present at \$REPO_ROOT — refusing to inject"
    _skip "validate.sh ignores secret-shaped strings inside ${ct_base}/worktrees/" \
      "real ${ct_base}/ present at \$REPO_ROOT — refusing to inject"
    continue
  fi
  # DS_Store inside the sibling harness's worktrees subtree
  CT_WT_NAME=".test-que61-fb-wt-${ct_base}-$$-${RANDOM:-x}"
  mkdir -p "$ct_dir/worktrees/$CT_WT_NAME"
  touch "$ct_dir/worktrees/$CT_WT_NAME/.DS_Store"
  assert_exit "validate.sh ignores .DS_Store inside ${ct_base}/worktrees/" 0 -- \
    bash "$REPO_ROOT/scripts/validate.sh"
  rm -rf "$ct_dir/worktrees/$CT_WT_NAME"
  # Secret-shaped fixture inside the sibling harness's worktrees subtree.
  # Same runtime-construction discipline as the.claude/ case.
  CT_SEC_NAME=".test-que61-fb-sec-${ct_base}-$$-${RANDOM:-x}"
  mkdir -p "$ct_dir/worktrees/$CT_SEC_NAME"
  val_que61fb_prefix='sk-'
  val_que61fb_body='fakefake1234567890_abcdefghij_test'
  printf '%s%s\n' "$val_que61fb_prefix" "$val_que61fb_body" > \
    "$ct_dir/worktrees/$CT_SEC_NAME/fixture-secret.txt"
  unset val_que61fb_prefix val_que61fb_body
  assert_exit "validate.sh ignores secret-shaped strings inside ${ct_base}/worktrees/" 0 -- \
    bash "$REPO_ROOT/scripts/validate.sh"
  rm -rf "$ct_dir/worktrees/$CT_SEC_NAME"
  rmdir "$ct_dir/worktrees" 2>/dev/null || true
  rmdir "$ct_dir" 2>/dev/null || true
done

# --- secret-pattern scan catches a secret in a non-harness
# worktrees/ dir — re-premised on COMMITTABILITY ---
# Pre-fix: validate.sh used --exclude-dir=worktrees, a blanket name-match that
# skipped ANY dir named worktrees — a silent blind spot. path-anchored the
# scan to the three harness worktrees only.
#
# the scan now enumerates the COMMITTABLE set (git ls-files --cached
# --others --exclude-standard). `.gitignore` ignores `worktrees/` globally, so an
# UNTRACKED fixture under tests/fixtures/.../worktrees/ is uncommittable → pruned
# → can never leak via a commit, so it is correctly out of scope. The meaningful
# case is a TRACKED file in such a dir: it CAN be committed, so it MUST be
# scanned. force-add the fixture so the "non-harness worktrees/ IS scanned"
# assertion stays meaningful — committability, not path, is now the criterion.
#
# Sentinel is runtime-constructed (per [[feedback_self_tripping_test_source]])
# so this test source doesn't self-trip when validate.sh scans tests/. The index
# is reset in cleanup so the force-added fixture leaves no staged orphan.
VAL_QUE66_FA_PARENT="tests/fixtures/que66-fa-$$-${RANDOM:-x}"
VAL_QUE66_FA_DIR="$VAL_QUE66_FA_PARENT/worktrees"
mkdir -p "$REPO_ROOT/$VAL_QUE66_FA_DIR"
val_que66fa_prefix='sk-'
val_que66fa_body='fakefake1234567890_abcdefghij_test'
printf '%s%s\n' "$val_que66fa_prefix" "$val_que66fa_body" > \
  "$REPO_ROOT/$VAL_QUE66_FA_DIR/secret.txt"
unset val_que66fa_prefix val_que66fa_body
git -C "$REPO_ROOT" add -f "$VAL_QUE66_FA_DIR/secret.txt" >/dev/null 2>&1
assert_exit "validate.sh catches secrets in a tracked non-harness worktrees/ dir" 1 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
git -C "$REPO_ROOT" reset -q -- "$VAL_QUE66_FA_DIR/secret.txt" 2>/dev/null || true
rm -rf "$REPO_ROOT/$VAL_QUE66_FA_PARENT"

# --- gitignored runtime-artifact dir cross-model-out/ pruned from the
# secret-pattern scan ---
# cross-model-out/ holds cross-model-review per-run output (codex-stdout.log,
# codex-review.md,...). It is gitignored runtime state that can never enter git,
# so validate.sh must not scan it for secrets — a real log/review quoting a long
# kebab-case identifier embeds an `sk-`-prefixed run matching the secret regex
# and false-fails validate on an otherwise-clean tree (the bug this closes). The
# scan now drops matches under cross-model-out/ via the same repo-root-anchored
# post-filter uses for.claude/worktrees/, extended to the gitignored
# runtime dirs. Mirrors the.claude/worktrees/ secret test.
#
# The sentinel lands in a representative non-log cross-model artifact
# (codex-review.md) to assert the cross-model-out DIRECTORY is pruned for ANY
# file under it (the anchored post-filter), not just *.log. The secret is
# CONSTRUCTED at runtime (never a source literal) per
# [[feedback_self_tripping_test_source]] so this test file does not itself match
# validate.sh's grep when validate scans tests/.
VAL_QUE244_DIR="cross-model-out/.test-que244-$$-${RANDOM:-x}"
mkdir -p "$REPO_ROOT/$VAL_QUE244_DIR"
val_que244_prefix='sk-'
val_que244_body='fakefake1234567890_abcdefghij_test'
printf '%s%s\n' "$val_que244_prefix" "$val_que244_body" > \
  "$REPO_ROOT/$VAL_QUE244_DIR/codex-review.md"
unset val_que244_prefix val_que244_body
assert_exit "validate.sh ignores secret-shaped strings inside cross-model-out/" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
rm -rf "$REPO_ROOT/$VAL_QUE244_DIR"
# rmdir only if empty — preserve any real cross-model-out/ the operator owns.
rmdir "$REPO_ROOT/cross-model-out" 2>/dev/null || true

# anchoring regression guard (adversarial cross-model finding F3): the
# exclusion is ROOT-ANCHORED, so a COMMITTABLE sibling whose name merely STARTS
# with "cross-model-out" (e.g. cross-model-out-archive/) is NOT gitignored and
# MUST still be scanned. A prefix match (StartsWith without a separator, or a
# loose post-filter) would silently skip it — a real secret-scan blind spot.
# The dir lives at repo root because the prefix collision only arises at the
# excluded root's own level. Sentinel constructed at runtime.
VAL_QUE244_SIB="cross-model-out-.test-que244-sib-$$-${RANDOM:-x}"
mkdir -p "$REPO_ROOT/$VAL_QUE244_SIB"
val_que244sib_prefix='sk-'
val_que244sib_body='fakefake1234567890_abcdefghij_test'
printf '%s%s\n' "$val_que244sib_prefix" "$val_que244sib_body" > \
  "$REPO_ROOT/$VAL_QUE244_SIB/secret.txt"
unset val_que244sib_prefix val_que244sib_body
assert_exit "validate.sh still catches secrets in a cross-model-out* sibling dir" 1 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
rm -rf "$REPO_ROOT/$VAL_QUE244_SIB"

# --- a TRACKED file whose NAME matches a gitignore rule is still
# scanned ---
# Committable-set enumeration lists tracked files via `git ls-files --cached`
# regardless of.gitignore, so a force-added daemon.log /.mcp.json carrying a
# secret IS in scope. The rejected first-cut alternative — basename
# `--exclude=*.log` / `--exclude=.mcp.json` — would have SKIPPED these, a false
# negative on a committable secret. `.gitignore` ignores `*.log` and `.mcp.json`,
# so each fixture is force-added; the index is reset in cleanup (no staged
# orphan). Sentinels constructed at runtime per [[feedback_self_tripping_test_source]].
for val_q246_name in "fixture-que246-$$-${RANDOM:-x}.log" ".test-que246-$$-${RANDOM:-y}.mcp.json"; do
  val_q246_prefix='sk-'
  val_q246_body='fakefake1234567890_abcdefghij_test'
  printf '%s%s\n' "$val_q246_prefix" "$val_q246_body" > "$REPO_ROOT/$val_q246_name"
  unset val_q246_prefix val_q246_body
  git -C "$REPO_ROOT" add -f "$val_q246_name" >/dev/null 2>&1
  assert_exit "validate.sh scans a tracked gitignored-name file ($val_q246_name)" 1 -- \
    bash "$REPO_ROOT/scripts/validate.sh"
  git -C "$REPO_ROOT" reset -q -- "$val_q246_name" 2>/dev/null || true
  rm -f "$REPO_ROOT/$val_q246_name"
done
unset val_q246_name

# --- the committable-set scan still PASSES clean on the live tree.
# A direct positive guard that the enumeration didn't over-prune everything
# (e.g. a botched relSpec) into a vacuous pass-by-emptiness. ---
assert_exit "validate.sh passes clean on the committable set" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"

# --- secret scan FAILS CLOSED on a listed-but-unreadable file ---
# A committable file `git ls-files` enumerates but the scanner cannot read must
# FAIL the scan, never be silently skipped into a pass. Modeled here as a file
# staged via `git add -f` then removed from the worktree: it stays in the index
# (--cached) so it is still LISTED, but the path is absent on disk so grep cannot
# read it. The bash twin already fails closed via grep's exit-2 tri-state; this
# pins that contract and is the parity sibling of validate-ps.test.ps1's new
# read-error-flag path (PS previously failed OPEN via -EA SilentlyContinue). A
# non-.md extension isolates the failure to the secret scan (the link/lifecycle
# checks ignore it). Index reset in cleanup so no staged orphan survives (per
# [[feedback_orphan_staged_fixtures]]); runs in CI / isolated worktree.
VAL_Q248_DEL="$REPO_ROOT/.test-que248-unreadable-$$-${RANDOM:-x}.txt"
if [ -e "$VAL_Q248_DEL" ]; then
  _skip "validate.sh fails closed on an unreadable listed file" "fixture collision: $VAL_Q248_DEL"
else
  printf 'placeholder\n' > "$VAL_Q248_DEL"
  git -C "$REPO_ROOT" add -f -- "$VAL_Q248_DEL" >/dev/null 2>&1
  rm -f "$VAL_Q248_DEL"
  assert_exit "validate.sh fails closed on an unreadable listed file" 1 -- \
    bash "$REPO_ROOT/scripts/validate.sh"
  git -C "$REPO_ROOT" reset -q -- "$VAL_Q248_DEL" >/dev/null 2>&1 || true
fi
unset VAL_Q248_DEL

# --- the root README secret exception is ROOT-EXACT, not basename
# Pre-fix the scan excluded README.md by basename (grep --exclude / ${f##*/}),
# so a nested docs/ or package README.md carrying a real token was a blind spot.
# A nested README with a secret MUST now be scanned -> FAIL. Sentinel constructed
# at runtime per [[feedback_self_tripping_test_source]]; fixture force-added
# (committable) then unstaged + removed. The unstage+remove is ALSO registered on
# INT/TERM (the bash analog of the PS twin's try/finally) so an interrupted or
# killed run cannot leave the force-added fixture orphaned in the index + on disk
# (the orphan-staged-fixture hazard). The trap is INT/TERM only (NOT EXIT — run.sh
# sources files, so an EXIT trap would persist across siblings per the header
# note) and is cleared immediately after the inline cleanup.
VAL_Q248_NEST="tests/fixtures/que248-nested-$$-${RANDOM:-x}"
trap 'git -C "$REPO_ROOT" reset -q -- "$VAL_Q248_NEST/README.md" >/dev/null 2>&1 || true; rm -rf "$REPO_ROOT/$VAL_Q248_NEST"' INT TERM
mkdir -p "$REPO_ROOT/$VAL_Q248_NEST"
val_q248_prefix='sk-'
val_q248_body='fakefake1234567890_abcdefghij_test'
printf 'value: %s%s\n' "$val_q248_prefix" "$val_q248_body" > "$REPO_ROOT/$VAL_Q248_NEST/README.md"
unset val_q248_prefix val_q248_body
git -C "$REPO_ROOT" add -f -- "$VAL_Q248_NEST/README.md" >/dev/null 2>&1
assert_exit "validate.sh scans a nested README.md for secrets" 1 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
git -C "$REPO_ROOT" reset -q -- "$VAL_Q248_NEST/README.md" >/dev/null 2>&1 || true
rm -rf "$REPO_ROOT/$VAL_Q248_NEST"
trap - INT TERM
unset VAL_Q248_NEST

# --- the ROOT README.md remains excepted (documented example
# key shapes). Appending a secret-shaped line to the repo-root README must NOT
# fail the scan. The restore is registered on INT/TERM (the bash analog of the PS
# twin's try/finally) so an interrupted or killed run cannot leak the
# secret-shaped sentinel into the tracked README.md — a leak would make this test
# _skip forever, since the guard below requires a clean README.md. The trap is
# INT/TERM only (NOT EXIT — run.sh sources files, so an EXIT trap would persist
# across siblings per the header note) and is cleared immediately after the
# inline restore. Guarded on the file being clean first so a dirty tree is never
# clobbered. Sentinel runtime-built.
if git -C "$REPO_ROOT" diff --quiet -- README.md 2>/dev/null; then
  trap 'git -C "$REPO_ROOT" checkout -- README.md >/dev/null 2>&1 || true' INT TERM
  val_q248r_prefix='sk-'
  val_q248r_body='fakefake1234567890_abcdefghij_test'
  printf 'value: %s%s\n' "$val_q248r_prefix" "$val_q248r_body" >> "$REPO_ROOT/README.md"
  unset val_q248r_prefix val_q248r_body
  assert_exit "validate.sh excepts a secret-shaped line in the ROOT README" 0 -- \
    bash "$REPO_ROOT/scripts/validate.sh"
  git -C "$REPO_ROOT" checkout -- README.md >/dev/null 2>&1 || true
  trap - INT TERM
else
  _skip "validate.sh excepts a secret-shaped line in the ROOT README" "README.md not clean"
fi
