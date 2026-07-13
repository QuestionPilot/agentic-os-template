#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/closeout-file-sweep.test.sh — invariants for the closeout
# file-sweep step + ## Files created this session output section.
#
# Spec: capabilities/closeout.md grows Q7 (file sweep) + a new output-block
# section between ## State Deltas and ## Running State; default-keep is
# forbidden; every created artifact gets keep-because-X / clean-now /
# clean-by-Y classification. core/self-improvement.md mirrors Q7 so the
# canonical-source-vs-capability lockstep holds. linear/closeout-format.md
# carries the same new section so the operator-facing template matches.
#
# Note: test files are SOURCED by tests/run.sh — do NOT set -e, exit, or
# re-source lib.sh; just call assert_*.

CL_PATH="$REPO_ROOT/capabilities/closeout.md"
SI_PATH="$REPO_ROOT/core/self-improvement.md"
LF_PATH="$REPO_ROOT/linear/closeout-format.md"

assert_file "capabilities/closeout.md exists" "$CL_PATH"
assert_file "core/self-improvement.md exists" "$SI_PATH"
assert_file "linear/closeout-format.md exists" "$LF_PATH"

CL_CONTENT="$(cat "$CL_PATH")"
SI_CONTENT="$(cat "$SI_PATH")"
LF_CONTENT="$(cat "$LF_PATH")"

# Local helper: line number of an exact heading match, or 0 if missing.
# Uses grep -nFx (line-number, fixed-string, full-line) — POSIX, BSD-grep safe.
# Mirrors the helper in tests/closeout-format.test.sh; redeclared so this
# file does not depend on source order across.test.sh files.
heading_line() {
  local n
  n=$(grep -nFx "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1)
  printf '%s\n' "${n:-0}"
}

# --- 1. capabilities/closeout.md — Q7 walk + frontmatter + summary count ----

# The walk grows to 8 questions (Q0..Q7). Both the walk-header prose AND the
# frontmatter summary must mirror the new count so the harness-skill router
# advertises the right number.
assert_contains "closeout.md walk header says 8 closeout questions" \
  "$CL_CONTENT" "The 8 closeout questions"
assert_contains "closeout.md frontmatter summary says 8 closeout questions" \
  "$CL_CONTENT" "walk the 8 closeout questions"

# Negative: no stale "7 closeout questions" substring anywhere in the file
# (matches the MT-1 pattern — guards against half-applied renumbering).
assert_not_contains "closeout.md has no stale '7 closeout questions' substring" \
  "$CL_CONTENT" "7 closeout questions"

# Q7 itself: the file-sweep question must appear with its canonical signal
# phrase ("File sweep") and the operator's directive language
# ("default-keep" is forbidden).
assert_contains "closeout.md walks Q7 File sweep" \
  "$CL_CONTENT" "File sweep"
assert_contains "closeout.md Q7 enumerates create-side surfaces" \
  "$CL_CONTENT" '`Write` / `Edit`'
assert_contains "closeout.md Q7 forbids default-keep" \
  "$CL_CONTENT" "Default-keep is forbidden"

# The three classification tokens must all appear in the walk text.
assert_contains "closeout.md Q7 lists keep-because-X classification" \
  "$CL_CONTENT" "keep-because-"
assert_contains "closeout.md Q7 lists clean-now classification" \
  "$CL_CONTENT" "clean-now"
assert_contains "closeout.md Q7 lists clean-by-Y classification" \
  "$CL_CONTENT" "clean-by-"

# --- 2. capabilities/closeout.md — new ## Files created this session section -

assert_contains "closeout.md output block adds ## Files created this session" \
  "$CL_CONTENT" "## Files created this session"

# Position invariant: ## State Deltas < ## Files created this session
# < ## Running State. Same shape as the position-guard for
# ## Running State.
sd_line=$(heading_line "$CL_PATH" "## State Deltas")
fc_line=$(heading_line "$CL_PATH" "## Files created this session")
rs_line=$(heading_line "$CL_PATH" "## Running State")
if [ "$sd_line" -gt 0 ] && [ "$fc_line" -gt 0 ] && [ "$rs_line" -gt 0 ] \
   && [ "$sd_line" -lt "$fc_line" ] && [ "$fc_line" -lt "$rs_line" ]; then
  _pass "closeout.md places ## Files created this session between ## State Deltas and ## Running State"
else
  _fail "closeout.md places ## Files created this session between ## State Deltas and ## Running State" \
        "state-deltas:$sd_line files-created:$fc_line running-state:$rs_line"
fi

# Q7 position: Q7 must appear AFTER Q6 in the walk (numbered list). Anchor on
# the actual leading "7. " (with the canonical signal phrase) and on Q6's text
# ("Did the work reveal a missing data path") to find the walk-list specifically.
q6_cl=$(grep -nE '^6\. Did the work reveal a missing data path' "$CL_PATH" | head -1 | cut -d: -f1)
q7_cl=$(grep -nE '^7\. \*\*File sweep' "$CL_PATH" | head -1 | cut -d: -f1)
if [ -n "$q6_cl" ] && [ -n "$q7_cl" ] && [ "$q6_cl" -lt "$q7_cl" ]; then
  _pass "closeout.md Q7 File sweep appears after Q6 in the walk"
else
  _fail "closeout.md Q7 File sweep appears after Q6 in the walk" \
        "q6:$q6_cl q7:$q7_cl"
fi

# --- 3. core/self-improvement.md — Q7 mirror in the canonical walk ----------
#
# Same lockstep contract that the EAD tests enforce: the canonical
# walk in core/self-improvement.md and the capability spec in
# capabilities/closeout.md stay in sync on question count + Q7 wording.

assert_contains "self-improvement.md walks Q7 File sweep" \
  "$SI_CONTENT" "File sweep"
assert_contains "self-improvement.md Q7 forbids default-keep" \
  "$SI_CONTENT" "Default-keep is forbidden"

# Codex MT-2 amendment: lockstep parity between
# capabilities/closeout.md and core/self-improvement.md on the 3 Q7
# classification tokens — without this, the self-improvement walk could
# silently drop one of the three options and the test would not catch it.
assert_contains "self-improvement.md Q7 lists keep-because-X classification" \
  "$SI_CONTENT" "keep-because-"
assert_contains "self-improvement.md Q7 lists clean-now classification" \
  "$SI_CONTENT" "clean-now"
assert_contains "self-improvement.md Q7 lists clean-by-Y classification" \
  "$SI_CONTENT" "clean-by-"

# Codex MT-2 amendment: Q0's fast-path must preserve Q7's file sweep
# (same lockstep contract as the existing state-delta-mandatory
# clause). The Q0-skips-Q1-through-Q6 fast path must NOT silently swallow
# Q7's file sweep — that would re-introduce the lingering-junk hole this
# whole change is designed to close. Pinned in both files.
assert_contains "closeout.md Q0 preserves mandatory Q7 file sweep" \
  "$CL_CONTENT" "Q7 file sweep below ALSO remains mandatory"
assert_contains "self-improvement.md Q0 preserves mandatory Q7 file sweep" \
  "$SI_CONTENT" "Q7 file sweep below ALSO remains mandatory"

# Q7 position in self-improvement.md too — anchor on the same Q6 text.
q6_si=$(grep -nE '^6\. Did the work reveal a missing' "$SI_PATH" | head -1 | cut -d: -f1)
q7_si=$(grep -nE '^7\. \*\*File sweep' "$SI_PATH" | head -1 | cut -d: -f1)
if [ -n "$q6_si" ] && [ -n "$q7_si" ] && [ "$q6_si" -lt "$q7_si" ]; then
  _pass "self-improvement.md Q7 File sweep appears after Q6 in the walk"
else
  _fail "self-improvement.md Q7 File sweep appears after Q6 in the walk" \
        "q6:$q6_si q7:$q7_si"
fi

# --- 4. linear/closeout-format.md — mirror the new section -------------------
#
# Operator-facing template: the new ## Files created this session section
# must appear there too, in the same position. linear/closeout-format.md
# section names diverge slightly from capabilities/closeout.md but the
# Files-section heading is identical for the operator workflow.

assert_contains "closeout-format.md adds ## Files created this session" \
  "$LF_CONTENT" "## Files created this session"

# Same position invariant in the operator-facing template.
lf_sd=$(heading_line "$LF_PATH" "## State Deltas")
lf_fc=$(heading_line "$LF_PATH" "## Files created this session")
lf_rs=$(heading_line "$LF_PATH" "## Running State")
if [ "$lf_sd" -gt 0 ] && [ "$lf_fc" -gt 0 ] && [ "$lf_rs" -gt 0 ] \
   && [ "$lf_sd" -lt "$lf_fc" ] && [ "$lf_fc" -lt "$lf_rs" ]; then
  _pass "closeout-format.md places ## Files created this session between ## State Deltas and ## Running State"
else
  _fail "closeout-format.md places ## Files created this session between ## State Deltas and ## Running State" \
        "state-deltas:$lf_sd files-created:$lf_fc running-state:$lf_rs"
fi

# --- 6. Q7a — operator-main git-state cleanliness verification ------
#
# Q7 (file sweep) already lands; extends Q7 with a new
# sub-step Q7a (operator-main git-state cleanliness) so the closeout output
# block cannot claim `operator-main clean at <SHA>` without verifying the
# index. Q7a deliberately lives as a same-question sub-step (not a 9th
# top-level question) so the canonical "8 closeout questions" wording +
# frontmatter summary stay unchanged — see
# docs/superpowers/plans/2026-05-28-t-126-* for the A-vs-B decision
# rationale. (The harness Stop hook that also carried this count string was
# removed — closeout is now manual-fire.)
#
# Lockstep contract (same shape as the MT-2 parity):
# - capabilities/closeout.md carries Q7a walk body + 3 check commands
# - core/self-improvement.md mirrors Q7a + 3 check commands
# - linear/closeout-format.md shows verified-clean shape in ## State Deltas
#
# Scoping: per Codex F-1 + F-2 review (cross-model-out/2026-05-28-t-126-*),
# walk-body assertions slice the file between the Q7a anchor and the next
# major boundary so a future edit that drops the Q7a walk body (while
# leaving the three command strings in unrelated State Deltas / Q0 prose)
# cannot pass. Q0-clause assertions slice Q0 between its line and Q1's line
# (same pattern as the MT-2 EAD-position guard at lines 285-301).

# 6.1 — capabilities/closeout.md Q7a presence + signal phrase (file-scope OK
# for these two; the body-scoped commands come next).
assert_contains "closeout.md walks Q7a operator-main git-state cleanliness" \
  "$CL_CONTENT" "Q7a"
assert_contains "closeout.md Q7a names operator-main git-state cleanliness" \
  "$CL_CONTENT" "operator-main git-state cleanliness"

# 6.2 — capabilities/closeout.md Q7a walk body MUST carry all three check
# commands. Slice the file between the Q7a anchor line and the next major
# walk-end marker (the "If every answer is \"no\"" paragraph that closes
# the numbered list) so unrelated occurrences in State Deltas prose can't
# false-PASS this gate (Codex F-1).
q7a_cl=$(grep -nE '\*\*Q7a — operator-main git-state cleanliness' "$CL_PATH" | head -1 | cut -d: -f1)
walk_end_cl=$(grep -nE '^If every answer is "no"' "$CL_PATH" | head -1 | cut -d: -f1)
if [ -n "$q7a_cl" ] && [ -n "$walk_end_cl" ] && [ "$q7a_cl" -lt "$walk_end_cl" ]; then
  q7a_body_cl=$(sed -n "${q7a_cl},$((walk_end_cl-1))p" "$CL_PATH")
else
  q7a_body_cl=""
fi
assert_contains "closeout.md Q7a walk body names git status --porcelain check" \
  "$q7a_body_cl" "git status --porcelain"
assert_contains "closeout.md Q7a walk body names git diff --cached --quiet check" \
  "$q7a_body_cl" "git diff --cached --quiet"
assert_contains "closeout.md Q7a walk body names git diff --quiet check" \
  "$q7a_body_cl" "git diff --quiet"

# 6.3 — capabilities/closeout.md Q7a forbids silent clean claims (body-scoped).
assert_contains "closeout.md Q7a forbids silent clean claims" \
  "$q7a_body_cl" "Silent claims of \`clean\` are forbidden"

# 6.4 — core/self-improvement.md mirrors Q7a (file-scope OK for presence).
assert_contains "self-improvement.md mirrors Q7a sub-step" \
  "$SI_CONTENT" "Q7a"
assert_contains "self-improvement.md mirrors Q7a operator-main git-state cleanliness" \
  "$SI_CONTENT" "operator-main git-state cleanliness"

# 6.5 — core/self-improvement.md Q7a walk body MUST carry all three check
# commands (body-scoped; mirror of 6.2). Walk-end marker in this file is
# the "If the answer is no" parenthetical that closes Q7's numbered item.
q7a_si=$(grep -nE '\*\*Q7a — operator-main git-state cleanliness' "$SI_PATH" | head -1 | cut -d: -f1)
walk_end_si=$(grep -nE '^If the answer is no' "$SI_PATH" | head -1 | cut -d: -f1)
if [ -n "$q7a_si" ] && [ -n "$walk_end_si" ] && [ "$q7a_si" -lt "$walk_end_si" ]; then
  q7a_body_si=$(sed -n "${q7a_si},$((walk_end_si-1))p" "$SI_PATH")
else
  q7a_body_si=""
fi
assert_contains "self-improvement.md Q7a walk body names git status --porcelain check" \
  "$q7a_body_si" "git status --porcelain"
assert_contains "self-improvement.md Q7a walk body names git diff --cached --quiet check" \
  "$q7a_body_si" "git diff --cached --quiet"
assert_contains "self-improvement.md Q7a walk body names git diff --quiet check" \
  "$q7a_body_si" "git diff --quiet"

# 6.6 — Q0 fast-path preserves mandatory Q7a verification (Codex F-2:
# scope to Q0's body specifically, not the whole file). Mirrors the
# MT-2 EAD position-guard slice at lines 285-301 — anchor on
# `^0\. \*\*EAD gate` for Q0 start + `^1\. Did we learn anything` for
# Q1 start; Q0 body is the lines in between. Without scoping, a future
# edit could drop "Q7a" from Q0's clause and leave it in unrelated
# State Deltas prose; the test would stay green and re-introduce the
# false-RED-propagation hole this whole change closes.

# Reuse the q0/q1 line numbers shape from the existing MT-2
# scoping pattern (closeout-format.test.sh lines 285-301).
q0_cl_line=$(grep -nE '^0\. \*\*EAD gate' "$CL_PATH" | head -1 | cut -d: -f1)
q1_cl_line=$(grep -nE '^1\. Did we learn anything' "$CL_PATH" | head -1 | cut -d: -f1)
if [ -n "$q0_cl_line" ] && [ -n "$q1_cl_line" ] && [ "$q0_cl_line" -lt "$q1_cl_line" ]; then
  q0_body_cl=$(sed -n "${q0_cl_line},$((q1_cl_line-1))p" "$CL_PATH")
else
  q0_body_cl=""
fi
assert_contains "closeout.md Q0 body preserves mandatory Q7a verification" \
  "$q0_body_cl" "Q7a verification"

q0_si_line=$(grep -nE '^0\. \*\*EAD gate' "$SI_PATH" | head -1 | cut -d: -f1)
q1_si_line=$(grep -nE '^1\. Did we learn anything' "$SI_PATH" | head -1 | cut -d: -f1)
if [ -n "$q0_si_line" ] && [ -n "$q1_si_line" ] && [ "$q0_si_line" -lt "$q1_si_line" ]; then
  q0_body_si=$(sed -n "${q0_si_line},$((q1_si_line-1))p" "$SI_PATH")
else
  q0_body_si=""
fi
assert_contains "self-improvement.md Q0 body preserves mandatory Q7a verification" \
  "$q0_body_si" "Q7a verification"

# 6.7 — linear/closeout-format.md ## State Deltas section shows the
# verified-clean shape so the operator-facing template demonstrates what
# Q7a-verified output looks like.
assert_contains "closeout-format.md State Deltas example shows verified-clean shape" \
  "$LF_CONTENT" "verified: git status --porcelain empty"
assert_contains "closeout-format.md State Deltas example shows dirty-state shape" \
  "$LF_CONTENT" "operator-main: 1 staged file"

# 6.8 — Codex F-3 amendment: capabilities/closeout.md post-walk
# parenthetical mirrors the "Q7a never short-circuits either" wording
# already present in core/self-improvement.md. Both canonical bodies must
# be equally explicit at the closeout decision point — otherwise a future
# reader of capabilities/closeout.md alone could conclude only Q7 is
# protected from the no-action fast path. Lockstep parity, same shape as
# the MT-2 contract.
assert_contains "closeout.md post-walk note mirrors Q7a never-short-circuit clause" \
  "$CL_CONTENT" "Q7a never short-circuits either"
assert_contains "self-improvement.md post-walk note mirrors Q7a never-short-circuit clause" \
  "$SI_CONTENT" "Q7a never short-circuits either"
