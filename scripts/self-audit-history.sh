#!/usr/bin/env bash
# scripts/self-audit-history.sh — append + read the operator-local self-audit
# score history so the point-in-time scorecard gains a trend view.
#
# self-audit.sh is a READ-ONLY framework diagnostic: it never writes into the
# agentic-os-template tree. Score history is RUNTIME, PER-OPERATOR state, so it lives in
# an operator-local JSONL store keyed off $CLAUDE_CONFIG_DIR — never committed
# to the repo (matching cross-model-out/ and .build-manifest.json, which are
# also operator-local). One record per run, one JSON object per line:
#   {"timestamp":"<ISO-8601 UTC>","total":<0-100>,"overall":<0-100>,
#    "pillars":{"<key>":<0-20>,...}}
# `total` and `overall` carry the same value (overall is an alias the trend
# view reads); both are written so either name resolves downstream.
#
# Usage:
#   self-audit.sh --json | bash scripts/self-audit-history.sh append [<store>]
#   bash scripts/self-audit-history.sh trend [<store>] [<N>]
#
# Subcommands:
#   append [<store>]      Read a self-audit --json scorecard from stdin, append
#                         one record to <store>. Exits non-zero on malformed
#                         JSON (so a piped self-audit failure does not silently
#                         write a junk record).
#   trend  [<store>] [N]  Print a per-pillar trend table over the last N records
#                         (default 5), with the delta of the newest run vs the
#                         prior one.
#
# <store> defaults to "$CLAUDE_CONFIG_DIR/self-audit-history.jsonl". If
# $CLAUDE_CONFIG_DIR is unset and no <store> is given, the command errors with
# guidance rather than guessing a path.
#
# jq is required (the store is JSONL). Without it the command errors loudly —
# self-audit.sh already requires jq for its own --json path.
#
# Read-only w.r.t. the framework tree: the only file this script writes is the
# operator-local <store>, which the caller chooses.
set -uo pipefail

usage() {
  grep -E '^# ' "$0" | sed 's/^# //'
}

die() { printf 'self-audit-history.sh: %s\n' "$1" >&2; exit "${2:-1}"; }

[ $# -ge 1 ] || { usage >&2; exit 2; }

SUB="$1"; shift

# Resolve the store path: explicit arg wins, else $CLAUDE_CONFIG_DIR default.
resolve_store() {
  local s="${1:-}"
  if [ -n "$s" ]; then
    printf '%s' "$s"
    return 0
  fi
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    printf '%s' "$CLAUDE_CONFIG_DIR/self-audit-history.jsonl"
    return 0
  fi
  return 1
}

command -v jq >/dev/null 2>&1 || die "jq is required (the history store is JSONL)" 3

# jqr — jq with CRLF normalization (parity with check-drift.sh): a
# Windows-built jq emits \r\n line endings. Unstripped, appended records end
# "\r\n" in the store and the trend table diverges byte-wise from the PS twin
# (whose output the parity test LF-normalizes — the bash side must be clean).
# jq's exit status survives the tr stage: set -o pipefail is active above.
jqr() { jq "$@" | tr -d '\r'; }

case "$SUB" in
  append)
    STORE="$(resolve_store "${1:-}")" \
      || die "no store path: pass one as an argument or set CLAUDE_CONFIG_DIR" 2
    # Read the full --json scorecard from stdin.
    scorecard="$(cat)"
    [ -n "$scorecard" ] || die "no scorecard on stdin (pipe self-audit.sh --json)" 2
    # Validate + project to a compact record. A malformed scorecard (e.g. the
    # {"error":...} jq emits when jq is missing on the producer side) has no
    # .total, so this jq fails and we refuse to append a junk line.
    record="$(printf '%s' "$scorecard" | jqr -c '
      if (.total | type) != "number" then error("scorecard has no numeric .total")
      else {
        timestamp: (.date // (now | todateiso8601)),
        total: .total,
        overall: .total,
        pillars: (.pillars | map_values(.score))
      } end
    ' 2>/dev/null)" \
      || die "stdin is not a valid self-audit --json scorecard" 4
    # A scorecard's .date is a YYYY-MM-DD day stamp; promote to a full ISO-8601
    # UTC timestamp so multiple same-day runs sort + dedupe by instant, not day.
    record="$(printf '%s' "$record" | jqr -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.timestamp = $ts')" \
      || die "could not stamp record timestamp" 4
    mkdir -p "$(dirname "$STORE")" || die "could not create store dir for $STORE"
    printf '%s\n' "$record" >> "$STORE" || die "could not append to $STORE"
    printf 'self-audit-history: appended record to %s\n' "$STORE" >&2
    ;;

  trend)
    STORE="$(resolve_store "${1:-}")" \
      || die "no store path: pass one as an argument or set CLAUDE_CONFIG_DIR" 2
    N="${2:-5}"
    case "$N" in ''|*[!0-9]*) die "N must be a positive integer, got: $N" 2 ;; esac
    [ "$N" -ge 1 ] || die "N must be >= 1" 2
    if [ ! -f "$STORE" ]; then
      printf '# self-audit trend — no history yet\n\n'
      printf 'No history store at %s.\n' "$STORE"
      printf 'Run a self-audit and append it first:\n'
      printf '  bash scripts/self-audit.sh --json | bash scripts/self-audit-history.sh append\n'
      exit 0
    fi
    # Last N valid JSONL records, oldest→newest. Skip blank/garbage lines.
    records="$(grep -v '^[[:space:]]*$' "$STORE" | tail -n "$N")"
    count="$(printf '%s\n' "$records" | grep -c . || true)"
    if [ -z "$records" ] || [ "$count" -eq 0 ]; then
      printf '# self-audit trend — store is empty\n\n'
      printf 'No records in %s yet.\n' "$STORE"
      exit 0
    fi

    # Emit a per-pillar table: one column per record (timestamp header), one row
    # per pillar (+ a Total row). The final column shows the newest-vs-prior
    # delta. jq does the shaping; the slurped array preserves file order.
    printf '# self-audit trend — last %s run(s)\n\n' "$count"
    printf '%s\n' "$records" | jqr -rs '
      # Stable pillar order from the newest record (falls back to sorted keys).
      (.[-1].pillars | keys) as $pkeys
      | (map(.timestamp)) as $stamps
      | "| Pillar | " + ($stamps | join(" | ")) + " | Δ (latest) |",
        ("| --- |" + ($stamps | map(" --- |") | join("")) + " --- |"),
        ( $pkeys[] as $p
          | "| " + $p + " | "
            + ([ .[] | (.pillars[$p] | tostring) ] | join(" | "))
            + " | "
            + ( if (length >= 2)
                then ((.[-1].pillars[$p] - .[-2].pillars[$p]) | if . > 0 then "+" + (.|tostring) elif . < 0 then (.|tostring) else "0" end)
                else "n/a" end )
            + " |"
        ),
        ( "| **Total** | "
          + ([ .[] | (.total | tostring) ] | join(" | "))
          + " | "
          + ( if (length >= 2)
              then ((.[-1].total - .[-2].total) | if . > 0 then "+" + (.|tostring) elif . < 0 then (.|tostring) else "0" end)
              else "n/a" end )
          + " |"
        )
    '
    ;;

  -h|--help)
    usage
    exit 0
    ;;

  *)
    die "unknown subcommand: $SUB (expected: append | trend)" 2
    ;;
esac

exit 0
