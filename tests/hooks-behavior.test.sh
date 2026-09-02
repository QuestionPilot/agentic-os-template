#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/hooks-behavior.test.sh — behavioral acceptance for the generated hooks.
#
# For each hook: feed mock event payloads, assert exit code + a stdout predicate
# ("blocks" / "emits a directive" / "silent"). Then run the same payloads through
# the current hand-coded hook in the live claude-config and assert it satisfies
# the same predicates — proving the generated hook is behaviorally equivalent.
#
# `expected-behavior` is the source of truth; the live-hook comparison is a
# transitional cross-check that auto-skips once removes the hand-coded hooks.

fix="$REPO_ROOT/tests/fixtures"

# Build the hooks once into a throwaway target.
HB_OUT="$(mktemp -d)/target"; mkdir -p "$HB_OUT"
HB_ENV="$(mktemp -d)/local.env"
make_local_env "$HB_ENV" "$HB_OUT"
AI_CONFIG_LOCAL_ENV="$HB_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
GEN_HOOKS="$HB_OUT/hooks"

# run_hook <script> <stdin-payload> [env-assignments...]
# Echoes "<exit>|<stdout>" for the given hook script. Captures the exit code
# without toggling global shell flags (run.sh is not run under `set -e`).
run_hook() {
  local script="$1" payload="$2"; shift 2
  local out status
  out="$(printf '%s' "$payload" | env "$@" bash "$script" 2>/dev/null)" && status=0 || status=$?
  printf '%s|%s' "$status" "$out"
}

# classify_block <result> -> "block" if stdout asks to block, else "allow".
# Claude Code PreToolUse honors ONLY hookSpecificOutput.permissionDecision
# ("deny") — the legacy top-level {"decision":"block"} is a NO-OP on PreToolUse
# (that top-level form is only valid for UserPromptSubmit/PostToolUse/Stop/
# SubagentStop/PreCompact). Classify on the MODERN deny shape so a regression
# back to the legacy form classifies as "allow" and trips the block-path
# assertions below.
classify_block() {
  case "${1#*|}" in *'"permissionDecision":"deny"'*) echo "block";; *) echo "allow";; esac
}
# classify_directive <result> <tag> -> "directive" if stdout carries the tag.
classify_directive() {
  case "${1#*|}" in *"$2"*) echo "directive";; *) echo "silent";; esac
}

# ---------------------------------------------------------------------------
# session-agent.sh (PreToolUse / pre-edit-gate)
# Expected behavior table:
# no transcript -> exit 0, allow
# transcript w/o session-agent -> exit 0, block
# session-agent + Linear gate + Lessons -> exit 0, allow
# session-agent + Linear gate, no Lessons -> exit 0, block
# session-agent, no Linear gate -> exit 0, block
# CLAUDE_SKIP_SESSION_AGENT=1 -> exit 0, allow
# ---------------------------------------------------------------------------
session_agent_payload() { printf '{"transcript_path":"%s","tool_name":"Write"}' "$1"; }

r1="$(run_hook "$GEN_HOOKS/session-agent.sh" '{"tool_name":"Write"}')"
assert_eq "session-agent: no transcript exits 0" "0" "${r1%%|*}"
assert_eq "session-agent: no transcript allows"  "allow" "$(classify_block "$r1")"

r2="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(session_agent_payload "$fix/transcript-empty.jsonl")")"
assert_eq "session-agent: no routing exits 0"  "0" "${r2%%|*}"
assert_eq "session-agent: no routing blocks"   "block" "$(classify_block "$r2")"

r3="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(session_agent_payload "$fix/transcript-session-agent-ok.jsonl")")"
assert_eq "session-agent: invoked+Linear+Lessons exits 0" "0" "${r3%%|*}"
assert_eq "session-agent: invoked+Linear+Lessons allows"  "allow" "$(classify_block "$r3")"

# The declaration contract is BOTH lines — a `Linear gate:` declaration without
# the `Lessons:` recall line must still block (the recall step is the read side
# of self-improvement; skipping it silently is the regression this pins).
r3b="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(session_agent_payload "$fix/transcript-session-agent-no-lessons.jsonl")")"
assert_eq "session-agent: invoked+Linear w/o Lessons blocks" "block" "$(classify_block "$r3b")"

# Value-less declarations do not open the transcript channel (panel finding):
# a bare `Lessons:` / `Linear gate:` with nothing after the colon is not a
# disposition — same non-empty contract as the marker channel.
r3c="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(session_agent_payload "$fix/transcript-session-agent-empty-values.jsonl")")"
assert_eq "session-agent: value-less transcript declaration blocks" "block" "$(classify_block "$r3c")"

r4="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(session_agent_payload "$fix/transcript-session-agent-no-linear.jsonl")")"
assert_eq "session-agent: invoked w/o Linear blocks" "block" "$(classify_block "$r4")"

# <TEAM>-360 fixture realism — the session-agent transcripts model the
# vacuousness triggers inside tool_result records: the skill body's injected
# `Linear gate:` / `Lessons:` template lines and a prior deny message quoting
# the phrases. Only ASSISTANT-authored line-anchored declarations may open the
# gate, so a regression back to a whole-transcript grep flips r3b/r4 to allow
# and fails here.
hb_nl_fixture="$(cat "$fix/transcript-session-agent-no-linear.jsonl")"
assert_contains "session-agent: no-linear fixture models the injected template line" "$hb_nl_fixture" 'Linear gate: <ISSUE-ID'
assert_contains "session-agent: no-linear fixture models the Lessons template line"  "$hb_nl_fixture" 'Lessons: <matched'
assert_contains "session-agent: no-linear fixture models the Execution template line" "$hb_nl_fixture" 'Execution: inline | delegated wave | delegated wave + panel'
assert_contains "session-agent: no-linear fixture models a prior deny message"       "$hb_nl_fixture" 'no complete routing declaration'
hb_nls_fixture="$(cat "$fix/transcript-session-agent-no-lessons.jsonl")"
assert_contains "session-agent: no-lessons fixture models the Lessons template line" "$hb_nls_fixture" 'Lessons: <matched'
# Positive path: the ok fixture's ASSISTANT declaration carries the Execution line,
# so r3's allow above proves a real declaration is not rejected for carrying it.
# Across the fixtures all three R2b values are exercised on a live hook path:
# `delegated wave` here, `inline` on the codex ok fixture, `delegated wave + panel`
# on the marker-write allow cases below.
assert_contains "session-agent: ok fixture declares Execution in the assistant declaration" "$(cat "$fix/transcript-session-agent-ok.jsonl")" 'Linear gate: PROJ-1\nExecution: delegated wave'

# The Execution template/declaration edits are hand-written JSON escapes inside
# these fixtures — one bad backslash silently reshapes a record and every hook
# assertion above starts testing a different transcript. Sweep them all through
# jq. The enumerated COUNT is part of the compared value, so a glob that matches
# nothing (a rename, a moved fixtures dir) fails loudly instead of passing on an
# empty set.
hb_jsonl_n=0; hb_jsonl_bad=""
for hb_f in "$fix"/transcript-session-agent-*.jsonl "$fix"/transcript-desktop-session-agent.jsonl \
            "$fix"/codex-transcript-session-agent-*.jsonl; do
  [ -f "$hb_f" ] || continue
  hb_jsonl_n=$(( hb_jsonl_n + 1 ))
  jq -e . "$hb_f" >/dev/null 2>&1 || hb_jsonl_bad="$hb_jsonl_bad $(basename "$hb_f")"
done
assert_eq "session-agent: every session-agent fixture parses as JSONL" \
  "enumerated>=8 bad=none" \
  "$([ "$hb_jsonl_n" -ge 8 ] && printf 'enumerated>=8' || printf 'enumerated=%s' "$hb_jsonl_n") bad=${hb_jsonl_bad:-none}"

# <TEAM>-365 — desktop/SDK-variant transcript: assistant TEXT blocks (including
# the R5 declaration, even as tool preamble) are NOT persisted; only tool_use /
# thinking records land. The transcript channel therefore cannot open the gate
# — the GATE MARKER channel must. The fixture models the variant's record mix
# (attachment / queue-operation / last-prompt, per-content-block assistant
# records), a persisted Skill invocation, a prior deny quote, and tool_use
# noise quoting the `Linear gate:` template — so any whole-transcript grep
# regression would false-open here.
dtp() { # desktop payload: <transcript> <session_id> [tool_name] [tool_input_json]
  local ti="${4:-null}"
  printf '{"transcript_path":"%s","session_id":"%s","tool_name":"%s","tool_input":%s}' \
    "$1" "$2" "${3:-Edit}" "$ti"
}
DT_FIX="$fix/transcript-desktop-session-agent.jsonl"
DT_SID="dt-0000-1111"
DT_GATE="$HB_OUT/agentic-os/gate-$DT_SID"
rm -f "$DT_GATE"

# 1. Genuine orient, declaration emitted but not persisted, no marker → deny,
#    and the deny must carry the recovery path (the exact marker file).
d1="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$DT_FIX" "$DT_SID")")"
assert_eq       "session-agent/desktop: no marker exits 0"        "0" "${d1%%|*}"
assert_eq       "session-agent/desktop: no marker blocks"         "block" "$(classify_block "$d1")"
assert_contains "session-agent/desktop: deny names the marker path" "${d1#*|}" "gate-$DT_SID"

# 2. The marker Write itself is allowed through pre-gate — exact path + both
#    line-anchored declaration lines in the content.
# Pre-existing contract: a declaration WITHOUT `Execution:` still allows — the gate
# must never require the new line (R2b is protocol, not enforcement).
d2_input="$(jq -nc --arg p "$DT_GATE" '{file_path: $p, content: "Routing: fix\nLessons: none match\nLinear gate: none — single-step\n"}')"
d2="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$DT_FIX" "$DT_SID" Write "$d2_input")")"
assert_eq "session-agent/desktop: marker write allowed through" "allow" "$(classify_block "$d2")"

# 2b. A marker carrying the R2b `Execution:` line as well is still allowed — the
#     gate keys on the two declaration lines and must not reject extra ones. The
#     value is the `+`-and-spaces spelling, the one most likely to trip a matcher.
d2b_input="$(jq -nc --arg p "$DT_GATE" '{file_path: $p, content: "Routing: fix\nLessons: none match\nLinear gate: none — single-step\nExecution: delegated wave + panel\n"}')"
d2b="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$DT_FIX" "$DT_SID" Write "$d2b_input")")"
assert_eq "session-agent/desktop: marker write with the Execution line allowed through" "allow" "$(classify_block "$d2b")"

# 3. A marker Write WITHOUT the declaration lines is denied (content contract).
d3_input="$(jq -nc --arg p "$DT_GATE" '{file_path: $p, content: "remember to declare later"}')"
d3="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$DT_FIX" "$DT_SID" Write "$d3_input")")"
assert_eq "session-agent/desktop: undeclared marker write blocks" "block" "$(classify_block "$d3")"

# 4. Marker on disk with the full declaration → gate open for subsequent edits.
mkdir -p "$HB_OUT/agentic-os"
printf 'Routing: fix\nLessons: none match\nLinear gate: none — single-step\n' > "$DT_GATE"
d4="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$DT_FIX" "$DT_SID")")"
assert_eq "session-agent/desktop: marker on disk allows" "allow" "$(classify_block "$d4")"

# 5. Marker content without a line-anchored declaration does NOT open the gate.
printf 'no declaration here\n' > "$DT_GATE"
d5="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$DT_FIX" "$DT_SID")")"
assert_eq "session-agent/desktop: declaration-less marker blocks" "block" "$(classify_block "$d5")"

# 5b. A bare `Linear gate:` with no disposition value is not a declaration
#     — neither on disk nor in a marker Write (panel finding).
printf 'Linear gate:\n' > "$DT_GATE"
d5b="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$DT_FIX" "$DT_SID")")"
assert_eq "session-agent/desktop: bare value-less marker blocks" "block" "$(classify_block "$d5b")"
d5c_input="$(jq -nc --arg p "$DT_GATE" '{file_path: $p, content: "Linear gate:"}')"
d5c="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$DT_FIX" "$DT_SID" Write "$d5c_input")")"
assert_eq "session-agent/desktop: value-less marker write blocks" "block" "$(classify_block "$d5c")"

# 5d. A whitespace-padded session_id keys the SAME marker path the directive
#     publishes (both sides trim — panel finding).
printf 'Lessons: none match\nLinear gate: none — single-step\n' > "$DT_GATE"
d5d="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$DT_FIX" "  $DT_SID  ")")"
assert_eq "session-agent/desktop: padded session id still keys the marker" "allow" "$(classify_block "$d5d")"

# 5e. The declaration contract is BOTH lines on the marker channel too — a
#     marker carrying only `Linear gate:` (no `Lessons:`) blocks, on disk and
#     as a Write.
printf 'Routing: fix\nLinear gate: none — single-step\n' > "$DT_GATE"
d5e="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$DT_FIX" "$DT_SID")")"
assert_eq "session-agent/desktop: lessons-less marker on disk blocks" "block" "$(classify_block "$d5e")"
d5f_input="$(jq -nc --arg p "$DT_GATE" '{file_path: $p, content: "Routing: fix\nLinear gate: none — single-step\n"}')"
d5f="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$DT_FIX" "$DT_SID" Write "$d5f_input")")"
assert_eq "session-agent/desktop: lessons-less marker write blocks" "block" "$(classify_block "$d5f")"

# 5g. Asymmetric case (panel finding): a proper `Linear gate:` plus a
#     LOWERCASE `lessons:` blocks — pins the Lessons pattern's
#     case-sensitivity independently of the Linear-gate pattern's.
printf 'Routing: fix\nlessons: none match\nLinear gate: none — single-step\n' > "$DT_GATE"
d5g="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$DT_FIX" "$DT_SID")")"
assert_eq "session-agent/desktop: lowercase-lessons asymmetric marker blocks" "block" "$(classify_block "$d5g")"

# 6. The marker NEVER substitutes for the Skill invocation itself — a session
#    with a valid marker but no session-agent run still blocks.
printf 'Lessons: none match\nLinear gate: none — single-step\n' > "$DT_GATE"
d6="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$fix/transcript-empty.jsonl" "$DT_SID")")"
assert_eq "session-agent/desktop: marker w/o skill run blocks" "block" "$(classify_block "$d6")"
rm -f "$DT_GATE"

# 7. Stale markers (>7 days) are reaped on the next hook run.
DT_STALE="$HB_OUT/agentic-os/gate-stale-9999"
printf 'Lessons: none match\nLinear gate: none — single-step\n' > "$DT_STALE"
touch -t 202601010000 "$DT_STALE"
run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$DT_FIX" "$DT_SID")" >/dev/null
if [[ -f "$DT_STALE" ]]; then dt_reap="stale-remains"; else dt_reap="reaped"; fi
assert_eq "session-agent/desktop: stale marker reaped" "reaped" "$dt_reap"

# 8. A path-escaping session_id disables the marker channel instead of
#    resolving outside the state dir (CLI transcript behavior still applies).
d8="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(dtp "$DT_FIX" "../../evil")")"
assert_eq "session-agent/desktop: hostile session_id still blocks" "block" "$(classify_block "$d8")"
assert_not_contains "session-agent/desktop: hostile id never echoed as path" "${d8#*|}" "agentic-os/gate-../../evil"

r5="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(session_agent_payload "$fix/transcript-empty.jsonl")" CLAUDE_SKIP_SESSION_AGENT=1)"
assert_eq "session-agent: kill switch allows" "allow" "$(classify_block "$r5")"

# explicit PreToolUse decision-shape contract. A block on this event
# MUST carry hookSpecificOutput with hookEventName=PreToolUse and
# permissionDecision=deny, and MUST NOT use the legacy top-level
# {"decision":"block"} form (the modern shape is the only PreToolUse-honored
# block channel). r2 is the no-routing block path; assert the exact emitted
# JSON shape.
assert_contains     "session-agent: block emits hookSpecificOutput"      "${r2#*|}" '"hookSpecificOutput"'
assert_contains     "session-agent: block names PreToolUse event"        "${r2#*|}" '"hookEventName":"PreToolUse"'
assert_contains     "session-agent: block uses permissionDecision deny"  "${r2#*|}" '"permissionDecision":"deny"'
assert_contains     "session-agent: block carries permissionDecisionReason" "${r2#*|}" '"permissionDecisionReason"'
assert_not_contains "session-agent: block drops legacy decision form"    "${r2#*|}" '"decision":"block"'
# Structural (not just substring) validation: the emitted text must be a single
# JSON object whose hookSpecificOutput nests the right event + decision. Guards
# against a malformed object / wrong nesting / the strings appearing only inside
# a free-text reason. (Cross-model review F4.)
r2_shape_ok="$(printf '%s' "${r2#*|}" | jq -e '.hookSpecificOutput.hookEventName=="PreToolUse" and .hookSpecificOutput.permissionDecision=="deny" and (.hookSpecificOutput.permissionDecisionReason|type=="string")' >/dev/null 2>&1 && echo ok || echo bad)"
assert_eq "session-agent: block JSON is structurally valid PreToolUse deny" "ok" "$r2_shape_ok"

# (cross-model review F2) — deny must fail CLOSED even when jq passes
# `command -v` but FAILS at runtime (broken binary / construction error). A jq
# whose `-nc` invocation errors must NOT make deny emit nothing (silent allow);
# the static fallback deny string keeps the gate closed. BROKENJQ_BIN shims a jq
# that works for `-r` (transcript extraction) but exits non-zero for `-nc`.
BROKENJQ_BIN="$(mktemp -d)"
for _b in bash cat grep sed git env printf; do
  _p="$(command -v "$_b" 2>/dev/null)" && ln -s "$_p" "$BROKENJQ_BIN/$_b"
done
_realjq="$(command -v jq)"
cat > "$BROKENJQ_BIN/jq" <<EOF
#!/bin/sh
case "\$*" in
  *"-nc"*) exit 5 ;;
  *) exec "$_realjq" "\$@" ;;
esac
EOF
chmod +x "$BROKENJQ_BIN/jq"
bj1="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(session_agent_payload "$fix/transcript-empty.jsonl")" PATH="$BROKENJQ_BIN")"
assert_eq        "session-agent: runtime-broken jq exits 0"                   "0" "${bj1%%|*}"
assert_eq        "session-agent: runtime-broken jq still blocks (fail-closed)" "block" "$(classify_block "$bj1")"
assert_contains  "session-agent: runtime-broken jq emits static deny fallback" "${bj1#*|}" '"permissionDecision":"deny"'
rm -rf "$BROKENJQ_BIN"

# ---------------------------------------------------------------------------
# framework-surface.sh (SessionStart)
# agentic-os-template has commits in window -> exit 0, emits additionalContext JSON
# CLAUDE_SKIP_FRAMEWORK_SURFACE=1 -> exit 0, silent
# ---------------------------------------------------------------------------
f1="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq "framework-surface: emits context exits 0" "0" "${f1%%|*}"
assert_contains "framework-surface: emits additionalContext" "${f1#*|}" "additionalContext"

f2="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' CLAUDE_SKIP_FRAMEWORK_SURFACE=1)"
assert_eq "framework-surface: kill switch is silent" "" "${f2#*|}"

# ---------------------------------------------------------------------------
# framework-surface session-agent invocation directive (auto-fire).
# default -> probe emits the SA_BLOCK header
# CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1 -> SA_BLOCK omitted; git-log preserved
# ---------------------------------------------------------------------------
fs_sa1="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq          "framework-surface: session-agent directive exits 0"      "0"                              "${fs_sa1%%|*}"
assert_contains    "framework-surface: emits session-agent directive header" "${fs_sa1#*|}" "Session-agent — invoke now"
assert_contains    "framework-surface: directive references Mode 1"          "${fs_sa1#*|}" "Mode 1"
assert_contains    "framework-surface: directive references session-agent"   "${fs_sa1#*|}" "session-agent"

fs_sa2="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' \
  CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1 CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq           "framework-surface: SA-directive kill switch exits 0"      "0"                              "${fs_sa2%%|*}"
assert_not_contains "framework-surface: SA-directive kill switch drops block"  "${fs_sa2#*|}" "Session-agent — invoke now"
assert_contains     "framework-surface: SA-directive kill switch keeps git-log" "${fs_sa2#*|}" "additionalContext"

# ---------------------------------------------------------------------------
# compaction/resume-aware session-agent directive. SessionStart
# re-fires with source=compact|resume after a compaction/resume; on those
# sources the directive must be the IDEMPOTENT re-orient (re-run Mode 1 only
# if orient outputs are gone, else Mode 2) — NOT the stock "first action this
# session" kickoff, whose skip-condition could suppress re-orienting exactly
# when the orient context was just compacted away. startup/clear/absent-source
# keep the kickoff directive (== prior behavior).
# ---------------------------------------------------------------------------
fs_compact="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{"source":"compact"}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq           "framework-surface: compact directive exits 0"             "0"            "${fs_compact%%|*}"
assert_contains     "framework-surface: compact emits re-orient header"        "${fs_compact#*|}" "re-orient after compacted session"
assert_contains     "framework-surface: compact directive references Mode 1"   "${fs_compact#*|}" "Mode 1"
assert_contains     "framework-surface: compact directive references Mode 2"   "${fs_compact#*|}" "Mode 2"
assert_not_contains "framework-surface: compact drops the kickoff header"      "${fs_compact#*|}" "invoke now (Mode 1: kickoff orient)"

fs_startup="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{"source":"startup"}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_contains     "framework-surface: explicit startup keeps kickoff header" "${fs_startup#*|}" "Session-agent — invoke now"
assert_not_contains "framework-surface: startup drops the re-orient header"    "${fs_startup#*|}" "re-orient after"

# Malformed / unparseable event JSON → SESSION_SOURCE empty → kickoff (the safe
# default; the hook stays exit-0 fail-open, never crashing on bad stdin). Guards
# the stdin-parse path against a regression that drops orientation.
fs_bad="$(run_hook "$GEN_HOOKS/framework-surface.sh" 'not-json{' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq           "framework-surface: malformed source JSON exits 0"         "0"            "${fs_bad%%|*}"
assert_contains     "framework-surface: malformed source JSON keeps kickoff"   "${fs_bad#*|}" "Session-agent — invoke now"
assert_not_contains "framework-surface: malformed source JSON drops re-orient" "${fs_bad#*|}" "re-orient after"

# ---------------------------------------------------------------------------
# framework-surface MCP-health probe.
# stub `claude mcp list` -> probe lists ✓ Connected MCPs in additionalContext
# probe omits "! Needs authentication" lines (not the failure mode we surface)
# advisory text references + the companion memory note
# CLAUDE_SKIP_MCP_PROBE=1 -> probe block omitted, git-log block preserved
# claude CLI absent -> probe block silently omitted, git-log preserved
# ---------------------------------------------------------------------------
QM_STUB="$(mktemp -d)"
# Symlink core utilities so the stub PATH is self-contained for the hook.
# `printf` deliberately excluded — it's a bash builtin (and `command -v printf`
# returns the bare name, not a path), so `ln -s` would create a self-referential
# symlink. Bash uses its internal builtin regardless, so the symlink is inert
# and just confusing. (Cross-model review 2026-05-24-t-59-pr14, Gemini F1.)
for _b in bash cat grep sed jq env git find awk tr sort uniq wc head tail; do
  _p="$(command -v "$_b" 2>/dev/null)" && ln -s "$_p" "$QM_STUB/$_b"
done
# Stub `claude` that returns a deterministic `claude mcp list` shape.
cat > "$QM_STUB/claude" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "list" ]; then
  cat <<MCP
Checking MCP server health…

claude.ai Linear: https://mcp.linear.app/mcp - ✓ Connected
claude.ai Stripe: https://mcp.stripe.com - ! Needs authentication
claude.ai HubSpot: https://mcp.hubspot.com - ✓ Connected
plugin:context7:context7: npx -y @upstash/context7-mcp - ✓ Connected
MCP
  exit 0
fi
exit 0
STUB
chmod +x "$QM_STUB/claude"

# Probe surfaces ✓ Connected MCPs, drops "Needs authentication" lines.
fp1="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' \
  CLAUDE_FRAMEWORK_SINCE_DAYS=3650 PATH="$QM_STUB:$PATH")"
assert_eq          "framework-surface: probe exits 0"                "0"                              "${fp1%%|*}"
assert_contains    "framework-surface: probe emits MCP block header" "${fp1#*|}" "MCP connectors"
assert_contains    "framework-surface: probe surfaces Linear"        "${fp1#*|}" "Linear"
assert_contains    "framework-surface: probe surfaces HubSpot"       "${fp1#*|}" "HubSpot"
assert_contains    "framework-surface: probe surfaces plugin MCPs"   "${fp1#*|}" "context7"
assert_not_contains "framework-surface: probe excludes Needs-auth"   "${fp1#*|}" "Stripe"
assert_contains    "framework-surface: probe flags the silent-empty-tools case" "${fp1#*|}" "silent-empty-tools"
assert_contains    "framework-surface: probe links memory note"      "${fp1#*|}" "reference_mcp_silent_empty_tools"

# Probe kill switch suppresses MCP block but preserves git-log surfacing.
fp2="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' \
  CLAUDE_SKIP_MCP_PROBE=1 CLAUDE_FRAMEWORK_SINCE_DAYS=3650 PATH="$QM_STUB:$PATH")"
assert_eq           "framework-surface: probe kill switch exits 0"      "0"                              "${fp2%%|*}"
assert_not_contains "framework-surface: probe kill switch drops block"  "${fp2#*|}" "MCP connectors"
assert_contains     "framework-surface: probe kill switch keeps git-log" "${fp2#*|}" "additionalContext"

# Claude CLI absent — probe silently omits, git-log still emits.
NO_CLAUDE_BIN="$(mktemp -d)"
for _b in bash cat grep sed jq env git find awk tr sort uniq wc head tail; do
  _p="$(command -v "$_b" 2>/dev/null)" && ln -s "$_p" "$NO_CLAUDE_BIN/$_b"
done
fp3="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' \
  CLAUDE_FRAMEWORK_SINCE_DAYS=3650 PATH="$NO_CLAUDE_BIN")"
assert_eq           "framework-surface: no-claude exits 0"          "0"                              "${fp3%%|*}"
assert_not_contains "framework-surface: no-claude omits MCP block"  "${fp3#*|}" "MCP connectors"
assert_contains     "framework-surface: no-claude keeps git-log"    "${fp3#*|}" "additionalContext"

# Edge case: all MCPs are ! Needs authentication — no ✓ Connected lines exist.
# Probe should omit the MCP block silently, hook still exits 0. Covers Codex
# MT1 + the "grep no-match" fail-open contract.
cat > "$QM_STUB/claude" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "list" ]; then
  cat <<MCP
Checking MCP server health…

claude.ai Linear: https://mcp.linear.app/mcp - ! Needs authentication
claude.ai HubSpot: https://mcp.hubspot.com - ! Needs authentication
MCP
  exit 0
fi
exit 0
STUB
fp4="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' \
  CLAUDE_FRAMEWORK_SINCE_DAYS=3650 PATH="$QM_STUB:$PATH")"
assert_eq           "framework-surface: all-disconnected exits 0"          "0"                              "${fp4%%|*}"
assert_not_contains "framework-surface: all-disconnected omits MCP block"  "${fp4#*|}" "MCP connectors"
assert_contains     "framework-surface: all-disconnected keeps git-log"    "${fp4#*|}" "additionalContext"

# Edge case: malformed nonempty output from claude mcp list. Probe should
# parse cleanly, find no ✓ Connected lines, omit the MCP block, exit 0.
# Covers Codex MT3 + Gemini MT2 parse-error fail-open contract.
cat > "$QM_STUB/claude" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "list" ]; then
  printf 'random nonsense output\nwith multiple lines\nand no recognizable format\n'
  exit 0
fi
exit 0
STUB
fp5="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' \
  CLAUDE_FRAMEWORK_SINCE_DAYS=3650 PATH="$QM_STUB:$PATH")"
assert_eq           "framework-surface: malformed output exits 0"          "0"                              "${fp5%%|*}"
assert_not_contains "framework-surface: malformed output omits MCP block"  "${fp5#*|}" "MCP connectors"
assert_contains     "framework-surface: malformed output keeps git-log"    "${fp5#*|}" "additionalContext"

rm -rf "$NO_CLAUDE_BIN" "$QM_STUB"

# ---------------------------------------------------------------------------
# framework-surface orphaned operator-local hook check (block 1c).
# settings.local.json lives at <install>/settings.local.json (beside hooks/).
# missing hook file -> warns + names the path; present -> silent; kill switch
# suppresses. Created in the rendered install dir, removed after so it cannot
# leak into the freshness assertions below.
HB_LOCAL_SETTINGS="$HB_OUT/settings.local.json"
cat > "$HB_LOCAL_SETTINGS" <<'JSON'
{ "hooks": { "SessionStart": [ { "matcher": "startup", "hooks": [ { "type": "command", "command": "/nonexistent/aos-test-missing-hook.sh" } ] } ] } }
JSON
fl1="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq       "framework-surface: orphaned-hook check exits 0"        "0" "${fl1%%|*}"
assert_contains "framework-surface: warns on missing local hook script" "${fl1#*|}" "Operator-local hook is missing"
assert_contains "framework-surface: names the missing hook path"        "${fl1#*|}" "/nonexistent/aos-test-missing-hook.sh"

# kill switch suppresses the orphaned-hook block but preserves git-log surfacing.
fl2="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' \
  CLAUDE_FRAMEWORK_SINCE_DAYS=3650 CLAUDE_SKIP_LOCAL_HOOK_CHECK=1)"
assert_eq           "framework-surface: orphaned-hook kill switch exits 0"     "0" "${fl2%%|*}"
assert_not_contains "framework-surface: orphaned-hook kill switch drops block" "${fl2#*|}" "Operator-local hook is missing"
assert_contains     "framework-surface: orphaned-hook kill switch keeps git-log" "${fl2#*|}" "additionalContext"

# present hook file -> the block stays silent (point at a file that exists).
cat > "$HB_LOCAL_SETTINGS" <<JSON
{ "hooks": { "SessionStart": [ { "matcher": "startup", "hooks": [ { "type": "command", "command": "$GEN_HOOKS/framework-surface.sh" } ] } ] } }
JSON
fl3="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq           "framework-surface: present local hook exits 0"        "0" "${fl3%%|*}"
assert_not_contains "framework-surface: present local hook stays silent"   "${fl3#*|}" "Operator-local hook is missing"

# no settings.local.json -> silent (fail-open).
rm -f "$HB_LOCAL_SETTINGS"
fl4="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq           "framework-surface: no settings.local.json exits 0"    "0" "${fl4%%|*}"
assert_not_contains "framework-surface: no settings.local.json stays silent" "${fl4#*|}" "Operator-local hook is missing"

# Regression (cross-model review): an EXISTING hook under a path WITH A SPACE must
# stay silent. When the config dir's folder name contains a space, truncating the
# command at the first space used to false-positive on a perfectly-present hook.
HB_SPACE_DIR="$(mktemp -d)/with space"; mkdir -p "$HB_SPACE_DIR"; : > "$HB_SPACE_DIR/hook.sh"
cat > "$HB_LOCAL_SETTINGS" <<JSON
{ "hooks": { "SessionStart": [ { "matcher": "startup", "hooks": [ { "type": "command", "command": "$HB_SPACE_DIR/hook.sh" } ] } ] } }
JSON
fl5="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_not_contains "framework-surface: existing spaced-path hook stays silent" "${fl5#*|}" "Operator-local hook is missing"

# a MISSING hook under a spaced path warns, naming the FULL path (not truncated).
cat > "$HB_LOCAL_SETTINGS" <<JSON
{ "hooks": { "SessionStart": [ { "matcher": "startup", "hooks": [ { "type": "command", "command": "$HB_SPACE_DIR/gone.sh" } ] } ] } }
JSON
fl6="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_contains "framework-surface: missing spaced-path hook warns"           "${fl6#*|}" "Operator-local hook is missing"
assert_contains "framework-surface: missing spaced-path hook names full path"  "${fl6#*|}" "$HB_SPACE_DIR/gone.sh"

# multiple missing hooks -> both named.
cat > "$HB_LOCAL_SETTINGS" <<'JSON'
{ "hooks": { "SessionStart": [ { "matcher": "startup", "hooks": [ { "type": "command", "command": "/nonexistent/one.sh" }, { "type": "command", "command": "/nonexistent/two.sh" } ] } ] } }
JSON
fl7="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_contains "framework-surface: multi-missing names first"  "${fl7#*|}" "/nonexistent/one.sh"
assert_contains "framework-surface: multi-missing names second" "${fl7#*|}" "/nonexistent/two.sh"

# a RELATIVE-path command is out of scope -> silent (no cwd-dependent false pos).
cat > "$HB_LOCAL_SETTINGS" <<'JSON'
{ "hooks": { "SessionStart": [ { "matcher": "startup", "hooks": [ { "type": "command", "command": "relative/nope.sh" } ] } ] } }
JSON
fl8="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_not_contains "framework-surface: relative-path command stays silent" "${fl8#*|}" "Operator-local hook is missing"

# malformed / odd-shape settings.local.json all fail open (silent, exit 0).
printf '' > "$HB_LOCAL_SETTINGS"
fl9="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq           "framework-surface: empty settings.local.json exits 0"      "0" "${fl9%%|*}"
assert_not_contains "framework-surface: empty settings.local.json stays silent" "${fl9#*|}" "Operator-local hook is missing"
printf 'not json {' > "$HB_LOCAL_SETTINGS"
fl10="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq           "framework-surface: invalid-JSON settings exits 0"      "0" "${fl10%%|*}"
assert_not_contains "framework-surface: invalid-JSON settings stays silent" "${fl10#*|}" "Operator-local hook is missing"
printf '{ "hooks": [1,2,3] }' > "$HB_LOCAL_SETTINGS"
fl11="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq           "framework-surface: odd-shape .hooks exits 0"      "0" "${fl11%%|*}"
assert_not_contains "framework-surface: odd-shape .hooks stays silent" "${fl11#*|}" "Operator-local hook is missing"

rm -rf "$HB_LOCAL_SETTINGS" "$HB_SPACE_DIR"

# ---------------------------------------------------------------------------
# framework-surface config-freshness nudge.
# fresh install -> no freshness block
# stale install (a recorded source hash no longer matches the repo)
# -> hook surfaces the nudge naming the stale source
# CLAUDE_SKIP_FRESHNESS_CHECK=1 -> nudge suppressed, git-log preserved
# The fresh build ($HB_OUT) was rendered from this repo above, so its manifest
# sources match → no nudge. To exercise the stale path we copy the built target
# and corrupt one recorded SOURCE hash (a real re-install is expensive; copying
# the throwaway target is not). The hook's @@AI_CONFIG_DIR@@ is already
# substituted to the repo root, so check-freshness compares the corrupted
# manifest against the live repo file and reports it stale.
# ---------------------------------------------------------------------------
fr0="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_not_contains "framework-surface: fresh install omits freshness nudge" "${fr0#*|}" "Installed config is stale"

if command -v jq >/dev/null 2>&1; then
  FRESH_COPY="$(mktemp -d)/target"
  cp -R "$HB_OUT" "$FRESH_COPY"
  fr_tmp="$(mktemp)"
  jq '.sources["capabilities/README.md"]="0000000000000000000000000000000000000000000000000000000000000000"' \
    "$FRESH_COPY/.build-manifest.json" > "$fr_tmp" && mv "$fr_tmp" "$FRESH_COPY/.build-manifest.json"

  fr1="$(run_hook "$FRESH_COPY/hooks/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
  assert_eq       "framework-surface: stale install exits 0"                   "0" "${fr1%%|*}"
  assert_contains "framework-surface: stale install surfaces freshness nudge"  "${fr1#*|}" "Installed config is stale"
  assert_contains "framework-surface: freshness nudge names the stale source"  "${fr1#*|}" "capabilities/README.md"

  fr2="$(run_hook "$FRESH_COPY/hooks/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650 CLAUDE_SKIP_FRESHNESS_CHECK=1)"
  assert_not_contains "framework-surface: freshness kill switch drops nudge"   "${fr2#*|}" "Installed config is stale"
  assert_contains     "framework-surface: freshness kill switch keeps git-log" "${fr2#*|}" "additionalContext"
  rm -rf "$FRESH_COPY"
else
  _skip "framework-surface: stale install exits 0" "jq unavailable"
  _skip "framework-surface: stale install surfaces freshness nudge" "jq unavailable"
  _skip "framework-surface: freshness nudge names the stale source" "jq unavailable"
  _skip "framework-surface: freshness kill switch drops nudge" "jq unavailable"
  _skip "framework-surface: freshness kill switch keeps git-log" "jq unavailable"
fi

# ---------------------------------------------------------------------------
# F3 — jq contract: the gate hook (session-agent) fails CLOSED when jq is
# absent from the hook PATH; the surfacing hook (framework-surface) fails OPEN.
# NOJQ_BIN is a PATH dir with the common utilities symlinked but jq omitted.
# ---------------------------------------------------------------------------
NOJQ_BIN="$(mktemp -d)"
for _b in bash cat grep sed git env printf; do
  _p="$(command -v "$_b" 2>/dev/null)" && ln -s "$_p" "$NOJQ_BIN/$_b"
done

# session-agent.sh — a transcript that WOULD normally allow still blocks without jq.
j1="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(session_agent_payload "$fix/transcript-session-agent-ok.jsonl")" PATH="$NOJQ_BIN")"
assert_eq "session-agent: no jq exits 0"               "0" "${j1%%|*}"
assert_eq "session-agent: no jq fails closed (blocks)" "block" "$(classify_block "$j1")"
# the jq-missing fail-closed path must ALSO emit the modern PreToolUse
# deny shape (a static string — no jq needed since the reason is a fixed
# literal), not the legacy no-op {"decision":"block"} form.
assert_contains     "session-agent: no jq emits PreToolUse deny shape" "${j1#*|}" '"permissionDecision":"deny"'
assert_not_contains "session-agent: no jq drops legacy decision form"  "${j1#*|}" '"decision":"block"'

# framework-surface.sh — surfacing hook fails open: exit 0, silent.
j3="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' PATH="$NOJQ_BIN" CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq "framework-surface: no jq exits 0"          "0" "${j3%%|*}"
assert_eq "framework-surface: no jq is silent (open)" "" "${j3#*|}"

rm -rf "$NOJQ_BIN"

# ---------------------------------------------------------------------------
# <TEAM>-364 — framework-surface distillation-lag nudge (block 2b). READ-ONLY
# kickoff surfacing of check-distillation-completeness.sh: a lapse (rc 1)
# names the undistilled notes; every other rc stays silent. Appended section —
# owns only the dn* fixtures/assertions below; MCP probe disabled throughout
# for a deterministic payload (its own coverage lives above).
# lapse (undistilled feedback note)  -> block header + note name, exit 0
# distilled (name in a lessons note) -> block absent
# CLAUDE_SKIP_DISTILLATION_NUDGE=1   -> block absent, git-log preserved
# unresolvable vault path            -> checker exit 2 -> silent, exit 0
# ---------------------------------------------------------------------------
DN_ROOT="$(mktemp -d)"
DN_CFG="$DN_ROOT/cfg"
DN_VAULT="$DN_ROOT/vault"
mkdir -p "$DN_CFG/projects/x/memory" "$DN_VAULT/04-Lessons"
# In-scope note: kebab slug + frontmatter `metadata:`-nested `type: feedback`
# (the shape the checker's frontmatter scan recognizes). MEMORY.md is always
# skipped by the checker.
cat > "$DN_CFG/projects/x/memory/feedback-test-lapse-note.md" <<'DN_NOTE'
---
title: test lapse note
metadata:
  type: feedback
---
A feedback note that has not been distilled into 04-Lessons.
DN_NOTE
printf '# Memory index\n' > "$DN_CFG/projects/x/memory/MEMORY.md"
printf '# Unrelated lesson\n\nNothing about that note here.\n' > "$DN_VAULT/04-Lessons/unrelated.md"

dn1="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' \
  CLAUDE_FRAMEWORK_SINCE_DAYS=3650 CLAUDE_SKIP_MCP_PROBE=1 \
  CLAUDE_CONFIG_DIR="$DN_CFG" OBSIDIAN_VAULT_PATH="$DN_VAULT")"
assert_eq       "framework-surface: distillation lapse exits 0"          "0" "${dn1%%|*}"
assert_contains "framework-surface: distillation lapse emits header"     "${dn1#*|}" "Distillation lag — 1 feedback/decision note(s) not yet distilled"
assert_contains "framework-surface: distillation lapse names the note"   "${dn1#*|}" "feedback-test-lapse-note"
assert_contains "framework-surface: distillation nudge says read-only"   "${dn1#*|}" "read-only lint"
assert_contains "framework-surface: distillation nudge names its switch" "${dn1#*|}" "CLAUDE_SKIP_DISTILLATION_NUDGE=1"

# Distilled: the note name recorded in a 04-Lessons note -> nudge absent
# (checker rc 0), git-log block untouched.
printf '# Thematic lesson\n\n## Source Notes\n\n- feedback-test-lapse-note\n' > "$DN_VAULT/04-Lessons/thematic-lesson.md"
dn2="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' \
  CLAUDE_FRAMEWORK_SINCE_DAYS=3650 CLAUDE_SKIP_MCP_PROBE=1 \
  CLAUDE_CONFIG_DIR="$DN_CFG" OBSIDIAN_VAULT_PATH="$DN_VAULT")"
assert_eq           "framework-surface: distilled note exits 0"          "0" "${dn2%%|*}"
assert_not_contains "framework-surface: distilled note drops the nudge"  "${dn2#*|}" "Distillation lag"
assert_contains     "framework-surface: distilled case keeps git-log"    "${dn2#*|}" "additionalContext"

# Kill switch: lapse restored, nudge suppressed, git-log preserved.
rm -f "$DN_VAULT/04-Lessons/thematic-lesson.md"
dn3="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' \
  CLAUDE_FRAMEWORK_SINCE_DAYS=3650 CLAUDE_SKIP_MCP_PROBE=1 CLAUDE_SKIP_DISTILLATION_NUDGE=1 \
  CLAUDE_CONFIG_DIR="$DN_CFG" OBSIDIAN_VAULT_PATH="$DN_VAULT")"
assert_eq           "framework-surface: distillation kill switch exits 0"     "0" "${dn3%%|*}"
assert_not_contains "framework-surface: distillation kill switch drops nudge" "${dn3#*|}" "Distillation lag"
assert_contains     "framework-surface: distillation kill switch keeps git-log" "${dn3#*|}" "additionalContext"

# Unresolvable vault (nonexistent dir) -> checker exits 2 -> fail-open silent.
dn4="$(run_hook "$GEN_HOOKS/framework-surface.sh" '{}' \
  CLAUDE_FRAMEWORK_SINCE_DAYS=3650 CLAUDE_SKIP_MCP_PROBE=1 \
  CLAUDE_CONFIG_DIR="$DN_CFG" OBSIDIAN_VAULT_PATH="$DN_ROOT/nope")"
assert_eq           "framework-surface: unresolvable vault exits 0"        "0" "${dn4%%|*}"
assert_not_contains "framework-surface: unresolvable vault stays silent"   "${dn4#*|}" "Distillation lag"
assert_contains     "framework-surface: unresolvable vault keeps git-log"  "${dn4#*|}" "additionalContext"

rm -rf "$DN_ROOT"

rm -rf "$HB_OUT"
