#!/usr/bin/env bash
# Session-agent enforcement hook (Claude Code PreToolUse event for Write|Edit|NotebookEdit).
# Blocks the tool use if the session-agent capability was not invoked earlier in
# the session. This hook is the SAFETY NET — the primary auto-fire mechanism is
# the SessionStart directive emitted by framework-surface.sh.
#
# Enforcement class: pre-edit-gate (see harnesses/claude/adapter.md).
# Kill switch: set CLAUDE_SKIP_SESSION_AGENT=1 to disable.
#
# stdin:  PreToolUse hook event JSON (session_id, transcript_path, cwd, tool_name, tool_input, ...)
# stdout: when blocking, a PreToolUse deny decision (hookSpecificOutput JSON)
# exit:   always 0 (non-zero is treated as a hook error, not a block)
#
# Decision shape: a PreToolUse block uses hookSpecificOutput.permissionDecision
# ("deny") — the documented, version-stable block channel for this event. The
# legacy top-level {"decision":"block","reason":...} form is NOT a reliable
# PreToolUse block: that top-level shape is the documented control for
# UserPromptSubmit/PostToolUse/Stop/SubagentStop/PreCompact, and on PreToolUse
# it does not deny the tool call (verified: the edit proceeds — the gate is
# silently a no-op). We emit permissionDecision:"deny" instead.
#
# Declaration channels (<TEAM>-365): the desktop/SDK harness variant does NOT
# persist turn-final assistant text blocks into the transcript file (verified
# live: 0 declaration hits across 493 assistant records; even tool-preamble
# text is unreliable), so the assistant-text check alone false-denies there.
# Two channels open the gate, either is sufficient:
#   1. GATE MARKER — the model persists its R5 routing declaration by writing
#      `<install>/agentic-os/gate-<session_id>` (path surfaced in the
#      SessionStart directive and in this hook's deny message). The marker
#      write itself is allowed through pre-gate via a structured-field match
#      (exact per-session path + line-anchored `Linear gate:` content); later
#      calls find the marker on disk. Same pattern as the Hermes gate file.
#   2. TRANSCRIPT — assistant-authored text block carrying the line-anchored
#      declaration (works on the CLI variant, whose transcript persists
#      assistant text; behavior unchanged from <TEAM>-360).
# Both channels require the session-agent Skill invocation in the transcript
# first — tool_use records persist reliably on ALL known variants.

set -uo pipefail

# deny <reason> — emit a Claude Code PreToolUse deny decision via jq for safe
# escaping of the reason string, then exit 0. jq is guaranteed present (by the
# `command -v jq` contract check below) before any call site is reached, but a
# jq that passes `command -v` can still fail AT RUNTIME (broken binary, OOM,
# corrupt build). If the construction emits nothing, fall back to a static deny
# string so the gate still fails CLOSED — never silently allow.
deny() {
  local out
  out="$(jq -nc --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' 2>/dev/null)"
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Session-agent enforcement gate is denying this edit but could not render its reason (jq failed at runtime). The gate fails closed. Re-run after invoking session-agent, or set env CLAUDE_SKIP_SESSION_AGENT=1 to bypass."}}'
  fi
  exit 0
}

if [[ "${CLAUDE_SKIP_SESSION_AGENT:-0}" == "1" ]]; then
  exit 0
fi

# jq contract — this is a gate hook, so it fails CLOSED: without jq the
# transcript cannot be parsed and the session-agent check cannot be made.
# deny() itself needs jq, so the fail-closed path emits the PreToolUse deny
# shape as a static string (fixed literal — no interpolation, so no escaping
# concern).
if ! command -v jq >/dev/null 2>&1; then
  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Session-agent enforcement hook cannot run: `jq` was not found on the hook PATH. The gate fails closed. Install jq, or set env CLAUDE_SKIP_SESSION_AGENT=1 to bypass enforcement."}}
EOF
  exit 0
fi

INPUT="$(cat)"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')"
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty')"

# No transcript path → allow (no way to check).
if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
  exit 0
fi

# Check if the session-agent capability ever ran in this session. Safe as a
# whole-transcript grep: the unescaped Skill tool_use JSON only appears in a
# real invocation record — anywhere the same text is quoted inside a string
# (the skill body citing its own marker, a tool result) the quotes are
# JSON-escaped (\"skill\") and this pattern cannot match. This check gates BOTH
# declaration channels below — the marker file alone never opens the gate.
if ! grep -qE '"skill"[[:space:]]*:[[:space:]]*"session-agent"' "$TRANSCRIPT" 2>/dev/null; then
  deny "First file-modifying tool use detected but the session-agent capability has not been invoked this session. Invoke \`session-agent\` via the Skill tool to walk the kickoff orient (Mode 1) then route the request. One invocation per session for Mode 1; re-invoke for each subsequent non-trivial prompt (Mode 2). Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
fi

# Channel 1 — gate marker (<TEAM>-365). Keyed strictly to the event's
# session_id: sanitized to a path-safe alphabet (letters/digits/hyphen — a
# superset of UUIDs) so a hostile/garbled id cannot
# path-escape the state dir (an id that fails the check just disables this
# channel — the transcript channel still applies). The install dir is this
# hook's own parent (hooks live at <install>/hooks/).
GATE_FILE=""
# Whitespace-tolerant capture (panel finding): the SessionStart directive trims
# the id before publishing the marker path, so the hook must key the same
# trimmed token or a padded id would publish one path and check another.
if [[ "$SESSION_ID" =~ ^[[:space:]]*([A-Za-z0-9-]+)[[:space:]]*$ ]]; then
  SESSION_ID="${BASH_REMATCH[1]}"
  SA_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  if [[ -n "$SA_INSTALL_DIR" ]]; then
    STATE_DIR="$SA_INSTALL_DIR/agentic-os"
    GATE_FILE="$STATE_DIR/gate-$SESSION_ID"
    # Reap stale markers (old sessions); never fails the hook.
    find "$STATE_DIR" -maxdepth 1 -name 'gate-*' -mtime +7 -delete 2>/dev/null || true
  fi
fi

if [[ -n "$GATE_FILE" ]]; then
  # 1a. The marker write itself is allowed through pre-gate: a Write to the
  #     exact per-session path whose content carries the line-anchored
  #     declaration WITH a non-empty value after the colon (a bare
  #     `Linear gate:` is not a disposition — panel finding). Structured-field match on the CURRENT event only — never
  #     a transcript grep, so tool_use fixture noise (the skill body's own
  #     template lines quoted inside other tool inputs) cannot satisfy it.
  if [[ "$TOOL_NAME" == "Write" ]]; then
    WPATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"
    if [[ "$WPATH" == "$GATE_FILE" ]]; then
      if printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null \
          | grep -qE '^[[:space:]]*Linear gate:[[:space:]]*[^[:space:]]'; then
        exit 0
      fi
      deny "The gate marker file must carry the routing declaration — include the full \`Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted\` line in its content, then retry."
    fi
  fi
  # 1b. Marker already on disk with a line-anchored declaration → gate open.
  if [[ -f "$GATE_FILE" ]] && grep -qE '^[[:space:]]*Linear gate:[[:space:]]*[^[:space:]]' "$GATE_FILE" 2>/dev/null; then
    exit 0
  fi
fi

# Channel 2 — transcript. session-agent ran; confirm the Linear gate was
# declared BY THE ASSISTANT. A whole-transcript grep is vacuous here: the
# skill body carries its own `Linear gate:` template lines (injected into the
# transcript the moment the skill loads) and a prior deny from this very hook
# quotes the phrase — so the gate would open as soon as it was explained,
# never enforcing the declaration. Parse the transcript records instead: keep
# only assistant-authored text blocks (skill-body injection and deny text land
# in user/tool_result records) and require the declaration at line start.
if jq -rR '
    fromjson?
    | select(.type == "assistant")
    | .message.content
    | if type == "string" then .
      elif type == "array" then (.[]? | select(.type == "text") | .text // empty)
      else empty end
  ' "$TRANSCRIPT" 2>/dev/null | grep -qE '^[[:space:]]*Linear gate:'; then
  exit 0
fi

# session-agent ran but no Linear-gate declaration reached either channel.
DENY_MSG="The session-agent capability ran but no \`Linear gate:\` declaration was found this session. Re-run the routing steps (R1–R5) and emit the full declaration including the \`Linear gate:\` line. If the task is multi-step or multi-session, a Linear issue/project must exist first."
if [[ -n "$GATE_FILE" ]]; then
  DENY_MSG="$DENY_MSG If you HAVE already declared and this deny persists, this harness variant does not persist assistant text into the transcript — persist the declaration to the gate marker instead: write the routing declaration (including the \`Linear gate:\` line) to $GATE_FILE (the Write tool call to that exact path is allowed through this gate; a Bash heredoc works too)."
fi
deny "$DENY_MSG Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
