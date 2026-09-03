#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tiering: builds a full claude render via scripts/install.sh --build-only.
# test-tier: slow
# tests/spine-size.test.sh — the anti-re-bloat regression gate for the native spine.
#
# The two native spine capabilities (session-agent, closeout) are re-read on every
# tool call for a whole session, so their compiled size is a MULTIPLICATIVE cost
# (skills/skill-authoring.md principle 5). They were slimmed against a captured
# baseline (tests/fixtures/spine-baseline.json); without a gate, "one more helpful
# paragraph" walks them straight back up.
#
# Two halves, deliberately paired:
#   (a) a SIZE ceiling — the freshly compiled claude render's two SKILL.md files
#       must together stay at or under 70% of the baseline's claude combined bytes.
#   (b) STRUCTURAL anchors — the load-bearing gates that must survive any future
#       slimming. Without (b), (a) is trivially satisfiable by deleting a gate.
#       These are deliberate regression anchors, not a prose contract
#       (skill-authoring principle 4).
#   (c) a SIZE FLOOR per compiled body — the anti-gutting tripwire. The anchors in
#       (b) are substrings: a body reduced to nothing but those strings would
#       satisfy every one of them while the instructions they anchor are gone. A
#       floor makes that failure mode loud.
#   (d) SOURCE-body ceilings against the baseline's `source` record. The compiled
#       ceilings above cover only the claude render, which is the one this suite
#       builds; re-bloat authored into capabilities/*.md reaches EVERY harness
#       render, and gating the source catches it without building four renders.
#
# Sourced by tests/run.sh; do NOT set -e or call exit.

SS_BASELINE="$REPO_ROOT/tests/fixtures/spine-baseline.json"
assert_file "spine-size: baseline fixture exists" "$SS_BASELINE"

# --- baseline: the checked-in record ------------------------------------------
# Every field the gate reads is asserted present, so a truncated or reshaped
# fixture fails loudly instead of silently yielding an empty (always-passing)
# ceiling.
ss_json() { jq -r "$1 // empty" "$SS_BASELINE" 2>/dev/null; }

assert_eq "spine-size: baseline records a capture date" "yes" \
  "$([ -n "$(ss_json '.captured')" ] && echo yes || echo no)"

for _ss_render in claude codex agents hermes source; do
  for _ss_cap in session_agent closeout; do
    for _ss_field in bytes lines; do
      _ss_v="$(ss_json ".per_render.$_ss_render.$_ss_cap.$_ss_field")"
      assert_eq "spine-size: baseline has per_render.$_ss_render.$_ss_cap.$_ss_field" \
        "yes" "$([ -n "$_ss_v" ] && [ "$_ss_v" -gt 0 ] 2>/dev/null && echo yes || echo no)"
    done
  done
done

for _ss_field in harness tool_calls fixed_reads tracker_calls wall_time; do
  assert_eq "spine-size: baseline live_mode1_sample records $_ss_field" "yes" \
    "$([ -n "$(ss_json ".live_mode1_sample.$_ss_field")" ] && echo yes || echo no)"
done

SS_BASE_SA="$(ss_json '.per_render.claude.session_agent.bytes')"
SS_BASE_CL="$(ss_json '.per_render.claude.closeout.bytes')"
SS_BASE_COMBINED=$(( SS_BASE_SA + SS_BASE_CL ))
# Integer ceiling at 70% — the acceptance bar is "at least 30 percent smaller".
SS_CEILING=$(( SS_BASE_COMBINED * 70 / 100 ))

# --- (c) anti-gutting FLOORS on the compiled bodies ---------------------------
# Hard byte minimums, not baseline-derived: the ceiling and the substring anchors
# are both satisfiable by a body stripped down to the anchor strings themselves.
# These numbers sit well below the current bodies (they are a tripwire, not a
# target) and only fire when a capability has been hollowed out.
SS_FLOOR_SA=10000
SS_FLOOR_CL=15000

# --- (d) SOURCE-body ceilings -------------------------------------------------
# Same 70%-of-baseline bar applied to capabilities/*.md, which every render
# compiles from. This suite builds only the claude render, so without these a
# re-bloat that lands in the source is invisible to the codex/agents/hermes lanes
# until someone builds them.
SS_SRC_SA="$REPO_ROOT/capabilities/session-agent.md"
SS_SRC_CL="$REPO_ROOT/capabilities/closeout.md"
SS_BASE_SRC_SA="$(ss_json '.per_render.source.session_agent.bytes')"
SS_BASE_SRC_CL="$(ss_json '.per_render.source.closeout.bytes')"
SS_SRC_CEIL_SA=$(( SS_BASE_SRC_SA * 70 / 100 ))
SS_SRC_CEIL_CL=$(( SS_BASE_SRC_CL * 70 / 100 ))
SS_NOW_SRC_SA="$(wc -c < "$SS_SRC_SA" | tr -d ' ')"
SS_NOW_SRC_CL="$(wc -c < "$SS_SRC_CL" | tr -d ' ')"

if [ "$SS_NOW_SRC_SA" -le "$SS_SRC_CEIL_SA" ]; then
  _pass "spine-size: source session-agent.md is <= 70% of its baseline ($SS_NOW_SRC_SA <= $SS_SRC_CEIL_SA bytes)"
else
  _fail "spine-size: source session-agent.md is <= 70% of its baseline" \
    "now=$SS_NOW_SRC_SA ceiling=$SS_SRC_CEIL_SA baseline=$SS_BASE_SRC_SA"
fi
if [ "$SS_NOW_SRC_CL" -le "$SS_SRC_CEIL_CL" ]; then
  _pass "spine-size: source closeout.md is <= 70% of its baseline ($SS_NOW_SRC_CL <= $SS_SRC_CEIL_CL bytes)"
else
  _fail "spine-size: source closeout.md is <= 70% of its baseline" \
    "now=$SS_NOW_SRC_CL ceiling=$SS_SRC_CEIL_CL baseline=$SS_BASE_SRC_CL"
fi

# --- (e) the moved Notes bullets survive in the reference doc ------------------
# Slimming the compiled spine by MOVING prose only helps if the prose actually
# lands somewhere. The six honesty / mode-economics bullets left
# capabilities/session-agent.md for capabilities/reference/session-agent.md; a
# source-ceiling gate alone would happily accept them being deleted outright, so
# each lead phrase is pinned at its new home. Source-level, no build needed.
SS_REF_SA="$REPO_ROOT/capabilities/reference/session-agent.md"
assert_file "spine-size: session-agent reference doc exists" "$SS_REF_SA"
if [ -f "$SS_REF_SA" ]; then
  SS_REF_SA_BODY="$(cat "$SS_REF_SA")"
  while IFS= read -r _ss_note; do
    [ -n "$_ss_note" ] || continue
    assert_contains "spine-size: reference doc carries the moved Notes bullet '$_ss_note'" \
      "$SS_REF_SA_BODY" "$_ss_note"
  done <<'SS_NOTES'
Mode 1 fires once per session
Be honest on the Linear gate
Be honest on the Lessons line
Be honest on the Execution line
The gate enforces the first complete declaration per session
Mode 1 is expensive, Mode 2 is cheap
SS_NOTES
  # Lead phrases alone only prove the six BOLD LEADS survived — a move that
  # dropped every bullet's body would keep them all. Each bullet is therefore
  # pinned a second time by a distinctive phrase from its TAIL, so the assertion
  # pair brackets the whole bullet.
  while IFS= read -r _ss_tail; do
    [ -n "$_ss_tail" ] || continue
    assert_contains "spine-size: reference doc keeps the moved Notes bullet tail '$_ss_tail'" \
      "$SS_REF_SA_BODY" "$_ss_tail"
  done <<'SS_NOTE_TAILS'
forces a Mode 1 re-run
defeats the protocol
use whichever is true
the panel the operator asked for
not a security boundary
Don't re-orient on every prompt
SS_NOTE_TAILS
fi

# --- build a claude render (same temp-install pattern as compiler.test.sh) ----
SS_DIR="$(mktemp -d)"
SS_OUT="$SS_DIR/out"; mkdir -p "$SS_OUT"
SS_ENV="$SS_DIR/local.env"
make_local_env "$SS_ENV" "$SS_OUT" "$SS_DIR/vault"
SS_BUILD="$(AI_CONFIG_LOCAL_ENV="$SS_ENV" bash "$REPO_ROOT/scripts/install.sh" --build-only 2>/dev/null)"

SS_SA="$SS_BUILD/skills/session-agent/SKILL.md"
SS_CL="$SS_BUILD/skills/closeout/SKILL.md"

if [ -n "$SS_BUILD" ] && [ -f "$SS_SA" ] && [ -f "$SS_CL" ]; then
  ss_bytes() { wc -c < "$1" | tr -d ' '; }
  SS_NOW_SA="$(ss_bytes "$SS_SA")"
  SS_NOW_CL="$(ss_bytes "$SS_CL")"
  SS_NOW_COMBINED=$(( SS_NOW_SA + SS_NOW_CL ))

  if [ "$SS_NOW_COMBINED" -le "$SS_CEILING" ]; then
    _pass "spine-size: compiled spine is <= 70% of the baseline ($SS_NOW_COMBINED <= $SS_CEILING bytes)"
  else
    _fail "spine-size: compiled spine is <= 70% of the baseline" \
      "combined=$SS_NOW_COMBINED ceiling=$SS_CEILING baseline=$SS_BASE_COMBINED (session-agent=$SS_NOW_SA closeout=$SS_NOW_CL)"
  fi

  # Neither capability may grow past its own baseline either — a combined-only
  # ceiling lets one body balloon while the other is gutted.
  if [ "$SS_NOW_SA" -le "$SS_BASE_SA" ]; then
    _pass "spine-size: compiled session-agent does not exceed its baseline ($SS_NOW_SA <= $SS_BASE_SA)"
  else
    _fail "spine-size: compiled session-agent does not exceed its baseline" \
      "now=$SS_NOW_SA baseline=$SS_BASE_SA"
  fi
  if [ "$SS_NOW_CL" -le "$SS_BASE_CL" ]; then
    _pass "spine-size: compiled closeout does not exceed its baseline ($SS_NOW_CL <= $SS_BASE_CL)"
  else
    _fail "spine-size: compiled closeout does not exceed its baseline" \
      "now=$SS_NOW_CL baseline=$SS_BASE_CL"
  fi

  # Anti-gutting floors: deleting the instructions while keeping the anchor
  # strings below would otherwise read as a clean pass.
  if [ "$SS_NOW_SA" -ge "$SS_FLOOR_SA" ]; then
    _pass "spine-size: compiled session-agent is above the anti-gutting floor ($SS_NOW_SA >= $SS_FLOOR_SA)"
  else
    _fail "spine-size: compiled session-agent is above the anti-gutting floor" \
      "now=$SS_NOW_SA floor=$SS_FLOOR_SA — the body has been hollowed out, not slimmed"
  fi
  if [ "$SS_NOW_CL" -ge "$SS_FLOOR_CL" ]; then
    _pass "spine-size: compiled closeout is above the anti-gutting floor ($SS_NOW_CL >= $SS_FLOOR_CL)"
  else
    _fail "spine-size: compiled closeout is above the anti-gutting floor" \
      "now=$SS_NOW_CL floor=$SS_FLOOR_CL — the body has been hollowed out, not slimmed"
  fi

  SS_SA_BODY="$(cat "$SS_SA")"
  SS_CL_BODY="$(cat "$SS_CL")"

  # --- (b) load-bearing structural anchors in the COMPILED bodies -------------
  # The two declaration lines the pre-edit-gate hook greps for, line-anchored and
  # with a non-empty value — see harnesses/claude/hooks/session-agent.sh.
  assert_contains "spine-size: compiled session-agent carries the Linear gate declaration line" \
    "$SS_SA_BODY" "Linear gate: <ISSUE-ID or URL>"
  assert_contains "spine-size: compiled session-agent carries the Lessons declaration line" \
    "$SS_SA_BODY" "Lessons: <matched lesson"
  # R2b's execution-shape declaration — the routing walk's HOW line.
  assert_contains "spine-size: compiled session-agent carries the Execution declaration line" \
    "$SS_SA_BODY" "Execution: inline | delegated wave | delegated wave + panel"
  # Every execution shape R2b names, pinned WITH its cascade position. The bare
  # values are satisfiable by an unrelated mention elsewhere in the body — R2b's own
  # opening sentence and the closing honesty paragraph both name \`inline\` — so a
  # value-only loop would not notice R2b losing a rule, nor the risk-before-size
  # ORDER the numbering encodes. (The full Notes bullets moved to
  # capabilities/reference/session-agent.md; the (e) block above pins them there.)
  for _ss_exec in "1. \`delegated wave + panel\`" "2. \`delegated wave\`" "3. \`inline\`"; do
    assert_contains "spine-size: compiled session-agent keeps R2b cascade rule $_ss_exec" \
      "$SS_SA_BODY" "$_ss_exec"
  done
  # ORDER, not just presence: the numbering is only meaningful if the rules appear
  # in it — risk BEFORE size BEFORE the residue. A future slim that reshuffles the
  # cascade keeps every needle above and would pass on presence alone.
  ss_pos() { local pre="${SS_SA_BODY%%"$1"*}"; [ "$pre" = "$SS_SA_BODY" ] && printf -- '-1' || printf '%s' "${#pre}"; }
  _ss_o1="$(ss_pos "1. \`delegated wave + panel\`")"
  _ss_o2="$(ss_pos "2. \`delegated wave\`")"
  _ss_o3="$(ss_pos "3. \`inline\`")"
  if [ "$_ss_o1" -ge 0 ] && [ "$_ss_o1" -lt "$_ss_o2" ] && [ "$_ss_o2" -lt "$_ss_o3" ]; then
    _pass "spine-size: compiled session-agent keeps the R2b cascade order 1→2→3"
  else
    _fail "spine-size: compiled session-agent keeps the R2b cascade order 1→2→3" \
      "offsets rule1=$_ss_o1 rule2=$_ss_o2 rule3=$_ss_o3 (want 0 <= rule1 < rule2 < rule3)"
  fi
  # Every valid Lessons value the hook's deny message and the honesty rules name.
  for _ss_val in "none match" "index unreachable" "skipped — "; do
    assert_contains "spine-size: compiled session-agent names the Lessons value '$_ss_val'" \
      "$SS_SA_BODY" "$_ss_val"
  done
  # The gate-marker write instruction (the only declaration channel on harness
  # variants whose transcript drops assistant text).
  assert_contains "spine-size: compiled session-agent instructs the gate-marker write path" \
    "$SS_SA_BODY" 'agentic-os/gate-<session_id>'
  # Mode selection rule + the script-first orient wiring.
  assert_contains "spine-size: compiled session-agent keeps the Mode 1 / Mode 2 selection rule" \
    "$SS_SA_BODY" "run Mode 1. Otherwise run Mode 2"
  assert_contains "spine-size: compiled session-agent wires scripts/orient.sh" \
    "$SS_SA_BODY" "scripts/orient.sh"
  assert_contains "spine-size: compiled session-agent keeps the projects-first cut" \
    "$SS_SA_BODY" "projects-first"

  # closeout: the pre-write gate wrapper, the 8-question walk, Q7a's three git
  # commands, and the full 11-class routing table.
  assert_contains "spine-size: compiled closeout wires scripts/closeout-gate.sh" \
    "$SS_CL_BODY" "scripts/closeout-gate.sh --draft"
  assert_contains "spine-size: compiled closeout keeps the fail-closed do-not-write rule" \
    "$SS_CL_BODY" "Non-zero = do NOT write"
  assert_contains "spine-size: compiled closeout keeps the 8-question walk header" \
    "$SS_CL_BODY" "The 8 closeout questions"
  # Q1b is the closeout-side consumer of R2b's Execution: line — without it the
  # declared execution shape is never checked against what actually ran.
  assert_contains "spine-size: compiled closeout keeps the Q1b Execution-honored question" \
    "$SS_CL_BODY" "Q1b — Execution-honored check"
  assert_contains "spine-size: compiled closeout keeps Q7a git status --porcelain" \
    "$SS_CL_BODY" "git status --porcelain"
  assert_contains "spine-size: compiled closeout keeps Q7a git diff --cached --quiet" \
    "$SS_CL_BODY" "git diff --cached --quiet"
  assert_contains "spine-size: compiled closeout keeps Q7a git diff --quiet" \
    "$SS_CL_BODY" "git diff --quiet"
  for _ss_class in rule check script linear obsidian playbook skill data-readiness goal-run no-action state-delta; do
    assert_contains "spine-size: compiled closeout classification table lists \`$_ss_class\`" \
      "$SS_CL_BODY" "| \`$_ss_class\` |"
  done
else
  _fail "spine-size: claude render produced both spine SKILL.md files" \
    "build='$SS_BUILD' session-agent='$SS_SA' closeout='$SS_CL'"
fi

[ -n "$SS_BUILD" ] && rm -rf "$SS_BUILD"
rm -rf "$SS_DIR"
unset SS_BASELINE SS_BASE_SA SS_BASE_CL SS_BASE_COMBINED SS_CEILING SS_DIR SS_OUT \
      SS_ENV SS_BUILD SS_SA SS_CL SS_NOW_SA SS_NOW_CL SS_NOW_COMBINED SS_SA_BODY SS_CL_BODY \
      SS_FLOOR_SA SS_FLOOR_CL SS_SRC_SA SS_SRC_CL SS_BASE_SRC_SA SS_BASE_SRC_CL \
      SS_SRC_CEIL_SA SS_SRC_CEIL_CL SS_NOW_SRC_SA SS_NOW_SRC_CL _ss_o1 _ss_o2 _ss_o3
unset -f ss_pos
