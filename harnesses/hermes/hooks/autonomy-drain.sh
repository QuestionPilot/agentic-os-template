#!/usr/bin/env bash
# Unattended-drain hook (Hermes on_session_end event) — WIRED, DISABLED BY
# DEFAULT. When (and only when) the operator enables unattended draining, this
# hook invokes the SHARED closeout drain for the no-human-closeout case by
# spawning a headless run that walks /closeout. It never defines a bespoke
# drain — the drain logic is owned by the shared closeout capability.
#
# DEFAULT-OFF CONTRACT: the hook is inert unless the enablement flag file
#   <HERMES_HOME>/agentic-os/unattended-drain.enabled
# exists. Creating that flag is a deliberate, separate operator act, gated on
# the storage-decision note's Review Trigger (an autonomous always-on Hermes
# actually arriving) and recorded as its own decision. Until then: silent exit.
#
# UNATTENDED-WRITE POLICY: messaging-gateway surfaces (telegram / slack /
# discord / whatsapp / matrix / mattermost) are PROPOSE-ONLY — they never
# autonomously drain durable Vault notes, even when the flag is on. Desktop +
# CLI sessions carry the full spine.
#
# stdin:  on_session_end event JSON ({..., session_id, extra: {platform: ...}})
# stdout: nothing (context injection is meaningless at session end)
# exit:   always 0

set -uo pipefail

HHOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
[[ -n "$HHOME" ]] || HHOME="${HERMES_HOME:-$HOME/.hermes}"
FLAG="$HHOME/agentic-os/unattended-drain.enabled"
LOG="$HHOME/agentic-os/unattended-drain.log"

INPUT="$(cat)"

# Default-off: no flag, no action — and no log line, so a governance test can
# assert the OFF state leaves zero trace.
[[ -f "$FLAG" ]] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty')"
PLATFORM="$(printf '%s' "$INPUT" | jq -r '.extra.platform // empty')"

# Propose-only surfaces never drain autonomously.
case "$PLATFORM" in
  telegram|slack|discord|whatsapp|matrix|mattermost)
    printf '%s skipped session=%s platform=%s (propose-only surface)\n' \
      "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$SESSION_ID" "$PLATFORM" >> "$LOG"
    exit 0 ;;
esac

# Enabled + non-gateway surface: invoke the shared drain in a detached
# headless run. The /closeout skill owns the drain protocol (write-through to
# the vault's session archive with the untrusted-evidence model + injection
# scan); this hook only fires it.
printf '%s draining session=%s platform=%s\n' \
  "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$SESSION_ID" "${PLATFORM:-unknown}" >> "$LOG"
nohup hermes --cli -z "Invoke /closeout to drain the just-ended unattended session ${SESSION_ID} — session-log write-through only; propose (do not write) any curated-note changes." \
  >> "$LOG" 2>&1 &

exit 0
