#!/usr/bin/env bash
# Session-agent enforcement hook (Cursor `preToolUse` event, matcher Write).
# Blocks the first file-modifying tool use of a conversation unless the
# session-agent capability ran and a complete routing declaration exists —
# BOTH the `Linear gate:` line (active-work disposition) and the `Lessons:`
# line (recall outcome: matched lesson names, `none match`, or `index
# unreachable`).
# SAFETY NET — primary auto-fire is the sessionStart directive emitted by
# framework-surface.sh.
#
# Enforcement class: pre-edit-gate (see harnesses/cursor/adapter.md).
# Kill switch: set CLAUDE_SKIP_SESSION_AGENT=1 to disable (same env name as the
# Claude harness — one kill switch works regardless of harness).
#
# stdin:  preToolUse hook event JSON
#         {tool_name, tool_input, tool_use_id, cwd, conversation_id, ...}
# stdout: {"permission":"allow"} or
#         {"permission":"deny","user_message":"...","agent_message":"..."}
# exit:   always 0 (the JSON carries the decision)
#
# CURSOR FAIL-OPEN CONTRACT — read before editing:
#   Cursor treats exit 0 as "use the JSON", exit 2 as a hard block, and ANY
#   OTHER exit code as a hook failure whose action PROCEEDS (fail-open). That
#   default is the opposite of what a gate wants, so the gate is hardened on
#   two independent layers:
#     1. the generated hooks.json entry sets "failClosed": true, so a crash,
#        timeout, or invalid JSON blocks instead of passing;
#     2. THIS SCRIPT denies on every error path of its own — missing jq,
#        unreadable payload, absent conversation id. Never `exit 0` silently
#        from an error branch; emit a deny.
#   The deny SHAPE is live-verified (2026-08-18, headless `agent -p`): a
#   {"permission":"deny",...} response really did stop a Write — the file was
#   never created and the agent surfaced agent_message. What is still unverified
#   is whether Cursor honors `failClosed` on preToolUse specifically
#   (adapter.md U-A), which is why layer 2 exists.
#
#   `permission: "ask"` is accepted by Cursor's schema but is NOT enforced on
#   preToolUse (docs 2026-08-18) — it silently becomes an allow. Never emit it
#   from this hook; `deny` is the only reliable block.
#
# Detection — the gate-file channel, the portable marker Claude and Hermes
# already share:
#   1. GATE FILE — the session-agent realization instructs the model to declare
#      the gate by writing `<config>/agentic-os/gate-<conversation_id>`, body
#      carrying the full declaration (`Linear gate:` AND `Lessons:` lines).
#      This hook ALLOWS exactly that write pre-gate, then later calls find the
#      marker on disk.
#   2. The `Shell` tool is outside this hook's matcher, so a shell-driven write
#      of the same marker also works — the documented fallback if a future
#      Write payload shape hides the content from the sweep below.
# Cursor DOES expose a per-conversation transcript (`transcript_path`, JSONL
# under <config>/projects/<slug>/agent-transcripts/ — live-verified
# 2026-08-18), so a transcript-parsing marker is possible on this harness. The
# gate file is chosen anyway: it is the contract three harnesses already
# implement, and it does not depend on an undocumented file format.

set -uo pipefail

if [[ "${CLAUDE_SKIP_SESSION_AGENT:-0}" == "1" ]]; then
  printf '{"permission":"allow"}\n'
  exit 0
fi

# jq contract — gate hook, fails CLOSED. deny() needs jq, so emit a static deny
# shape when jq is absent rather than exiting non-zero (a non-2 exit would be
# fail-OPEN on Cursor, which is exactly the trap this guards).
if ! command -v jq >/dev/null 2>&1; then
  cat <<'EOF'
{"permission":"deny","user_message":"agentic-os session-agent gate: jq was not found on the hook PATH; the gate fails closed.","agent_message":"The session-agent enforcement hook cannot run: `jq` was not found on the hook PATH. The gate fails closed. Install jq, or set env CLAUDE_SKIP_SESSION_AGENT=1 to bypass enforcement."}
EOF
  exit 0
fi

allow() { printf '{"permission":"allow"}\n'; exit 0; }

deny() {
  jq -nc --arg r "$1" \
    '{permission: "deny", user_message: "agentic-os session-agent gate: blocked (see the agent message for the fix).", agent_message: $r}'
  exit 0
}

INPUT="$(cat)"

# An unparseable payload is an error path — deny, never fall through.
if ! printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  deny "The session-agent enforcement hook could not parse its preToolUse payload as a JSON object. The gate fails closed. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
fi

# `conversation_id` is the stable per-conversation id (the sessionStart event
# calls the same value `session_id`); accept either spelling so the marker key
# is identical no matter which field a given Cursor build populates.
CONV_ID="$(printf '%s' "$INPUT" | jq -r '.conversation_id // .session_id // empty')"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"

if [[ -z "$CONV_ID" ]]; then
  deny "The session-agent enforcement hook found no conversation_id in the preToolUse payload, so it cannot key the per-conversation gate marker. The gate fails closed. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
fi

# A conversation id is interpolated into a filesystem path below. Cursor's ids
# are opaque strings; refuse anything carrying a path separator or a dot-segment
# so a hostile/degenerate id cannot escape the state dir.
case "$CONV_ID" in
  */*|*\\*|.|..) deny "The session-agent enforcement hook refuses a conversation_id containing a path separator. The gate fails closed. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1." ;;
esac

# Config-home resolution: hooks are installed at <config>/hooks/, so the
# script's own parent is the authoritative home; the env var is the fallback.
# (Cursor's own CLI reads CURSOR_CONFIG_DIR for cli-config.json relocation; the
# framework build target uses the same variable by design — adapter.md.)
CHOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
[[ -n "$CHOME" ]] || CHOME="${CURSOR_CONFIG_DIR:-$HOME/.cursor}"
STATE_DIR="$CHOME/agentic-os"
GATE_FILE="$STATE_DIR/gate-$CONV_ID"

# Reap stale gate markers (old conversations); never fails the hook.
find "$STATE_DIR" -name 'gate-*' -mtime +7 -delete 2>/dev/null || true

# 1. Gate already declared for this conversation (marker on disk carrying both
#    contract lines — line-anchored, case-sensitive, non-empty value after the
#    colon, so prose that merely MENTIONS the phrases does not open the gate).
if [[ -f "$GATE_FILE" ]] \
    && grep -qE '^[[:space:]]*Linear gate:[[:space:]]*[^[:space:]]' "$GATE_FILE" 2>/dev/null \
    && grep -qE '^[[:space:]]*Lessons:[[:space:]]*[^[:space:]]' "$GATE_FILE" 2>/dev/null; then
  allow
fi

# 2. The gate-declaration write itself is allowed through.
#
#    A Write call carries `tool_input.file_path` + `tool_input.content`
#    (live-verified 2026-08-18, headless `agent -p`), but Cursor's docs specify
#    `tool_input` only for the Shell tool, so the shape is not contractual and
#    an IDE-side or future build could differ. Rather than depend on those two
#    keys, sweep EVERY string value in tool_input: a call is a gate-declaration
#    write when some string carries the gate path, and the declaration lines are
#    sought across the joined strings. The verified keys are a strict subset of
#    that sweep, so this is both correct today and shape-agnostic tomorrow — and
#    it degrades to a deny-with-explanation rather than a silent allow.
if [[ "$TOOL" == "Write" ]]; then
  TI_STRINGS="$(printf '%s' "$INPUT" | jq -r '[.tool_input? | .. | strings] | join("\n")' 2>/dev/null || printf '')"
  if [[ -n "$TI_STRINGS" ]] && printf '%s\n' "$TI_STRINGS" | grep -qF -- "$GATE_FILE"; then
    if printf '%s\n' "$TI_STRINGS" | grep -qE '^[[:space:]]*Linear gate:[[:space:]]*[^[:space:]]' \
        && printf '%s\n' "$TI_STRINGS" | grep -qE '^[[:space:]]*Lessons:[[:space:]]*[^[:space:]]'; then
      allow
    fi
    deny "The gate file must carry the routing declaration — include the full \`Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted\` line AND the \`Lessons: <matched lesson names> | none match | index unreachable | skipped — <reason>\` line in its content. If this write already contained both lines, Cursor's Write tool payload did not expose them to the hook: write the marker with the \`Shell\` tool instead (Shell is outside this gate's matcher)."
  fi
fi

deny "First file-modifying tool use detected but the session-agent gate is not open for this conversation. Invoke \`/session-agent\` to walk the kickoff orient (Mode 1) then route the request (R1-R5, including the R1a lesson recall), and declare the gate by writing the file $GATE_FILE with the full routing declaration including the \`Linear gate:\` and \`Lessons:\` lines as its content. If the Write tool payload does not carry the content through, use the \`Shell\` tool — it is outside this gate's matcher. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
