#!/usr/bin/env bash
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
# session-agent + Linear gate -> exit 0, allow
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
assert_eq "session-agent: invoked+Linear exits 0" "0" "${r3%%|*}"
assert_eq "session-agent: invoked+Linear allows"  "allow" "$(classify_block "$r3")"

r4="$(run_hook "$GEN_HOOKS/session-agent.sh" "$(session_agent_payload "$fix/transcript-session-agent-no-linear.jsonl")")"
assert_eq "session-agent: invoked w/o Linear blocks" "block" "$(classify_block "$r4")"

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

rm -rf "$HB_OUT"
