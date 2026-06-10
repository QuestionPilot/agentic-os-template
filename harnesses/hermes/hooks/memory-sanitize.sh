#!/usr/bin/env bash
# Memory-write governance hook (Hermes pre_tool_call event, matcher memory).
# Hermes's native memory files are frozen-snapshot-injected into every future
# session's system prompt, so a prompt-injection payload persisted via the
# memory tool becomes a standing hijack vector. This hook runs the framework's
# injection scan over the content being persisted and blocks on a hit.
#
# Scope: NATIVE-memory hygiene only. It never imposes Vault schema on the
# native store (cache contract) — it only refuses to persist hostile shapes.
#
# @@AI_CONFIG_DIR@@ is a build placeholder (the framework checkout, which
# carries scripts/check-memory-drift.sh --injection-scan).
#
# stdin:  pre_tool_call hook event JSON
# stdout: when blocking, {"decision":"block","reason":"..."}
# exit:   always 0

set -uo pipefail

AI_CONFIG_DIR="@@AI_CONFIG_DIR@@"

block() {
  jq -nc --arg r "$1" '{decision: "block", reason: $r}'
  exit 0
}

# Governance hook: fails CLOSED without jq (static legacy block shape).
if ! command -v jq >/dev/null 2>&1; then
  cat <<'EOF'
{"decision":"block","reason":"Memory-sanitize hook cannot run: `jq` was not found on the hook PATH. The governance gate fails closed for memory persistence. Install jq."}
EOF
  exit 0
fi

INPUT="$(cat)"

# Extract every string value in tool_input — the memory tool's write surface.
CONTENT="$(printf '%s' "$INPUT" | jq -r '[.tool_input // {} | .. | strings] | join("\n")')"
[[ -n "$CONTENT" ]] || exit 0

SCAN="$AI_CONFIG_DIR/scripts/check-memory-drift.sh"
if [[ ! -f "$SCAN" ]]; then
  # The scan ships with the framework checkout this build rendered from; its
  # absence means a broken install — fail closed for persistence.
  block "Memory-sanitize hook cannot find the injection scan at $SCAN — refusing to persist memory content until the framework checkout is restored."
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$CONTENT" > "$TMP"

if ! bash "$SCAN" --injection-scan "$TMP" >/dev/null 2>&1; then
  block "Memory persistence blocked: the content matches a prompt-injection payload class (chat-role spoof / override-instructions / persona flip / future-agent targeting / memory-write directive / prompt exfil). Native memory is injected into every future session, so hostile shapes must not persist. To document such a pattern legitimately, fence it in a code block and persist via a normal note instead."
fi

exit 0
