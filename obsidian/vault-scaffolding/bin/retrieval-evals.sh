#!/usr/bin/env bash
# retrieval-evals.sh — run the 00-System/Retrieval Fixtures set against the
# vault's full-text baseline (bin/vault-search.sh).
#
# WHY. A retrieval surface is only trustworthy if something checks that it still
# retrieves. This is that check: each fixture asserts a real question surfaces
# the note that actually answers it, and each negative control asserts the
# surface can still say "nothing here". A surface that can never report absence
# will always find something, and a search that always answers is indis-
# tinguishable from a search that is guessing.
#
# Usage:
#   bin/retrieval-evals.sh           # run every fixture + negative control
#   bin/retrieval-evals.sh --list    # print the parsed fixture set and stop
#
# Exit codes:
#   0  every fixture and negative control passed
#   1  at least one fixture or control failed
#   2  the fixture table could not be parsed, or the baseline is missing
#      (fail loud: "0 fixtures, all passed" is the exact false clean this
#      instrument exists to eliminate)
#
# Determinism: LC_ALL=C is pinned so the table parse and every comparison are
# byte-oriented regardless of caller locale.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$VAULT_ROOT/00-System/Retrieval Fixtures.md"
SEARCH="$SCRIPT_DIR/vault-search.sh"

# An unrecognized argument is an unexpected condition — reject it loudly rather
# than silently running the full suite under a flag the caller thinks is active.
MODE_LIST=0
case "${1:-}" in
  "") ;;
  --list) MODE_LIST=1 ;;
  *) echo "usage: retrieval-evals.sh [--list]" >&2; exit 2 ;;
esac
[ $# -gt 1 ] && { echo "usage: retrieval-evals.sh [--list]" >&2; exit 2; }

die() { printf 'retrieval-evals: %s\n' "$*" >&2; exit 2; }

[ -f "$FIXTURES" ] || die "fixture note missing: 00-System/Retrieval Fixtures.md"
[ -x "$SEARCH" ]   || die "baseline missing or not executable: bin/vault-search.sh"

# Parse the positive table: rows are `| R<n> | query | scope | max | `path` | class |`.
# Backticks around the path are stripped. Anything that does not match the row
# shape is ignored, so surrounding prose is safe.
POSITIVES="$(awk -F'|' '
  /^\| *R[0-9]+ *\|/ {
    for (i = 2; i <= NF; i++) { gsub(/^ +| +$/, "", $i); gsub(/`/, "", $i) }
    print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7
  }' "$FIXTURES")"

# Parse the negative-control table: `| N<n> | query | scope | expected |`.
NEGATIVES="$(awk -F'|' '
  /^\| *N[0-9]+ *\|/ {
    for (i = 2; i <= NF; i++) { gsub(/^ +| +$/, "", $i); gsub(/`/, "", $i) }
    print $2 "\t" $3 "\t" $4
  }' "$FIXTURES")"

POS_COUNT="$(printf '%s' "$POSITIVES" | grep -c . || true)"
NEG_COUNT="$(printf '%s' "$NEGATIVES" | grep -c . || true)"

# An empty parse means the table shape changed under us. Reporting "all passed"
# from zero fixtures would be worse than useless.
[ "$POS_COUNT" -gt 0 ] || die "parsed 0 positive fixtures — has the table shape changed?"
[ "$NEG_COUNT" -gt 0 ] || die "parsed 0 negative controls — has the table shape changed?"

if [ "$MODE_LIST" -eq 1 ]; then
  printf 'positives (%s):\n' "$POS_COUNT"
  printf '%s\n' "$POSITIVES" | while IFS=$'\t' read -r id q scope max target class; do
    printf '  %s  [%s] scope=%s max=%s  %s\n      -> %s\n' "$id" "$class" "$scope" "$max" "$q" "$target"
  done
  printf 'negative controls (%s):\n' "$NEG_COUNT"
  printf '%s\n' "$NEGATIVES" | while IFS=$'\t' read -r id q scope; do
    printf '  %s  scope=%s  %s\n' "$id" "$scope" "$q"
  done
  exit 0
fi

# The fixture note quotes every query verbatim, so leaving it in scope would make
# it match every fixture — including every negative control. Filtering it HERE
# would be wrong on its own: that makes the runner measure a surface no caller
# ever sees, so a control could pass while a real query returned a match. The
# exclusion lives in bin/vault-search.sh itself, and this stays only as a
# belt-and-braces guard. If it ever strips anything, the baseline's own glob has
# regressed — the two must agree.
SELF="00-System/Retrieval Fixtures.md"
strip_self() { grep -Fxv "$SELF" || true; }

# Prove the two agree, rather than assuming it. A control query is asked of the
# baseline directly; if the note comes back, the caller surface and the measured
# surface have diverged and every negative control below is meaningless.
_probe="$("$SEARCH" "kubernetes ingress controller" --scope durable --paths-only 2>/dev/null)"
if printf '%s\n' "$_probe" | grep -Fxq "$SELF"; then
  die "baseline returns the fixture note itself — caller and measured surface have diverged"
fi

fails=0
passes=0

while IFS=$'\t' read -r id q scope max target class; do
  [ -n "${id:-}" ] || continue
  if [ ! -f "$VAULT_ROOT/$target" ]; then
    printf 'FAIL %s  broken pointer: %s does not exist\n' "$id" "$target"
    fails=$((fails + 1)); continue
  fi
  # Ask for one extra result: excluding the self-match must not silently cost a
  # fixture its last slot.
  out="$("$SEARCH" "$q" --scope "$scope" --max "$((max + 1))" --paths-only 2>/dev/null | strip_self | head -n "$max")"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -gt 1 ]; then
    printf 'FAIL %s  baseline errored (exit %s) on query: %s\n' "$id" "$rc" "$q"
    fails=$((fails + 1)); continue
  fi
  if printf '%s\n' "$out" | grep -Fqx "$target"; then
    printf 'PASS %s  [%s] %s\n' "$id" "$class" "$q"
    passes=$((passes + 1))
  else
    printf 'FAIL %s  [%s] %s\n     wanted: %s\n     got:    %s\n' \
      "$id" "$class" "$q" "$target" "$(printf '%s' "$out" | tr '\n' ' ')"
    fails=$((fails + 1))
  fi
done <<< "$POSITIVES"

while IFS=$'\t' read -r id q scope; do
  [ -n "${id:-}" ] || continue
  hits="$("$SEARCH" "$q" --scope "$scope" --paths-only 2>/dev/null | strip_self)"
  rc=${PIPESTATUS[0]}
  # A control whose ONLY hit was the fixture note itself is still a clean
  # "found nothing" — the scaffolding does not count as a match.
  [ "$rc" -eq 0 ] && [ -z "$hits" ] && rc=1
  if [ "$rc" -eq 1 ]; then
    printf 'PASS %s  [negative-control] correctly found nothing: %s\n' "$id" "$q"
    passes=$((passes + 1))
  elif [ "$rc" -eq 0 ]; then
    printf 'FAIL %s  [negative-control] expected no matches, got some: %s\n' "$id" "$q"
    fails=$((fails + 1))
  else
    printf 'FAIL %s  [negative-control] baseline errored (exit %s): %s\n' "$id" "$rc" "$q"
    fails=$((fails + 1))
  fi
done <<< "$NEGATIVES"

printf '\n%s passed, %s failed (%s positives, %s negative controls)\n' \
  "$passes" "$fails" "$POS_COUNT" "$NEG_COUNT"
[ "$fails" -eq 0 ] || exit 1
exit 0
