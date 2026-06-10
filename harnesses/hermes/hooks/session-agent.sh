#!/usr/bin/env bash
# Session-agent enforcement hook (Hermes pre_tool_call event,
# matcher write_file|patch|terminal).
# Blocks the first file-modifying tool use of a session unless the
# session-agent capability ran and a `Linear gate:` declaration exists.
# SAFETY NET — primary auto-fire is via the on_session_start directive
# emitted by framework-surface.sh.
#
# Enforcement class: pre-edit-gate (see harnesses/hermes/adapter.md).
# Kill switch: set CLAUDE_SKIP_SESSION_AGENT=1 to disable (same env name as
# the Claude harness — one kill switch works regardless of harness).
#
# stdin:  pre_tool_call hook event JSON
#         {hook_event_name, tool_name, tool_input, session_id, cwd, extra}
# stdout: when blocking, {"decision":"block","reason":"..."} — the
#         Claude-Code-style legacy shape, which Hermes parses natively into
#         its block wire shape (verified v0.16.0, `hermes hooks test`)
# exit:   always 0
#
# Detection (Hermes stores transcripts in state.db, not files — two channels):
#   1. GATE FILE — the session-agent realization instructs the model to declare
#      the gate by writing `<HERMES_HOME>/agentic-os/gate-<session_id>` via the
#      write_file tool, body carrying the full `Linear gate:` line. This hook
#      ALLOWS exactly that write pre-gate (structured-field match — path +
#      content; no shell parsing), then later calls find the marker on disk.
#   2. state.db BACKSTOP — when sqlite3 is available, a read-only query for
#      this session's messages matching the skill-read marker
#      (skills/session-agent/SKILL.md) plus a `Linear gate:` line also opens
#      the gate (covers multi-turn sessions where the declaration is already
#      persisted, with no gate file written).

set -uo pipefail

if [[ "${CLAUDE_SKIP_SESSION_AGENT:-0}" == "1" ]]; then
  exit 0
fi

# jq contract — gate hook, fails CLOSED. The static legacy block shape below
# is parsed natively by Hermes (wire shape {"action":"block",...}).
if ! command -v jq >/dev/null 2>&1; then
  cat <<'EOF'
{"decision":"block","reason":"Session-agent enforcement hook cannot run: `jq` was not found on the hook PATH. The gate fails closed. Install jq, or set env CLAUDE_SKIP_SESSION_AGENT=1 to bypass enforcement."}
EOF
  exit 0
fi

block() {
  jq -nc --arg r "$1" '{decision: "block", reason: $r}'
  exit 0
}

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty')"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"

# No session id → cannot key the gate; stay silent rather than hard-block a
# synthetic payload (`hermes hooks test` sends one with a test session id).
[[ -n "$SESSION_ID" ]] || exit 0

# HERMES_HOME resolution: hooks are installed at <HERMES_HOME>/hooks/, so the
# script's own parent is the authoritative home; env is the fallback.
HHOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
[[ -n "$HHOME" ]] || HHOME="${HERMES_HOME:-$HOME/.hermes}"
STATE_DIR="$HHOME/agentic-os"
GATE_FILE="$STATE_DIR/gate-$SESSION_ID"

# Reap stale gate markers (old sessions); never fails the hook.
find "$STATE_DIR" -name 'gate-*' -mtime +7 -delete 2>/dev/null || true

# 1. The gate-declaration write itself is allowed through: write_file to the
#    exact per-session gate path with a `Linear gate:` line in the content.
if [[ "$TOOL" == "write_file" ]]; then
  WPATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.path // empty')"
  WCONTENT="$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty')"
  if [[ "$WPATH" == "$GATE_FILE" ]]; then
    if [[ "$WCONTENT" == *"Linear gate:"* ]]; then
      exit 0
    fi
    block "The gate file must carry the routing declaration — include the full \`Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted\` line in its content."
  fi
fi

# 2. Gate already declared this session (marker on disk).
if [[ -f "$GATE_FILE" ]] && grep -qF 'Linear gate:' "$GATE_FILE" 2>/dev/null; then
  exit 0
fi

# 3. state.db backstop — read-only; any failure falls through to the block.
DB="$HHOME/state.db"
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$DB" ]]; then
  HIT="$(sqlite3 -readonly "$DB" \
    "SELECT (SELECT COUNT(*) FROM messages WHERE session_id='${SESSION_ID//\'/\'\'}' AND content LIKE '%skills/session-agent/SKILL.md%') > 0 AND (SELECT COUNT(*) FROM messages WHERE session_id='${SESSION_ID//\'/\'\'}' AND content LIKE '%Linear gate:%') > 0;" \
    2>/dev/null || true)"
  if [[ "$HIT" == "1" ]]; then
    exit 0
  fi
fi

block "First file-modifying tool use detected but the session-agent gate is not open for this session. Invoke /session-agent to walk the kickoff orient (Mode 1) then route the request (R1-R5), and declare the gate by writing the file $GATE_FILE via the write_file tool with the full routing declaration including the \`Linear gate:\` line as its content. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
