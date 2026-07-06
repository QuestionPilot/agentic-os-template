#!/usr/bin/env bash
# tests/closeout-format.test.sh — assert the closeout shape carries the
# state-delta class + State Deltas section across all four definition files.
# Guards against future drift where one file silently loses the new class.

# Note: this file is sourced by tests/run.sh; do NOT set -e or call exit.

# --- 1. core/self-improvement.md: state-delta class is in the table + Inputs section exists.
SI_CONTENT="$(cat "$REPO_ROOT/core/self-improvement.md")"

assert_contains "self-improvement.md lists state-delta class" \
  "$SI_CONTENT" "\`state-delta\`"

assert_contains "self-improvement.md has the State Deltas inputs section" \
  "$SI_CONTENT" "## Inputs — State Deltas"

# --- 2. capabilities/closeout.md: state-delta in routing table + State Deltas in block + input step.
CL_CONTENT="$(cat "$REPO_ROOT/capabilities/closeout.md")"

assert_contains "closeout.md routing table includes state-delta" \
  "$CL_CONTENT" "\`state-delta\`"

assert_contains "closeout.md output block requires ## State Deltas" \
  "$CL_CONTENT" "## State Deltas"

assert_contains "closeout.md Inputs section enumerates State Deltas" \
  "$CL_CONTENT" "Enumerate State Deltas"

# --- 3. linear/closeout-format.md: ## State Deltas section + class enum lists state-delta.
LF_CONTENT="$(cat "$REPO_ROOT/linear/closeout-format.md")"

assert_contains "closeout-format.md has ## State Deltas section" \
  "$LF_CONTENT" "## State Deltas"

assert_contains "closeout-format.md class enum includes state-delta" \
  "$LF_CONTENT" "\`state-delta\`"

# --- 4. obsidian/lesson-template.md: class enum lists state-delta.
OL_CONTENT="$(cat "$REPO_ROOT/obsidian/lesson-template.md")"

assert_contains "lesson-template.md class enum includes state-delta" \
  "$OL_CONTENT" "\`state-delta\`"

# --- 5. session-agent owns the kickoff query order.
# The Kickoff query order subsection moved out of CLAUDE.template / AGENTS.template
# and into capabilities/session-agent.md (Mode 1 orient, sub-step O3).
# The templates now carry a pointer to session-agent's Mode 1; the canonical text
# lives in the capability body so it's a single source of truth.
CT_CONTENT="$(cat "$REPO_ROOT/harnesses/claude/CLAUDE.template.md")"
AT_CONTENT="$(cat "$REPO_ROOT/harnesses/codex/AGENTS.template.md")"
SA_CONTENT="$(cat "$REPO_ROOT/capabilities/session-agent.md")"

assert_contains "session-agent.md owns the projects-first kickoff cut" \
  "$SA_CONTENT" "projects-first"

assert_contains "session-agent.md references linear/linear-setup.md for surface commands" \
  "$SA_CONTENT" "linear/linear-setup.md"

assert_contains "CLAUDE.template points at session-agent Mode 1 for kickoff" \
  "$CT_CONTENT" "session-agent"

assert_contains "AGENTS.template points at session-agent Mode 1 for kickoff" \
  "$AT_CONTENT" "session-agent"

assert_contains "CLAUDE.template references state-delta closeout rule" \
  "$CT_CONTENT" "state-delta"

assert_contains "AGENTS.template references state-delta closeout rule" \
  "$AT_CONTENT" "state-delta"

# --- 6. core/memory-model.md: headline-vs-body contract section.
MM_CONTENT="$(cat "$REPO_ROOT/core/memory-model.md")"

assert_contains "memory-model.md has the Per-Harness Memory Index section" \
  "$MM_CONTENT" "Per-Harness Memory Index"

assert_contains "memory-model.md references state-delta as the write-side guarantee" \
  "$MM_CONTENT" "state-delta"

# --- 7. every derivative carries the FULL 11-class set.
# State-delta is already asserted above; this section pins data-readiness and
# goal-run, the two classes the 2026-05-23 hygiene sweep found missing from the
# derivative files. Cross-model review (F-2) flagged that the original test
# only guarded state-delta, leaving the other two free to silently drop again.
for class in data-readiness goal-run; do
  assert_contains "core/closeout.md lists $class"             "$(cat "$REPO_ROOT/core/closeout.md")"             "\`$class\`"
  assert_contains "linear/closeout-format.md lists $class"    "$(cat "$REPO_ROOT/linear/closeout-format.md")"    "\`$class\`"
  assert_contains "obsidian/lesson-template.md lists $class"  "$(cat "$REPO_ROOT/obsidian/lesson-template.md")"  "\`$class\`"
  assert_contains "capabilities/closeout.md lists $class"     "$CL_CONTENT"                                       "\`$class\`"
  assert_contains "self-improvement.md lists $class"          "$SI_CONTENT"                                       "\`$class\`"
done

# --- 8. output block adds ## Running State + ## Pick up here sections.
#
# Per the issue spec:
# - `## Running State` between `## State Deltas` and `## Residual Risk` in the
# capabilities/closeout.md output block.
# - `## Pick up here` after `## Lessons`, as the final line of the output block.
# - linear/closeout-format.md is the CANONICAL schema the capability's block
# mirrors — both new sections must exist there too under the same names.

# Local helper: line number of an exact heading match, or 0 if missing.
# Uses grep -nFx (line-number, fixed-string, full-line) — POSIX, BSD-grep safe.
heading_line() {
  local n
  n=$(grep -nFx "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1)
  printf '%s\n' "${n:-0}"
}

CL_PATH="$REPO_ROOT/capabilities/closeout.md"

# Presence: the two new sections must appear in the output block.
assert_contains "closeout.md output block requires ## Running State" \
  "$CL_CONTENT" "## Running State"
assert_contains "closeout.md output block requires ## Pick up here" \
  "$CL_CONTENT" "## Pick up here"

# Position: State Deltas < Running State < Residual Risk.
sd_line=$(heading_line "$CL_PATH" "## State Deltas")
rs_line=$(heading_line "$CL_PATH" "## Running State")
rr_line=$(heading_line "$CL_PATH" "## Residual Risk")
if [ "$sd_line" -gt 0 ] && [ "$rs_line" -gt 0 ] && [ "$rr_line" -gt 0 ] \
   && [ "$sd_line" -lt "$rs_line" ] && [ "$rs_line" -lt "$rr_line" ]; then
  _pass "closeout.md places ## Running State between ## State Deltas and ## Residual Risk"
else
  _fail "closeout.md places ## Running State between ## State Deltas and ## Residual Risk" \
        "state-deltas:$sd_line running-state:$rs_line residual-risk:$rr_line"
fi

# Position: Lessons < Pick up here.
les_line=$(heading_line "$CL_PATH" "## Lessons")
pu_line=$(heading_line "$CL_PATH" "## Pick up here")
if [ "$les_line" -gt 0 ] && [ "$pu_line" -gt 0 ] && [ "$les_line" -lt "$pu_line" ]; then
  _pass "closeout.md places ## Pick up here after ## Lessons"
else
  _fail "closeout.md places ## Pick up here after ## Lessons" \
        "lessons:$les_line pick-up-here:$pu_line"
fi

# linear/closeout-format.md mirrors the shape.
assert_contains "closeout-format.md adds ## Running State section" \
  "$LF_CONTENT" "## Running State"
assert_contains "closeout-format.md adds ## Pick up here section" \
  "$LF_CONTENT" "## Pick up here"

# Stronger: ## Pick up here must be the LAST `##` heading inside the fenced
# output block in capabilities/closeout.md — so a future section can't silently
# land after it (Codex review F-2, 2026-05-24). Slices the file between the
# first two ```-only lines and checks the trailing heading.
fence_start=$(grep -nFx '```' "$CL_PATH" | sed -n '1p' | cut -d: -f1)
fence_end=$(grep -nFx '```' "$CL_PATH" | sed -n '2p' | cut -d: -f1)
if [ -n "$fence_start" ] && [ -n "$fence_end" ] && [ "$fence_start" -lt "$fence_end" ]; then
  last_inner=$(sed -n "$((fence_start+1)),$((fence_end-1))p" "$CL_PATH" \
                 | grep -E '^## ' | tail -1)
  assert_eq "closeout.md fenced output block ends with ## Pick up here" \
    "## Pick up here" "$last_inner"
else
  _fail "closeout.md fenced output block ends with ## Pick up here" \
        "could not locate fenced output block (start='$fence_start' end='$fence_end')"
fi

# linear/closeout-format.md also enforces ordering — even though the issue
# notes position is "less strict" there, the two files drifting apart is the
# kind of slow-creep failure these tests exist to catch (Gemini review missing
# test, 2026-05-24).
LF_PATH="$REPO_ROOT/linear/closeout-format.md"
lf_sd=$(heading_line "$LF_PATH" "## State Deltas")
lf_rs=$(heading_line "$LF_PATH" "## Running State")
lf_rr=$(heading_line "$LF_PATH" "## Residual Risk")
if [ "$lf_sd" -gt 0 ] && [ "$lf_rs" -gt 0 ] && [ "$lf_rr" -gt 0 ] \
   && [ "$lf_sd" -lt "$lf_rs" ] && [ "$lf_rs" -lt "$lf_rr" ]; then
  _pass "closeout-format.md places ## Running State between ## State Deltas and ## Residual Risk"
else
  _fail "closeout-format.md places ## Running State between ## State Deltas and ## Residual Risk" \
        "state-deltas:$lf_sd running-state:$lf_rs residual-risk:$lf_rr"
fi

# Pick up here is the last ## heading in linear/closeout-format.md.
lf_last_heading=$(grep -E '^## ' "$LF_PATH" | tail -1)
assert_eq "closeout-format.md ## Pick up here is the last top-level section" \
  "## Pick up here" "$lf_last_heading"

# --- 9. "Boring is Beautiful" named principle in core/operating-system.md.
#
# Per the issue spec:
# - `## Boring is Beautiful` heading exists in core/operating-system.md.
# - The four canonical clauses appear in the section body (so the heading can't
# land without its motivating prose, and so a future edit that hoists the
# clauses into Working Rules or Closeout Flow can't pass the assertion —
# Codex review MT-4 2026-05-25).
# - The heading appears BEFORE `## Closeout Flow` (position guard so the
# principle can't silently get folded into the closeout content).
OS_PATH="$REPO_ROOT/core/operating-system.md"
OS_CONTENT="$(cat "$OS_PATH")"

assert_contains "operating-system.md adds ## Boring is Beautiful heading" \
  "$OS_CONTENT" "## Boring is Beautiful"

# Position: ## Boring is Beautiful before ## Closeout Flow.
bb_line=$(heading_line "$OS_PATH" "## Boring is Beautiful")
cf_line=$(heading_line "$OS_PATH" "## Closeout Flow")
if [ "$bb_line" -gt 0 ] && [ "$cf_line" -gt 0 ] && [ "$bb_line" -lt "$cf_line" ]; then
  _pass "operating-system.md places ## Boring is Beautiful before ## Closeout Flow"
else
  _fail "operating-system.md places ## Boring is Beautiful before ## Closeout Flow" \
        "boring-is-beautiful:$bb_line closeout-flow:$cf_line"
fi

# Codex MT-4 amendment 2026-05-25: scope the four canonical clauses to the
# section body (between the two headings) so a future edit hoisting the clauses
# elsewhere in the file can't silently keep the assertions green. Slice with
# sed: lines (bb_line+1) through (cf_line-1) inclusive.
if [ "$bb_line" -gt 0 ] && [ "$cf_line" -gt 0 ] && [ "$bb_line" -lt "$cf_line" ]; then
  bb_body=$(sed -n "$((bb_line+1)),$((cf_line-1))p" "$OS_PATH")
else
  bb_body=""
fi

# Four canonical clauses (substrings the issue body specifies) — scoped.
assert_contains "operating-system.md Boring section body names 'lowest autonomy'" \
  "$bb_body" "lowest autonomy"
assert_contains "operating-system.md Boring section body says 'Workflows beat agents'" \
  "$bb_body" "Workflows beat agents"
assert_contains "operating-system.md Boring section body prefers deterministic over non-deterministic" \
  "$bb_body" "deterministic over non-deterministic"
assert_contains "operating-system.md Boring section body says 'eliminate before automating'" \
  "$bb_body" "eliminate before automating"

# --- 10. EAD ("Eliminate / Automate / Delegate") gate in closeout walk.
#
# Per the issue spec:
# - capabilities/closeout.md walks the EAD question — section retitled
# "The 7 closeout questions" (was 6) since the EAD question becomes Q0.
# - The canonical "should have eliminated" substring from the issue body
# lands in the walk.
# - core/self-improvement.md mirrors the question in its parallel walk so the
# canonical source (core/) and the capability spec (capabilities/) stay in
# lockstep — same lockstep contract as the existing class taxonomy assertions.
#
# update: the walk grew to 8 questions (Q0..Q7) when Q7 (File sweep)
# landed. The header / frontmatter count migrated 7 -> 8; the EAD question
# itself (Q0) and the canonical "should have eliminated" substring are
# unchanged. The 8-count assertions live in tests/closeout-file-sweep.test.sh;
# the EAD-question-text invariants stay here.
assert_contains "closeout.md walks EAD question — canonical text" \
  "$CL_CONTENT" "should have eliminated"

# core/self-improvement.md: parallel mirror.
assert_contains "self-improvement.md walks EAD question — canonical text" \
  "$SI_CONTENT" "should have eliminated"

# --- 11. Codex amendments (2026-05-25), count migration.
#
# F-2: frontmatter `summary:` mirrors the body count.
# MT-1: lock the negative — the previous count must not linger anywhere in
# the file. An earlier guard pinned "6 closeout questions" absent; a later
# change advances the count + retargets the negative to "7 closeout questions"
# absent so the half-applied-renumbering guard rolls forward with the
# canonical count. The 8-count assertions (positive presence in body +
# frontmatter + harness hooks) live in tests/closeout-file-sweep.test.sh.
# MT-2: Q0 must appear BEFORE question 1 in both files (position; the issue
# spec is explicit that EAD is the FIRST question, not the last).
# MT-5: F-1 wording fix — both files must explicitly say "State-delta lessons
# remain mandatory regardless of Q0 outcome" so the no-action fast path
# can't be misread as suppressing state-delta memory writes.
# F-3: hook blocked-reason text in both harness hooks must reference the
# canonical count. Post-fix the count is 8; the positive
# assertions live in tests/closeout-file-sweep.test.sh.

# MT-1 retargeted: the pre-fix "7 closeout questions" wording must not
# linger anywhere (guards against half-applied 7->8 renumbering, the same
# shape as the "6 closeout questions" guard).
assert_not_contains "closeout.md has no stale '7 closeout questions' substring anywhere" \
  "$CL_CONTENT" "7 closeout questions"

# MT-2: Q0 before the closeout walk's Q1 in both files. Anchor on the actual
# Q1 text ("Did we learn anything that should change future behavior?") because
# both files have a separate `1. ` numbered list earlier (capabilities/closeout.md
# has `1. List the files touched...` in the Inputs section, self-improvement.md
# has a `1....` in a different section). Anchor on the Q1 text to find the
# closeout walk's own Q1 specifically.
CL_PATH="$REPO_ROOT/capabilities/closeout.md"
SI_PATH="$REPO_ROOT/core/self-improvement.md"

q0_cl=$(grep -nE '^0\. \*\*EAD gate' "$CL_PATH" | head -1 | cut -d: -f1)
q1_cl=$(grep -nE '^1\. Did we learn anything' "$CL_PATH" | head -1 | cut -d: -f1)
if [ -n "$q0_cl" ] && [ -n "$q1_cl" ] && [ "$q0_cl" -lt "$q1_cl" ]; then
  _pass "closeout.md Q0 EAD gate appears before Q1 in the walk"
else
  _fail "closeout.md Q0 EAD gate appears before Q1 in the walk" \
        "q0:$q0_cl q1:$q1_cl"
fi

q0_si=$(grep -nE '^0\. \*\*EAD gate' "$SI_PATH" | head -1 | cut -d: -f1)
q1_si=$(grep -nE '^1\. Did we learn anything' "$SI_PATH" | head -1 | cut -d: -f1)
if [ -n "$q0_si" ] && [ -n "$q1_si" ] && [ "$q0_si" -lt "$q1_si" ]; then
  _pass "self-improvement.md Q0 EAD gate appears before Q1 in the walk"
else
  _fail "self-improvement.md Q0 EAD gate appears before Q1 in the walk" \
        "q0:$q0_si q1:$q1_si"
fi

# MT-5: state-delta-remains-mandatory guard in both files (F-1 wording fix).
# Substring is the post-line-wrap fragment (capabilities/closeout.md hard-wraps
# the bullet body so "State-delta\n lessons" spans lines; the unique suffix
# "remain mandatory regardless of Q0 outcome" matches both files unambiguously).
assert_contains "closeout.md Q0 preserves mandatory state-delta handling" \
  "$CL_CONTENT" "remain mandatory regardless of Q0 outcome"
assert_contains "self-improvement.md Q0 preserves mandatory state-delta handling" \
  "$SI_CONTENT" "remain mandatory regardless of Q0 outcome"

# F-3 hook blocked-reason positive assertions moved to
# tests/closeout-file-sweep.test.sh under the count migration; the
# negative-stale-substring guard below catches any backslide.

# --- 12. Session-log drain — the always-on write-through capture.
# capabilities/closeout.md carries the drain step + its invariants; closeout-format.md
# carries the closeout_id tie; vault-guide.md carries the propose-vs-write-through
# split. Assert the durable substrings, not a tracker token (shipped files carry none).
assert_contains "closeout.md has the Session-log drain section" \
  "$CL_CONTENT" "## Session-log drain"
assert_contains "closeout.md drain names the Sessions archive path" \
  "$CL_CONTENT" "30-Archive/Sessions"
assert_contains "closeout.md drain uses the agnostic vault path var" \
  "$CL_CONTENT" "\$OBSIDIAN_VAULT_PATH"
assert_contains "closeout.md drain stamps a closeout_id" \
  "$CL_CONTENT" "closeout_id"
assert_contains "closeout.md drain quarantines untrusted text under Raw observations" \
  "$CL_CONTENT" "Raw observations"
assert_contains "closeout.md drain names provenance labelling" \
  "$CL_CONTENT" "provenance"
assert_contains "closeout.md drain runs the injection scan before writing" \
  "$CL_CONTENT" "--injection-scan"
assert_contains "closeout.md drain requires write-verification (FLAG on miss)" \
  "$CL_CONTENT" "FLAG"

# The drain section must sit OUTSIDE the fenced output block, so it can't break the
# "Pick up here is the last heading in the fenced block" invariant (section 8).
dr_line=$(heading_line "$CL_PATH" "## Session-log drain — write-through to the durable vault")
if [ "$dr_line" -gt 0 ] && [ -n "$fence_end" ] && [ "$dr_line" -gt "$fence_end" ]; then
  _pass "closeout.md Session-log drain section is after the fenced output block"
else
  _fail "closeout.md Session-log drain section is after the fenced output block" \
        "drain:$dr_line fence_end:$fence_end"
fi

# closeout-format.md ties the comment to a closeout_id.
assert_contains "closeout-format.md ties the comment to a closeout_id" \
  "$LF_CONTENT" "closeout_id"

# vault-guide.md §8: the session log is the write-through exception; curated notes
# still propose-don't-write.
VG_CONTENT="$(cat "$REPO_ROOT/obsidian/vault-guide.md")"
assert_contains "vault-guide.md names the session-log write-through exception" \
  "$VG_CONTENT" "write-through"
assert_contains "vault-guide.md keeps curated notes propose-don't-write" \
  "$VG_CONTENT" "propose-don't-write"

# core/self-improvement.md notes the always-on drain alongside the lesson classes.
assert_contains "self-improvement.md notes the always-on session-log drain" \
  "$SI_CONTENT" "session log"
