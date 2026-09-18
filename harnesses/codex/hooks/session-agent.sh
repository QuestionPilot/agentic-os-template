#!/usr/bin/env bash
# Session-agent enforcement hook (Codex PreToolUse event, matcher
# Bash|apply_patch|Edit|Write). Blocks bounded file-mutation paths if the
# session-agent capability was not invoked earlier in the session. Read-only
# Bash commands pass without inspecting the session. SAFETY NET — primary
# auto-fire is via the SessionStart directive emitted by framework-surface.sh.
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
# assistant-authored line-anchored declaration carrying BOTH contract lines:
# `Linear gate:` (active-work disposition) and `Lessons:` (recall outcome).

set -uo pipefail

deny() {
  jq -nc --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# Return a simplified view of a Bash command. Quoted content becomes a benign
# placeholder and escaped characters are ignored. This deliberately is NOT a
# shell parser: it exists only to avoid treating a literal `>` in an orient
# command as a redirection while recognizing the common mutation forms below.
# Commands hidden in `bash -c '...'`, command substitutions, aliases, or a
# non-listed executable are outside this procedural gate's coverage.
strip_bash_quotes() {
  local source="$1" out='' state=plain ch i
  for ((i=0; i<${#source}; i++)); do
    ch="${source:i:1}"
    case "$state" in
      plain)
        case "$ch" in
          "\\") ((i++)) ;;
          "'") state=single; out+='q' ;;
          '"') state=double; out+='q' ;;
          *) out+="$ch" ;;
        esac
        ;;
      single)
        [ "$ch" = "'" ] && state=plain
        ;;
      double)
        case "$ch" in
          "\\") ((i++)) ;;
          '"') state=plain ;;
        esac
        ;;
    esac
  done
  printf '%s' "$out"
}

# Bash is needed for the shell-wrapped patch path, but matching every Bash call
# would stop orientation reads. Gate only common direct mutation commands and
# file redirection. The writer verb must begin a command segment, which avoids
# denying a read solely because an argument contains a writer word. This is an
# intentionally bounded heuristic, not a complete shell-write security boundary.
bash_command_may_write() {
  local command bare redirect_check dev_null_redirect null_redirect_re
  local LC_ALL=C
  command="$1"
  # A UTF-8 byte-count guard bounds the deliberately simple quote-stripper.
  # Oversized Bash commands take the existing declaration-check path.
  if ((${#command} > 8192)); then
    return 0
  fi
  bare="$(strip_bash_quotes "$command")"
  # Treat a newline as a command separator. Quoted newlines were stripped above.
  bare="${bare//$'\n'/;}"
  # Keep ordinary read controls usable only for the exact /dev/null target.
  # Removing that token first still catches another redirection in this command.
  # The synthetic terminator makes each removed match include a real boundary.
  # It prevents a valid /dev/null span from removing a lookalike's prefix.
  redirect_check="${bare};"
  null_redirect_re='[0-9]*>>?[[:space:]]*/dev/null[[:space:];|&]'
  while [[ "$redirect_check" =~ $null_redirect_re ]]; do
    dev_null_redirect="${BASH_REMATCH[0]}"
    redirect_check="${redirect_check/"$dev_null_redirect"/}"
  done
  [[ "$bare" =~ (^|[\;\|&]|\&\&|\|\|)[[:space:]]*([^[:space:];\|&]*/)?(apply_patch|tee|touch|mkdir|rm|mv|cp|install|truncate|dd)([[:space:];\|&<]|$) ]] \
    || [[ "$redirect_check" =~ (^|[^>])\>[[:space:]]*[^\&[:space:]] ]]
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

# A Codex shell-wrapped `apply_patch` reports tool_name `Bash`, so it never
# reaches an apply_patch-only matcher. Let ordinary Bash reads through first;
# the bounded mutation predicate is documented above. Native edit tool names
# always continue to the declaration check below.
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
if [[ "$TOOL_NAME" == "Bash" ]]; then
  COMMAND_KIND="$(printf '%s' "$INPUT" | jq -r 'if (.tool_input? | type) == "object" and (.tool_input.command? | type) == "string" then "string" else "invalid" end')"
  if [[ "$COMMAND_KIND" != "string" ]]; then
    deny "Bash pre-edit candidate has no string tool_input.command; the bounded mutation check cannot inspect it, so the gate fails closed."
  fi
  COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command')"
  if ! bash_command_may_write "$COMMAND"; then
    exit 0
  fi
fi
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

# session-agent ran — confirm the Linear gate AND the Lessons recall outcome
# were declared BY THE ASSISTANT. A whole-transcript grep is vacuous here: the
# injected capability body carries its own `Linear gate:` / `Lessons:` template
# lines and a prior deny from this very hook quotes the phrases. Keep only
# assistant-authored message text and require each declaration line at line
# start WITH a non-empty value after the colon (a bare `Lessons:` is not a
# recall outcome — panel finding); the two lines may land in different
# assistant messages, so each pattern is checked independently over the
# combined assistant text.
ASSISTANT_TEXT="$(jq -rR '
    fromjson? | select(.type == "response_item")
    | .payload | select(.type == "message" and .role == "assistant")
    | .content[]? | .text? // empty
  ' "$TRANSCRIPT" 2>/dev/null)"
if printf '%s\n' "$ASSISTANT_TEXT" | grep -qE '^[[:space:]]*Linear gate:[[:space:]]*[^[:space:]]' \
    && printf '%s\n' "$ASSISTANT_TEXT" | grep -qE '^[[:space:]]*Lessons:[[:space:]]*[^[:space:]]'; then
  exit 0
fi

deny "The session-agent capability ran but no complete routing declaration was found this session — both the \`Linear gate:\` line AND the \`Lessons:\` line are required. Re-run the routing steps (R1–R5, including the R1a lesson recall) and emit the full declaration. If the task is multi-step or multi-session, a Linear issue/project must exist first. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
