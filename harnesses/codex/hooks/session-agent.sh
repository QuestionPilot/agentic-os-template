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
# hook detects session-agent ran by finding the injected capability body (its
# H1) or an assistant function_call reading the SKILL.md path, plus an
# assistant-authored line-anchored `Linear gate:` declaration.

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

# Check if the session-agent capability ran. A bare whole-transcript path grep
# is vacuous: Codex injects a skills CATALOG as a developer message on EVERY
# session, and each catalog line carries the skill's `(file: …/SKILL.md)` path
# — so the old check self-matched before any invocation. Detect a genuine
# invocation instead, from the rollout's response_item records:
#   (a) a message record carrying the capability body's own H1 (the catalog
#       line quotes only name + description, never the body), or
#   (b) an assistant-initiated function_call whose arguments read the SKILL.md
#       path (the model pulling the body itself; separator-tolerant so a
#       Windows-transcript backslash path also counts — parity with the PS
#       twin's <TEAM>-113 F-1 amendment).
# The H1 literal must stay in sync with capabilities/session-agent.md.
# Scope note (cross-model panel 2026-07-02): the H1 branch cannot tell WHO put
# the body in the transcript — pasted H1 text opens only this ran-check. That
# is accepted: the enforcement lives in the assistant-authored line-anchored
# declaration below, and this gate is a discipline net with a documented kill
# switch, not a security boundary.
SA_RAN="$(jq -rR '
    fromjson? | select(.type == "response_item") | .payload
    | if .type == "message" then
        ([.content[]? | .text? // empty] | join("\n"))
        | select(contains("Session Agent — Session Kickoff Orient + Routing"))
        | "ran"
      elif .type == "function_call" then
        ((.arguments // "") | tostring) + " " + ((.name // "") | tostring)
        | select(test("skills[/\\\\]+session-agent[/\\\\]+SKILL[.]md"))
        | "ran"
      else empty end
  ' "$TRANSCRIPT" 2>/dev/null | head -n 1)"
if [[ "$SA_RAN" != "ran" ]]; then
  deny "First file-modifying tool use detected but the session-agent capability has not been invoked this session. Invoke \`\$session-agent\` to walk the kickoff orient (Mode 1) then route the request. One invocation per session for Mode 1; re-invoke for each subsequent non-trivial prompt (Mode 2). Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
fi

# session-agent ran — confirm the Linear gate was declared BY THE ASSISTANT.
# A whole-transcript grep is vacuous here: the injected capability body carries
# its own `Linear gate:` template lines and a prior deny from this very hook
# quotes the phrase. Keep only assistant-authored message text and require the
# declaration at line start.
if jq -rR '
    fromjson? | select(.type == "response_item")
    | .payload | select(.type == "message" and .role == "assistant")
    | .content[]? | .text? // empty
  ' "$TRANSCRIPT" 2>/dev/null | grep -qE '^[[:space:]]*Linear gate:'; then
  exit 0
fi

deny "The session-agent capability ran but no \`Linear gate:\` declaration was found this session. Re-run the routing steps (R1–R5) and emit the full declaration including the \`Linear gate:\` line. If the task is multi-step or multi-session, a Linear issue/project must exist first. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
