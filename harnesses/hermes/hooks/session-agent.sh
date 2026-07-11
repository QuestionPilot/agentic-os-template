#!/usr/bin/env bash
# Session-agent enforcement hook (Hermes pre_tool_call event,
# matcher write_file|patch|terminal).
# Blocks the first file-modifying tool use of a session unless the
# session-agent capability ran and a complete routing declaration exists —
# BOTH the `Linear gate:` line (active-work disposition) and the `Lessons:`
# line (recall outcome: matched lesson names, `none match`, or `index
# unreachable`).
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
#      write_file tool, body carrying the full declaration (`Linear gate:` AND
#      `Lessons:` lines). This hook ALLOWS exactly that write pre-gate
#      (structured-field match — path + content; no shell parsing), then later
#      calls find the marker on disk.
#   2. state.db BACKSTOP — when sqlite3 is available, a read-only query for
#      this session's messages matching the skill-read marker
#      (skills/session-agent/SKILL.md, user/assistant rows) plus
#      ASSISTANT-authored line-anchored `Linear gate:` AND `Lessons:`
#      declarations also opens the gate (covers multi-turn sessions where the
#      declaration is already persisted, with no gate file written).

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
#    exact per-session gate path with both declaration lines in the content —
#    line-anchored, case-sensitive, and with a non-empty value after the colon
#    (panel finding: the earlier bare-substring match let prose that merely
#    MENTIONED the phrases open the gate; this aligns the Hermes marker
#    contract with the Claude twin's).
if [[ "$TOOL" == "write_file" ]]; then
  WPATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.path // empty')"
  WCONTENT="$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty')"
  if [[ "$WPATH" == "$GATE_FILE" ]]; then
    if printf '%s\n' "$WCONTENT" | grep -qE '^[[:space:]]*Linear gate:[[:space:]]*[^[:space:]]' \
        && printf '%s\n' "$WCONTENT" | grep -qE '^[[:space:]]*Lessons:[[:space:]]*[^[:space:]]'; then
      exit 0
    fi
    block "The gate file must carry the routing declaration — include the full \`Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted\` line AND the \`Lessons: <matched lesson names> | none match | index unreachable | skipped — <reason>\` line in its content."
  fi
fi

# 2. Gate already declared this session (marker on disk, both contract lines,
#    same line-anchored non-empty match as the write path).
if [[ -f "$GATE_FILE" ]] \
    && grep -qE '^[[:space:]]*Linear gate:[[:space:]]*[^[:space:]]' "$GATE_FILE" 2>/dev/null \
    && grep -qE '^[[:space:]]*Lessons:[[:space:]]*[^[:space:]]' "$GATE_FILE" 2>/dev/null; then
  exit 0
fi

# 3. state.db backstop — read-only; any failure falls through to the block.
# Role-filtered + line-anchored: an any-row LIKE was vacuous —
# the skill body alone (one tool/user row carrying both the SKILL.md path and
# the `Linear gate:` template lines) satisfied both patterns, and a prior deny
# from this very hook quotes the phrase too. The ran-marker accepts user- or
# assistant-authored rows (the body injection / the model reading it — tool
# results and the system-prompt catalog are excluded); the declaration must be
# an ASSISTANT row with `Linear gate:` at line start (LIKE has no ^-anchor, so
# anchor = start-of-content or after a newline).
DB="$HHOME/state.db"
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$DB" ]]; then
  SID_SQL="${SESSION_ID//\'/\'\'}"
  # case_sensitive_like: SQLite LIKE is case-insensitive for ASCII by default,
  # which would accept `linear gate:` here while the other harnesses' grep does
  # not — pin it case-sensitive for cross-harness parity.
  HIT="$(sqlite3 -readonly "$DB" \
    "PRAGMA case_sensitive_like=ON; SELECT (SELECT COUNT(*) FROM messages WHERE session_id='$SID_SQL' AND role IN ('user','assistant') AND (COALESCE(content,'') LIKE '%skills/session-agent/SKILL.md%' OR COALESCE(tool_calls,'') LIKE '%skills/session-agent/SKILL.md%')) > 0 AND (SELECT COUNT(*) FROM messages WHERE session_id='$SID_SQL' AND role='assistant' AND (COALESCE(content,'') LIKE 'Linear gate:%' OR COALESCE(content,'') LIKE '%'||char(10)||'Linear gate:%')) > 0 AND (SELECT COUNT(*) FROM messages WHERE session_id='$SID_SQL' AND role='assistant' AND (COALESCE(content,'') LIKE 'Lessons:%' OR COALESCE(content,'') LIKE '%'||char(10)||'Lessons:%')) > 0;" \
    2>/dev/null | tail -n 1 || true)"
  if [[ "$HIT" == "1" ]]; then
    exit 0
  fi
fi

block "First file-modifying tool use detected but the session-agent gate is not open for this session. Invoke /session-agent to walk the kickoff orient (Mode 1) then route the request (R1-R5, including the R1a lesson recall), and declare the gate by writing the file $GATE_FILE via the write_file tool with the full routing declaration including the \`Linear gate:\` and \`Lessons:\` lines as its content. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
