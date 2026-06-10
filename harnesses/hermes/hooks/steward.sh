#!/usr/bin/env bash
# Vault-index steward — the periodic reconcile job for the shared vault's
# generated harness-index views. SHIPPED UNREGISTERED: the build copies this
# script into hooks/ but never schedules it; registering the cron job is a
# deliberate operator act (the same enablement gate as the unattended drain).
#
# Cost discipline (cron is fixed-overhead burn — the failure mode is a steward
# that spends resources reconciling an unchanged index):
#   - SKIP-WHEN-NO-DELTA: when the generated views already match regeneration,
#     exit immediately.
#   - ITERATION BOUND: at most ONE regenerate-and-recheck cycle per run; a
#     view that still drifts after one regeneration is flagged, not retried.
#   - DAILY CAP: at most DAILY_CAP (4) runs per UTC day (stamp file); excess
#     runs exit immediately.
#
# Pure file I/O + node — no model calls, no Linear calls. Conflicts are
# FLAGGED (logged) for the operator, never auto-resolved.
#
# @@OBSIDIAN_VAULT_PATH@@ is a build placeholder (the shared vault root).
#
# Usage: steward.sh            run (subject to caps)
#        steward.sh --status   print the day's run count + last result
# exit:  0 on success/skip; 1 when drift could not be reconciled

set -uo pipefail

VAULT="@@OBSIDIAN_VAULT_PATH@@"
HHOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
[[ -n "$HHOME" ]] || HHOME="${HERMES_HOME:-$HOME/.hermes}"
STATE_DIR="$HHOME/agentic-os"
STAMP="$STATE_DIR/steward-runs"
LOG="$STATE_DIR/steward.log"
DAILY_CAP=4

mkdir -p "$STATE_DIR"
TODAY="$(date -u '+%Y-%m-%d')"

note() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG"; }

if [[ "${1:-}" == "--status" ]]; then
  [[ -f "$STAMP" ]] && cat "$STAMP" || printf 'no runs recorded\n'
  tail -n 3 "$LOG" 2>/dev/null
  exit 0
fi

# Daily cap.
COUNT=0
if [[ -f "$STAMP" ]]; then
  read -r stamp_day stamp_count < "$STAMP" || true
  [[ "$stamp_day" == "$TODAY" ]] && COUNT="${stamp_count:-0}"
fi
if [[ "$COUNT" -ge "$DAILY_CAP" ]]; then
  note "daily cap reached ($COUNT/$DAILY_CAP) — skipping"
  exit 0
fi
printf '%s %s\n' "$TODAY" "$((COUNT + 1))" > "$STAMP"

GEN="$VAULT/bin/generate-harness-index.js"
if [[ ! -f "$GEN" ]] || ! command -v node >/dev/null 2>&1; then
  note "generator or node unavailable — nothing to steward"
  exit 0
fi

# Skip-when-no-delta.
if node "$GEN" --check >/dev/null 2>&1; then
  note "no delta — views match regeneration; skipping"
  exit 0
fi

# Iteration bound: exactly one regenerate-and-recheck cycle.
node "$GEN" >/dev/null 2>&1 || true
if node "$GEN" --check >/dev/null 2>&1; then
  note "reconciled — views regenerated"
  exit 0
fi

note "CONFLICT — views still drift after one regeneration; flagging for the operator (no retry)"
exit 1
