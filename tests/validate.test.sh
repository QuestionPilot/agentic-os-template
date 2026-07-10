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

# <TEAM>-394: the FAIL-expecting injection tests below run against a hermetic
# tracked-only fixture copy, NOT $REPO_ROOT. In a co-located living home the
# real .claude/.codex are the operator's RECOGNIZED config dirs (and .agents an
# info/exclude-declared workspace), so validate rightly exempts them — an
# injected sentinel there can never produce the expected failure, and these
# tests were part of the standing false-failure set that made the living-home
# suite permanently red. The fixture has no co-location, no local.env, and no
# info/exclude, so every guard branch fires exactly as on a fresh clone.
VAL_GUARD_FIX="$(mktemp -d)"
copy_repo_tracked "$VAL_GUARD_FIX"

# --- Test 2: hand-edit-only child rejected ---
# Differentiator under current code: validate FAILs because.claude/ exists at
# all. After the fix: validate FAILs because the sentinel is not in the
# allowlist. Both exit 1 — this test catches regressions, not the bug.
VAL_HAND_EDIT=".test-t60-hand-edit-$$-${RANDOM:-x}"
mkdir -p "$VAL_GUARD_FIX/.claude"
printf 'simulated hand-edit\n' > "$VAL_GUARD_FIX/.claude/$VAL_HAND_EDIT"
assert_exit "validate.sh fails on a non-allowlisted child in .claude/" 1 -- \
  bash "$VAL_GUARD_FIX/scripts/validate.sh"
rm -f "$VAL_GUARD_FIX/.claude/$VAL_HAND_EDIT"
rmdir "$VAL_GUARD_FIX/.claude" 2>/dev/null || true

# --- Test 3:.claude/worktrees/ as the only child must PASS (KEY BUG FIX) ---
# Before the fix: validate FAILs (existence is enough to reject) — RED.
# After the fix: worktrees/ is allowlisted → PASS — GREEN.
mkdir -p "$REPO_ROOT/.claude/worktrees/.test-t60-fake-worktree"
assert_exit "validate.sh passes when .claude/ has only worktrees/" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
rm -rf "$REPO_ROOT/.claude/worktrees/.test-t60-fake-worktree"
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
# Runs in the hermetic guard fixture (<TEAM>-394): the fixture carries no real
# harness dirs, so no skip-if-real branch is needed and coverage holds even
# in a co-located living home where the real dirs are recognized/exempt.
for ct_dir in "$VAL_GUARD_FIX/.claude" "$VAL_GUARD_FIX/.codex" "$VAL_GUARD_FIX/.agents"; do
  ct_base="$(basename "$ct_dir")"
  for cc_name in "CLAUDE.md" "settings.json"; do
    cc_target="$ct_dir/$cc_name"
    mkdir -p "$ct_dir"
    printf '# test fixture\n' > "$cc_target"
    # F-1 (cross-model review, Codex): assert both exit + message content.
    # The spec's behavior matrix says these scenarios FAIL "with hand-edit
    # message" — a regression that changed validate.sh's stderr text but
    # kept exit=1 would silently violate that. Pattern mirrors Tests 4g-4i.
    val_he_output="$(bash "$VAL_GUARD_FIX/scripts/validate.sh" 2>&1)" \
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
  mkdir -p "$ct_dir/skills/.test-t70-fake-skill-$$-${RANDOM:-x}"
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

# --- Tests 4j-4l: a CO-LOCATED config dir is recognized, not rejected (<TEAM>-285) ---
# When the operator points CLAUDE_CONFIG_DIR at a repo-root .claude/ — running
# every harness out of the framework folder — that dir holds the harness's own
# compiled output + runtime state (gitignored, never committable). The root-guard
# must RECOGNIZE it and skip the reject, even with a skills/ subdir + settings.json
# that would otherwise trip the finding-#8 / hand-edit branches. The contrast
# (config dir pointing ELSEWHERE) still FAILS — proving the skip is gated on the
# physical-path match, not blanket-disabled. Skip-if-real: never co-opt a real
# $REPO_ROOT/.claude. Sentinels are uniquely suffixed; cleanup is inline.
if [ -e "$REPO_ROOT/.claude" ]; then
  _skip "validate.sh recognizes a co-located CLAUDE_CONFIG_DIR" \
    "real .claude/ present at \$REPO_ROOT — refusing to co-opt as a config target"
else
  mkdir -p "$REPO_ROOT/.claude/skills/.test-t285-skill-$$-${RANDOM:-x}"
  printf '{}\n' > "$REPO_ROOT/.claude/settings.json"
  # (a) config dir IS this .claude/ → recognized → PASS despite skills/ + settings.json
  assert_exit "validate.sh recognizes a co-located CLAUDE_CONFIG_DIR (skills/+settings.json PASS)" 0 -- \
    env CLAUDE_CONFIG_DIR="$REPO_ROOT/.claude" bash "$REPO_ROOT/scripts/validate.sh"
  # (b) config dir is a DIFFERENT existing dir → not recognized → still FAILS (finding #8)
  VAL_Q285_ELSEWHERE="$REPO_ROOT/.test-t285-elsewhere-$$-${RANDOM:-x}"
  mkdir -p "$VAL_Q285_ELSEWHERE"
  val_q285_out="$(env CLAUDE_CONFIG_DIR="$VAL_Q285_ELSEWHERE" bash "$REPO_ROOT/scripts/validate.sh" 2>&1)" \
    && val_q285_exit=0 || val_q285_exit=$?
  rmdir "$VAL_Q285_ELSEWHERE" 2>/dev/null || true
  assert_eq "validate.sh still FAILS a foreign repo-root .claude/skills/" "1" "$val_q285_exit"
  assert_contains "validate.sh foreign .claude/skills/ keeps the security message" \
    "$val_q285_out" "security"
  # Surgical cleanup — only what this block created (skip-if-real guaranteed .claude/ was absent).
  rm -rf "$REPO_ROOT/.claude/skills"
  rm -f "$REPO_ROOT/.claude/settings.json"
  rmdir "$REPO_ROOT/.claude" 2>/dev/null || true
  unset VAL_Q285_ELSEWHERE val_q285_out val_q285_exit
fi

# --- Test 5: mixed (worktrees/ + hand-edit) must FAIL ---
# Regression: both pre and post fix → FAIL. Hermetic guard fixture (<TEAM>-394).
mkdir -p "$VAL_GUARD_FIX/.claude/worktrees/.test-t60-fake-worktree"
VAL_MIXED_EDIT=".test-t60-mixed-$$-${RANDOM:-x}"
printf 'mixed hand-edit\n' > "$VAL_GUARD_FIX/.claude/$VAL_MIXED_EDIT"
assert_exit "validate.sh fails on mixed .claude/ (worktrees + hand-edit)" 1 -- \
  bash "$VAL_GUARD_FIX/scripts/validate.sh"
rm -f "$VAL_GUARD_FIX/.claude/$VAL_MIXED_EDIT"
rm -rf "$VAL_GUARD_FIX/.claude/worktrees/.test-t60-fake-worktree"
rmdir "$VAL_GUARD_FIX/.claude/worktrees" 2>/dev/null || true
rmdir "$VAL_GUARD_FIX/.claude" 2>/dev/null || true

# --- Test 6: failure message surfaces the leaked path (diagnostic) ---
# Before the fix: message is "forbidden local or legacy artifact present:
# path/.claude" — no per-child detail. After: message lists the actual
# hand-edited path so the operator knows what to move/delete.
mkdir -p "$VAL_GUARD_FIX/.claude"
VAL_DIAG_NAME=".test-t60-diag-$$-${RANDOM:-x}"
printf 'diag content\n' > "$VAL_GUARD_FIX/.claude/$VAL_DIAG_NAME"
val_output="$(bash "$VAL_GUARD_FIX/scripts/validate.sh" 2>&1)" && val_exit=0 || val_exit=$?
rm -f "$VAL_GUARD_FIX/.claude/$VAL_DIAG_NAME"
rmdir "$VAL_GUARD_FIX/.claude" 2>/dev/null || true
assert_eq "validate.sh exits 1 on diag-name injection" "1" "$val_exit"
assert_contains "validate.sh failure surfaces leaked path" "$val_output" "$VAL_DIAG_NAME"

# --- F-1 amendment (cross-model review, Gemini+Codex agreed): coverage for
# codex/ and.agents/ ---
# scripts/validate.sh loops over all three harness-config dirs identically.
# The.claude/ branch is exhaustively covered above; the other two are
# textually equivalent but should at least have a hand-edit-reject test to
# catch a regression that affects only their loop iteration. Runs in the
# hermetic guard fixture (<TEAM>-394), so no skip-if-real branch is needed.
for ct_dir in "$VAL_GUARD_FIX/.codex" "$VAL_GUARD_FIX/.agents"; do
  ct_base="$(basename "$ct_dir")"
  CT_INJECT=".test-t60-${ct_base}-$$-${RANDOM:-x}"
  mkdir -p "$ct_dir"
  printf 'simulated hand-edit\n' > "$ct_dir/$CT_INJECT"
  assert_exit "validate.sh fails on hand-edit in ${ct_base}/" 1 -- \
    bash "$VAL_GUARD_FIX/scripts/validate.sh"
  rm -f "$ct_dir/$CT_INJECT"
  rmdir "$ct_dir" 2>/dev/null || true
done
# Guard-fixture teardown — the fixture-scoped injection tests end here.
rm -rf "$VAL_GUARD_FIX"
unset VAL_GUARD_FIX

# --- other scans must prune harness-managed worktrees ---
# After the forbidden-roots check allowlists.claude/worktrees/, but
# the earlier.DS_Store scan (validate.sh:9-13) and the recursive secret-
# pattern scan (validate.sh:71-73) still walked into the worktree subtree. A
# real worktree can contain.DS_Store (macOS Finder writes one in any opened
# dir) or test fixtures whose strings match the secret regex (e.g., sk-...
# mock data inside an unrelated worktree). Each scan must prune the
# {claude,codex,agents}/worktrees/ subtree. Sentinel-named injections live
# inside an explicit.test-t61-* dir so they cannot collide with a real
# worktree even when the test runs from main.

# Test 7:.DS_Store inside.claude/worktrees/<name>/ must NOT trip validate.
VAL_T61_WT=".test-t61-fake-wt-$$-${RANDOM:-x}"
mkdir -p "$REPO_ROOT/.claude/worktrees/$VAL_T61_WT"
touch "$REPO_ROOT/.claude/worktrees/$VAL_T61_WT/.DS_Store"
assert_exit "validate.sh ignores .DS_Store inside .claude/worktrees/" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
rm -rf "$REPO_ROOT/.claude/worktrees/$VAL_T61_WT"
rmdir "$REPO_ROOT/.claude/worktrees" 2>/dev/null || true
rmdir "$REPO_ROOT/.claude" 2>/dev/null || true

# Test 8: secret-shaped fixture inside.claude/worktrees/<name>/ must NOT
# trip the secret-pattern scan. The planted file matches validate.sh's
# regex; it lives inside worktree-managed (non-framework) content where a
# real fixture might legitimately exist. The secret is CONSTRUCTED at
# runtime — never written as a literal in the source — so this test file
# itself does not match validate.sh's grep when validate scans tests/.
VAL_T61_SEC=".test-t61-sec-$$-${RANDOM:-x}"
mkdir -p "$REPO_ROOT/.claude/worktrees/$VAL_T61_SEC"
val_t61_prefix='sk-'
val_t61_body='fakefake1234567890_abcdefghij_test'
printf '%s%s\n' "$val_t61_prefix" "$val_t61_body" > \
  "$REPO_ROOT/.claude/worktrees/$VAL_T61_SEC/fixture-secret.txt"
unset val_t61_prefix val_t61_body
assert_exit "validate.sh ignores secret-shaped strings inside .claude/worktrees/" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
rm -rf "$REPO_ROOT/.claude/worktrees/$VAL_T61_SEC"
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
  CT_WT_NAME=".test-t61-fb-wt-${ct_base}-$$-${RANDOM:-x}"
  mkdir -p "$ct_dir/worktrees/$CT_WT_NAME"
  touch "$ct_dir/worktrees/$CT_WT_NAME/.DS_Store"
  assert_exit "validate.sh ignores .DS_Store inside ${ct_base}/worktrees/" 0 -- \
    bash "$REPO_ROOT/scripts/validate.sh"
  rm -rf "$ct_dir/worktrees/$CT_WT_NAME"
  # Secret-shaped fixture inside the sibling harness's worktrees subtree.
  # Same runtime-construction discipline as the.claude/ case.
  CT_SEC_NAME=".test-t61-fb-sec-${ct_base}-$$-${RANDOM:-x}"
  mkdir -p "$ct_dir/worktrees/$CT_SEC_NAME"
  val_t61fb_prefix='sk-'
  val_t61fb_body='fakefake1234567890_abcdefghij_test'
  printf '%s%s\n' "$val_t61fb_prefix" "$val_t61fb_body" > \
    "$ct_dir/worktrees/$CT_SEC_NAME/fixture-secret.txt"
  unset val_t61fb_prefix val_t61fb_body
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
VAL_T66_FA_PARENT="tests/fixtures/t66-fa-$$-${RANDOM:-x}"
VAL_T66_FA_DIR="$VAL_T66_FA_PARENT/worktrees"
mkdir -p "$REPO_ROOT/$VAL_T66_FA_DIR"
val_t66fa_prefix='sk-'
val_t66fa_body='fakefake1234567890_abcdefghij_test'
printf '%s%s\n' "$val_t66fa_prefix" "$val_t66fa_body" > \
  "$REPO_ROOT/$VAL_T66_FA_DIR/secret.txt"
unset val_t66fa_prefix val_t66fa_body
git -C "$REPO_ROOT" add -f "$VAL_T66_FA_DIR/secret.txt" >/dev/null 2>&1
assert_exit "validate.sh catches secrets in a tracked non-harness worktrees/ dir" 1 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
git -C "$REPO_ROOT" reset -q -- "$VAL_T66_FA_DIR/secret.txt" 2>/dev/null || true
rm -rf "$REPO_ROOT/$VAL_T66_FA_PARENT"

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
VAL_T244_DIR="cross-model-out/.test-t244-$$-${RANDOM:-x}"
mkdir -p "$REPO_ROOT/$VAL_T244_DIR"
val_t244_prefix='sk-'
val_t244_body='fakefake1234567890_abcdefghij_test'
printf '%s%s\n' "$val_t244_prefix" "$val_t244_body" > \
  "$REPO_ROOT/$VAL_T244_DIR/codex-review.md"
unset val_t244_prefix val_t244_body
assert_exit "validate.sh ignores secret-shaped strings inside cross-model-out/" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
rm -rf "$REPO_ROOT/$VAL_T244_DIR"
# rmdir only if empty — preserve any real cross-model-out/ the operator owns.
rmdir "$REPO_ROOT/cross-model-out" 2>/dev/null || true

# anchoring regression guard (adversarial cross-model finding F3): the
# exclusion is ROOT-ANCHORED, so a COMMITTABLE sibling whose name merely STARTS
# with "cross-model-out" (e.g. cross-model-out-archive/) is NOT gitignored and
# MUST still be scanned. A prefix match (StartsWith without a separator, or a
# loose post-filter) would silently skip it — a real secret-scan blind spot.
# The dir lives at repo root because the prefix collision only arises at the
# excluded root's own level. Sentinel constructed at runtime.
VAL_T244_SIB="cross-model-out-.test-t244-sib-$$-${RANDOM:-x}"
mkdir -p "$REPO_ROOT/$VAL_T244_SIB"
val_t244sib_prefix='sk-'
val_t244sib_body='fakefake1234567890_abcdefghij_test'
printf '%s%s\n' "$val_t244sib_prefix" "$val_t244sib_body" > \
  "$REPO_ROOT/$VAL_T244_SIB/secret.txt"
unset val_t244sib_prefix val_t244sib_body
assert_exit "validate.sh still catches secrets in a cross-model-out* sibling dir" 1 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
rm -rf "$REPO_ROOT/$VAL_T244_SIB"

# --- a TRACKED file whose NAME matches a gitignore rule is still
# scanned ---
# Committable-set enumeration lists tracked files via `git ls-files --cached`
# regardless of.gitignore, so a force-added daemon.log /.mcp.json carrying a
# secret IS in scope. The rejected first-cut alternative — basename
# `--exclude=*.log` / `--exclude=.mcp.json` — would have SKIPPED these, a false
# negative on a committable secret. `.gitignore` ignores `*.log` and `.mcp.json`,
# so each fixture is force-added; the index is reset in cleanup (no staged
# orphan). Sentinels constructed at runtime per [[feedback_self_tripping_test_source]].
for val_q246_name in "fixture-t246-$$-${RANDOM:-x}.log" ".test-t246-$$-${RANDOM:-y}.mcp.json"; do
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
VAL_Q248_DEL="$REPO_ROOT/.test-t248-unreadable-$$-${RANDOM:-x}.txt"
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
VAL_Q248_NEST="tests/fixtures/t248-nested-$$-${RANDOM:-x}"
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

# --- <TEAM>-319: the .DS_Store + embedded-.git scans honor the CO-LOCATED config
# dir exemption ---
# A co-located install (CLAUDE_CONFIG_DIR=$REPO_ROOT/.claude — running every
# harness out of the framework folder) keeps the harness's own gitignored
# runtime state under the repo-root config dir: plugin-marketplace clones that
# carry their OWN .git (.claude/plugins/marketplaces/*/.git,
# .codex/.tmp/plugins/.git) and Finder .DS_Store files. Before <TEAM>-319 the two
# early tree-walk scans (.DS_Store at validate.sh's top, embedded-.git just
# below) pruned only worktrees/ / cross-model-out/ / .codegraph/ — NOT the
# co-located config dirs — so `bash scripts/validate.sh` (and thus `make verify`)
# cascade-failed locally on an otherwise-clean tree. <TEAM>-319 hoists the
# co-located recognition the forbidden-artifacts guard already had (<TEAM>-285)
# above both scans.
#
# Inject into $REPO_ROOT/.hermes (skip-if-real) and drive recognition via
# HERMES_HOME so the test never touches the operator's real .claude/.codex. The
# contrast (HERMES_HOME pointing ELSEWHERE) must still FAIL — proving the
# exemption is gated on the physical-path match, not a blanket prune that would
# gut the scan. Sentinels are uniquely suffixed; cleanup is inline (NOT trap
# EXIT — run.sh sources files, so an EXIT trap persists across siblings).
if [ -e "$REPO_ROOT/.hermes" ]; then
  _skip "validate.sh exempts embedded .git in a co-located config dir" \
    "real .hermes/ present at \$REPO_ROOT — refusing to co-opt as a config target"
  _skip "validate.sh still FAILS embedded .git when config dir is elsewhere" \
    "real .hermes/ present at \$REPO_ROOT — refusing to co-opt as a config target"
  _skip "validate.sh exempts .DS_Store in a co-located config dir" \
    "real .hermes/ present at \$REPO_ROOT — refusing to co-opt as a config target"
  _skip "validate.sh still FAILS .DS_Store when config dir is elsewhere" \
    "real .hermes/ present at \$REPO_ROOT — refusing to co-opt as a config target"
else
  VAL_Q319_ELSEWHERE="$REPO_ROOT/.test-q319-elsewhere-$$-${RANDOM:-x}"
  mkdir -p "$VAL_Q319_ELSEWHERE"

  # Scenario A — embedded .git (a plugin clone's own .git dir).
  mkdir -p "$REPO_ROOT/.hermes/plugins/.test-q319-$$-${RANDOM:-g}/.git"
  # (a) HERMES_HOME IS this .hermes/ → recognized → pruned → PASS.
  assert_exit "validate.sh exempts embedded .git in a co-located config dir" 0 -- \
    env HERMES_HOME="$REPO_ROOT/.hermes" bash "$REPO_ROOT/scripts/validate.sh"
  # (b) HERMES_HOME elsewhere → not recognized → still FAILS on the embedded .git.
  val_q319_out="$(env HERMES_HOME="$VAL_Q319_ELSEWHERE" bash "$REPO_ROOT/scripts/validate.sh" 2>&1)" \
    && val_q319_exit=0 || val_q319_exit=$?
  assert_eq "validate.sh still FAILS embedded .git when config dir is elsewhere" \
    "1" "$val_q319_exit"
  assert_contains "validate.sh embedded-.git FAIL names the scan" \
    "$val_q319_out" "embedded .git"
  rm -rf "$REPO_ROOT/.hermes/plugins"

  # Scenario B — a Finder .DS_Store directly under the config dir.
  touch "$REPO_ROOT/.hermes/.DS_Store"
  # (a) recognized → pruned → PASS.
  assert_exit "validate.sh exempts .DS_Store in a co-located config dir" 0 -- \
    env HERMES_HOME="$REPO_ROOT/.hermes" bash "$REPO_ROOT/scripts/validate.sh"
  # (b) elsewhere → still FAILS on the .DS_Store.
  val_q319b_out="$(env HERMES_HOME="$VAL_Q319_ELSEWHERE" bash "$REPO_ROOT/scripts/validate.sh" 2>&1)" \
    && val_q319b_exit=0 || val_q319b_exit=$?
  assert_eq "validate.sh still FAILS .DS_Store when config dir is elsewhere" \
    "1" "$val_q319b_exit"
  assert_contains "validate.sh .DS_Store FAIL names the scan" \
    "$val_q319b_out" "DS_Store"
  # Clear the .hermes artifact before Scenario C so its assertion is unambiguous.
  rm -f "$REPO_ROOT/.hermes/.DS_Store"
  rmdir "$REPO_ROOT/.hermes" 2>/dev/null || true

  # Scenario C — a config var pointing at a NON-harness repo dir must NOT exempt.
  # Recognition is gated on a repo-root harness dir (.claude/.codex/.hermes)
  # physically equaling the config path — NOT on "any dir a config var points
  # at". A .DS_Store INSIDE the pointed-at non-harness dir must still FAIL. This
  # is the exact case the cross-model review caught the PS twin getting wrong
  # (it pruned under any configured path); this test locks bash↔PS parity on it.
  touch "$VAL_Q319_ELSEWHERE/.DS_Store"
  val_q319c_out="$(env HERMES_HOME="$VAL_Q319_ELSEWHERE" bash "$REPO_ROOT/scripts/validate.sh" 2>&1)" \
    && val_q319c_exit=0 || val_q319c_exit=$?
  assert_eq "validate.sh does NOT exempt a non-harness dir a config var points at" \
    "1" "$val_q319c_exit"
  assert_contains "validate.sh non-harness-cfg FAIL names the .DS_Store scan" \
    "$val_q319c_out" "DS_Store"
  rm -f "$VAL_Q319_ELSEWHERE/.DS_Store"

  # Surgical cleanup — only what this block created (skip-if-real guaranteed
  # .hermes/ was absent).
  rmdir "$VAL_Q319_ELSEWHERE" 2>/dev/null || true
  unset VAL_Q319_ELSEWHERE val_q319_out val_q319_exit val_q319b_out val_q319b_exit
  unset val_q319c_out val_q319c_exit
fi

# --- <TEAM>-328 Item B: the .DS_Store + embedded-.git tree-walk scans FAIL
# CLOSED on a find enumeration error ---
# Both early scans now capture find's exit status and FAIL on a non-zero instead
# of silently false-passing through an empty hit list (the prior
# `done < <(find ...)` form discarded find's status, so a permission-denied
# subtree or system limit read as "no hits -> PASS"). Provoke a real find
# failure with a mode-000 subdir at the repo root: find walks into it, errors,
# and exits non-zero. The .DS_Store scan runs first, so its fail-closed message
# is the one that surfaces; the embedded-.git scan immediately below applies the
# identical capture-and-fail pattern (it cannot be exercised independently — the
# same mode-000 dir trips the .DS_Store walk first). The PS twin
# (validate.test.ps1) mirrors this via -ErrorVariable.
#
# _skip when the unreadable dir can't actually block find — running as root
# (perms bypassed) or a filesystem that ignores mode 000 — so the test never
# false-passes where the failure can't be provoked. Restore + remove on INT/TERM
# (the bash analog of the PS twin's try/finally) so an interrupted run never
# orphans an unreadable dir in the live repo root; cleared after inline cleanup.
VAL_Q328_LOCK="$REPO_ROOT/.test-q328-locked-$$-${RANDOM:-x}"
if [ -e "$VAL_Q328_LOCK" ]; then
  _skip "validate.sh tree-walk scan fails closed on a find enumeration error" \
    "fixture collision: $VAL_Q328_LOCK"
elif [ "$(id -u)" = "0" ]; then
  _skip "validate.sh tree-walk scan fails closed on a find enumeration error" \
    "running as root — mode 000 does not block find"
else
  trap 'chmod 0755 "$VAL_Q328_LOCK" 2>/dev/null; rm -rf "$VAL_Q328_LOCK" 2>/dev/null' INT TERM
  mkdir -p "$VAL_Q328_LOCK/sub"
  chmod 000 "$VAL_Q328_LOCK"
  # Probe in THIS shell (same user as the validate.sh child): does mode 000
  # actually make find error here? If not, the gap can't be exercised → skip.
  if find "$VAL_Q328_LOCK" >/dev/null 2>&1; then
    _skip "validate.sh tree-walk scan fails closed on a find enumeration error" \
      "find does not error on the mode-000 dir on this filesystem"
  else
    val_q328_out="$(bash "$REPO_ROOT/scripts/validate.sh" 2>&1)" && val_q328_exit=0 || val_q328_exit=$?
    case "$val_q328_out" in *"enumeration errored"*) val_q328_msg=1 ;; *) val_q328_msg=0 ;; esac
    if [ "$val_q328_exit" = "1" ] && [ "$val_q328_msg" = "1" ]; then
      _pass "validate.sh tree-walk scan fails closed on a find enumeration error"
    else
      _fail "validate.sh tree-walk scan fails closed on a find enumeration error" \
        "expected exit 1 + 'enumeration errored', got exit $val_q328_exit" "$val_q328_out"
    fi
  fi
  chmod 0755 "$VAL_Q328_LOCK" 2>/dev/null
  rm -rf "$VAL_Q328_LOCK"
  trap - INT TERM
  unset val_q328_out val_q328_exit val_q328_msg
fi
unset VAL_Q328_LOCK

# --- local.env is parsed as DATA, never sourced/executed (<TEAM>-360) -----------
# validate.sh used to source local.env in three subshells to resolve the
# config-dir keys; a hostile or malformed local.env could execute arbitrary
# code from a validation entry point (self-audit.sh closed the same class with
# _sa_localenv_get). Two guards: (a) structural — no sourcing site remains;
# (b) functional — the shipped _v_le_* parser resolves composed/quoted/%q
# values while a command-substitution booby trap stays inert.
vle_src="$REPO_ROOT/scripts/validate.sh"
if grep -qE '\.[[:space:]]+"\$repo_root/local\.env"' "$vle_src"; then
  _fail "validate.sh has no local.env sourcing site" \
    "found a '. \$repo_root/local.env' sourcing site — local.env must be read as data"
else
  _pass "validate.sh has no local.env sourcing site"
fi

vle_tmp="$(mktemp -d)"
awk '/^_v_le_keys=\(\)/{f=1} f&&/^if \[ -f "\$repo_root\/local\.env" \]/{exit} f{print}' \
  "$vle_src" > "$vle_tmp/funcs.sh"
if [ -s "$vle_tmp/funcs.sh" ]; then
  _pass "validate.sh _v_le_* parser block extracted"
  vle_sentinel="$vle_tmp/pwn-sentinel"
  cat > "$vle_tmp/local.env" <<VLE_EOF
# hostile fixture — the command substitution below must stay inert data
PWNED=\$(touch $vle_sentinel)
BASE=/tmp/vle-base
CLAUDE_CONFIG_DIR=\$BASE/.claude
CODEX_HOME="/tmp/vle quoted/.codex"
HERMES_HOME=/tmp/vle\\ esc/.hermes
VLE_EOF
  vle_out="$(bash -c "set -euo pipefail; . '$vle_tmp/funcs.sh'; _v_le_parse '$vle_tmp/local.env'; printf '%s|%s|%s' \"\$(_v_le_get CLAUDE_CONFIG_DIR)\" \"\$(_v_le_get CODEX_HOME)\" \"\$(_v_le_get HERMES_HOME)\"" 2>/dev/null)"
  assert_eq "validate.sh parser resolves composed + quoted + %q-escaped config dirs" \
    "/tmp/vle-base/.claude|/tmp/vle quoted/.codex|/tmp/vle esc/.hermes" "$vle_out"
  if [ -f "$vle_sentinel" ]; then
    _fail "validate.sh local.env command substitution stays inert" \
      "sentinel file was created — local.env content EXECUTED"
  else
    _pass "validate.sh local.env command substitution stays inert"
  fi
else
  _fail "validate.sh _v_le_* parser block extracted" \
    "awk extraction found no _v_le_* block — did the parser move or get renamed?"
fi
rm -rf "$vle_tmp"
unset vle_src vle_tmp vle_out vle_sentinel

# --- <TEAM>-394: projects/ workspace junk must not trip the junk scans ---
# The shipped .gitignore declares projects/ the operator's local project
# workspace ("never tracked"); a real workspace holds whole checkouts, so a
# nested .git dir or a Finder .DS_Store there is operator content, not
# framework content. Pre-fix, `make validate` from a living co-located home
# failed on the workspace's own checkouts — 41 suite assertions fell to that
# one enumeration. Plants junk in the REAL repo's projects/ (gitignored) and
# expects validate to stay green, mirroring the Test-7 worktrees pattern.
VAL_T394="$REPO_ROOT/projects/.test-t394-$$"
mkdir -p "$VAL_T394/nested/.git"
touch "$VAL_T394/.DS_Store"
assert_exit "validate.sh ignores .DS_Store + nested .git under projects/ (operator workspace)" 0 -- \
  bash "$REPO_ROOT/scripts/validate.sh"
rm -rf "$VAL_T394"
unset VAL_T394

# --- <TEAM>-394: .git/info/exclude declares an operator harness workspace ---
# A repo-root harness dir with NO config variable (.agents/) is guarded by the
# finding-#8 skills reject on a fresh clone; an operator who excluded the dir
# in .git/info/exclude has made the explicit operator-state declaration, and
# validate recognizes exactly that source — never the shipped .gitignore, so
# the guard's fresh-clone posture is unchanged.
VIE_FIX="$(mktemp -d)"
copy_repo_tracked "$VIE_FIX"
git -C "$VIE_FIX" init -q .
mkdir -p "$VIE_FIX/.agents/skills"
printf 'fixture\n' > "$VIE_FIX/.agents/skills/SKILL.md"
assert_exit "validate.sh guards a repo-root .agents/skills with no local declaration" 1 -- \
  bash "$VIE_FIX/scripts/validate.sh"
printf '.agents/\n' >> "$VIE_FIX/.git/info/exclude"
assert_exit "validate.sh recognizes an info/exclude-declared harness workspace (.agents)" 0 -- \
  bash "$VIE_FIX/scripts/validate.sh"
# Panel F2 narrowing: the recognition applies to .agents ONLY. A .claude/skills
# with an info/exclude entry must STILL fail — .claude/skills/ is the actual
# finding-#8 auto-load surface and the harness loads it regardless of git
# ignore status; an ignore-based bypass there would gut the guard.
rm -rf "$VIE_FIX/.agents"
mkdir -p "$VIE_FIX/.claude/skills"
printf 'fixture\n' > "$VIE_FIX/.claude/skills/SKILL.md"
printf '.claude/\n' >> "$VIE_FIX/.git/info/exclude"
assert_exit "validate.sh still guards .claude/skills even when info/exclude'd (finding #8 kept)" 1 -- \
  bash "$VIE_FIX/scripts/validate.sh"
rm -rf "$VIE_FIX"
unset VIE_FIX
