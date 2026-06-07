#!/usr/bin/env bash
# Session-agent enforcement hook (Codex PreToolUse event, matcher apply_patch).
# Blocks the file edit if the session-agent capability was not invoked earlier
# in the session. SAFETY NET — primary auto-fire is via the SessionStart
# directive emitted by framework-surface.sh.
#
# Enforcement class: pre-edit-gate (see harnesses/codex/adapter.md).
# Kill switch: set CLAUDE_SKIP_SESSION_AGENT=1 to disable (same env name as the
# Claude harness — one kill switch works regardless of harness).
#
# stdin:  PreToolUse hook event JSON
# stdout: when blocking, a PreToolUse deny decision
# exit:   always 0
#
# Marker: Codex has no `Skill` tool — capabilities are context-injected. The
# hook detects session-agent ran by matching `skills/session-agent/SKILL.md` in
# the transcript, plus the `Linear gate:` declaration.

set -uo pipefail

deny() {
  jq -nc --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

if [[ "${CLAUDE_SKIP_SESSION_AGENT:-0}" == "1" ]]; then
  exit 0
fi

# jq contract — gate hook, fails CLOSED. deny() needs jq, so emit a static-string
# block shape when jq is absent. The legacy top-level {"decision":"block"} form is
# used here and GENUINELY blocks on Codex PreToolUse (verified v0.132.0 schema +
# docs — see adapter.md "Hook decision formats"). This is a real Codex/Claude
# divergence: do NOT "fix" it to match the Claude twin's <TEAM>-227 change, where the
# legacy top-level form is a no-op on PreToolUse.
if ! command -v jq >/dev/null 2>&1; then
  cat <<'EOF'
{"decision":"block","reason":"Session-agent enforcement hook cannot run: `jq` was not found on the hook PATH. The gate fails closed. Install jq, or set env CLAUDE_SKIP_SESSION_AGENT=1 to bypass enforcement."}
EOF
  exit 0
fi

INPUT="$(cat)"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')"

if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
  exit 0
fi

if ! grep -qF 'skills/session-agent/SKILL.md' "$TRANSCRIPT" 2>/dev/null; then
  deny "First file-modifying tool use detected but the session-agent capability has not been invoked this session. Invoke \`\$session-agent\` to walk the kickoff orient (Mode 1) then route the request. One invocation per session for Mode 1; re-invoke for each subsequent non-trivial prompt (Mode 2). Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
fi

if grep -qE 'Linear gate:' "$TRANSCRIPT" 2>/dev/null; then
  exit 0
fi

deny "The session-agent capability ran but no \`Linear gate:\` declaration was found this session. Re-run the routing steps (R1–R5) and emit the full declaration including the \`Linear gate:\` line. If the task is multi-step or multi-session, a Linear issue/project must exist first. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
