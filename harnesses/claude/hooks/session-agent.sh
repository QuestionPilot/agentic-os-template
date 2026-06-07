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

# No transcript path → allow (no way to check).
if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
  exit 0
fi

# Check if the session-agent capability ever ran in this session.
if ! grep -qE '"skill"[[:space:]]*:[[:space:]]*"session-agent"' "$TRANSCRIPT" 2>/dev/null; then
  deny "First file-modifying tool use detected but the session-agent capability has not been invoked this session. Invoke \`session-agent\` via the Skill tool to walk the kickoff orient (Mode 1) then route the request. One invocation per session for Mode 1; re-invoke for each subsequent non-trivial prompt (Mode 2). Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
fi

# session-agent ran — confirm the Linear gate was declared.
if grep -qE 'Linear gate:' "$TRANSCRIPT" 2>/dev/null; then
  exit 0
fi

# session-agent ran but no Linear-gate declaration.
deny "The session-agent capability ran but no \`Linear gate:\` declaration was found this session. Re-run the routing steps (R1–R5) and emit the full declaration including the \`Linear gate:\` line. If the task is multi-step or multi-session, a Linear issue/project must exist first. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
