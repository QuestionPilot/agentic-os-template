#!/usr/bin/env bash
# Skill-management hard gate (Hermes pre_tool_call event, matcher skill_manage).
# Self-authored skills become executable slash-commands — strictly more
# dangerous than notes — so autonomous skill creation/modification is blocked
# pending explicit human approval. DISABLED-BY-DEFAULT in the strong sense:
# there is no always-on bypass, only a per-use, operator-created approval
# marker that this hook CONSUMES (one approval, one mutation).
#
# skill_manage is a MUTATION-ONLY tool: every valid action (create/edit/patch/
# delete/write_file/remove_file) mutates a skill. Reads go through the SEPARATE,
# ungated skill_view/skills_list tools, which this hook's matcher never fires on.
# So there is no read-only skill_manage call to fast-path — EVERY skill_manage
# invocation is gated. (An earlier version fast-pathed a read-only verb allowlist
# that did not correspond to any real skill_manage action and coupled the gate's
# fail-closed guarantee to downstream verb-key precedence; gating every call is
# simpler, strictly more fail-closed, and has no behavioral cost on the real tool.)
#
# Approval flow: the operator creates
#   <HERMES_HOME>/agentic-os/allow-skill-manage
# after reviewing the proposed skill change (the block message tells the model
# to surface the full diff for review). The next skill_manage call passes and
# the marker is deleted — approval never persists.
#
# stdin:  pre_tool_call hook event JSON (consumed, not inspected)
# stdout: when blocking, {"decision":"block","reason":"..."}
# exit:   always 0

set -uo pipefail

HHOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
[[ -n "$HHOME" ]] || HHOME="${HERMES_HOME:-$HOME/.hermes}"
APPROVAL="$HHOME/agentic-os/allow-skill-manage"

# Consume the hook payload; we gate EVERY skill_manage call, so there is nothing
# to inspect (and not reading stdin could EPIPE the caller).
cat >/dev/null

if [[ -f "$APPROVAL" ]]; then
  rm -f "$APPROVAL"
  exit 0
fi

REASON="skill_manage mutation blocked pending human approval. Self-authored skills become executable slash-commands, so autonomous creation/modification is hard-gated. Surface the FULL proposed skill change (name, frontmatter, complete body, and any commands it runs) to the operator; after review the operator approves ONE mutation by creating the file $APPROVAL — the approval is consumed on use and never persists."
if command -v jq >/dev/null 2>&1; then
  jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
else
  printf '{"decision":"block","reason":"skill_manage mutation blocked pending human approval (and jq is missing on the hook PATH — the gate fails closed)."}\n'
fi
exit 0
