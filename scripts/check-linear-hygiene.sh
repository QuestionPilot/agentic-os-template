#!/usr/bin/env bash
# scripts/check-linear-hygiene.sh — advisory Linear issue-hygiene signal.
#
# Answers: "do the workspace's OPEN issues meet the issue-creation standard in
# linear/issue-template.md?" Per open issue it flags:
#   no-project              (issue belongs to no project)
#   no-priority             (left at the "No priority" default)
#   no-labels               (no label applied)
#   no-assignee             (no owner)
#   no-acceptance-criteria  (description has no '## Acceptance criteria' heading,
#                            case-insensitive)
#
# ADVISORY, WARN-only — never a gate. Deliberately NOT wired into `make verify`:
# CI has no Linear token, and issue hygiene is workspace state, not repo state.
# Run it manually or as part of a periodic hygiene sweep; the fix is upgrading
# the flagged issues to the linear/issue-template.md standard.
#
# Requires the lineark CLI (linear/linear-setup.md §3.2) and jq. Override the
# binary with $LINEARK_BIN — the hermetic tests use this to inject a stub that
# serves fixture JSON, so the check itself never needs live credentials to be
# testable.
#
# The list payload carries priority/labels/assignee but NOT project or
# description, so those two checks need a per-issue read. Reads run
# sequentially (Linear rate limits; see linear/linear-setup.md §7) and are
# capped by --max-reads; issues beyond the cap are still list-level-checked
# and are NAMED as unchecked — no silent truncation.
#
# Usage:
#   check-linear-hygiene.sh [--max-reads <n>] [--list]
#
#   --max-reads <n>  cap on per-issue read calls for the project/body checks
#                    (default 50; 0 = list-level checks only).
#   --list           machine mode: one line per flagged issue,
#                    `IDENTIFIER<TAB>gap[,gap...]`. Nothing when clean.
#
# Exit codes (BOTH modes):
#   0  clean — no checked issue has a hygiene gap
#   1  gaps  — at least one open issue has a hygiene gap (advisory WARN)
#   2  skip  — could not determine (no lineark / no jq / list call failed /
#              bad argument). Callers treat exit 2 as "say nothing".
set -uo pipefail

LINEARK_BIN="${LINEARK_BIN:-lineark}"
MAX_READS=50
MODE_LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    # Guard the value BEFORE `shift 2` (parity with check-freshness.sh): a
    # value-less flag would otherwise re-loop on itself forever.
    --max-reads) [ $# -ge 2 ] || { printf 'check-linear-hygiene: --max-reads needs a value\n' >&2; exit 2; }
                 MAX_READS="$2"; shift 2 ;;
    --list)      MODE_LIST=1; shift ;;
    *) printf 'check-linear-hygiene: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$MAX_READS" in
  ''|*[!0-9]*) printf 'check-linear-hygiene: --max-reads must be a non-negative integer\n' >&2; exit 2 ;;
esac

# skip <reason> — emit the reason (human mode only) and exit 2 (indeterminate).
skip() {
  [ "$MODE_LIST" -eq 1 ] || printf 'SKIP %s\n' "$1" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || skip "jq unavailable; cannot parse issue payloads"
command -v "$LINEARK_BIN" >/dev/null 2>&1 || skip "lineark not found (\$LINEARK_BIN or PATH) — see linear/linear-setup.md §3.2"

list_json="$("$LINEARK_BIN" issues list --format json 2>/dev/null)" || skip "lineark issues list failed"
printf '%s' "$list_json" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || skip "unexpected issues-list payload (not a JSON array)"

total="$(printf '%s' "$list_json" | jq 'length')"
if [ "$total" -eq 0 ]; then
  [ "$MODE_LIST" -eq 1 ] || printf 'PASS no open issues to check\n'
  exit 0
fi

flagged=0
reads=0
unchecked=()

# Iterate in the CURRENT shell via process substitution (not a pipe, which
# would subshell the counters — same pattern as check-freshness.sh). Empty
# fields become a "-" sentinel in jq BEFORE @tsv: tab is IFS whitespace, so
# adjacent tabs from empty middle fields would collapse and misalign `read`.
# The s() helper also tolerates the Linear-MCP-shaped payloads (arrays /
# objects where lineark returns flat strings) rather than crashing @tsv.
while IFS=$'\t' read -r ident priority labels assignee; do
  [ -n "$ident" ] && [ "$ident" != "-" ] || continue
  g_project=0; g_priority=0; g_labels=0; g_assignee=0; g_ac=0
  case "$priority" in "No priority"|"-") g_priority=1 ;; esac
  [ "$labels" = "-" ] && g_labels=1
  [ "$assignee" = "-" ] && g_assignee=1

  if [ "$reads" -lt "$MAX_READS" ]; then
    reads=$((reads + 1))
    if read_json="$("$LINEARK_BIN" issues read "$ident" --format json 2>/dev/null)" \
       && printf '%s' "$read_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
      printf '%s' "$read_json" | jq -e '.project != null' >/dev/null 2>&1 || g_project=1
      printf '%s' "$read_json" | jq -e '(.description // "") | ascii_downcase | contains("## acceptance criteria")' >/dev/null 2>&1 || g_ac=1
    else
      # Read failed — project/body state is UNKNOWN, not a gap. Name it.
      unchecked+=("$ident")
    fi
  else
    unchecked+=("$ident")
  fi

  gaps=()
  [ "$g_project"  -eq 1 ] && gaps+=("no-project")
  [ "$g_priority" -eq 1 ] && gaps+=("no-priority")
  [ "$g_labels"   -eq 1 ] && gaps+=("no-labels")
  [ "$g_assignee" -eq 1 ] && gaps+=("no-assignee")
  [ "$g_ac"       -eq 1 ] && gaps+=("no-acceptance-criteria")
  if [ "${#gaps[@]}" -gt 0 ]; then
    flagged=$((flagged + 1))
    joined="$(IFS=,; printf '%s' "${gaps[*]}")"
    if [ "$MODE_LIST" -eq 1 ]; then
      printf '%s\t%s\n' "$ident" "$joined"
    else
      printf 'WARN %s: %s\n' "$ident" "$joined"
    fi
  fi
done < <(printf '%s' "$list_json" | jq -r '
  def s(f): (f // ""
    | if type == "array"
      then (map(if type == "object" then (.name // tostring) else tostring end) | join(", "))
      elif type == "object" then (.name // tostring)
      else tostring end)
    | if . == "" then "-" else . end;
  .[] | [ s(.identifier), s(.priority), s(.labels), s(.assignee) ] | @tsv')

if [ "${#unchecked[@]}" -gt 0 ] && [ "$MODE_LIST" -eq 0 ]; then
  printf 'NOTE %s open issue(s) not checked for project/body (read cap --max-reads=%s, or a failed read): %s\n' \
    "${#unchecked[@]}" "$MAX_READS" "${unchecked[*]}"
fi

if [ "$flagged" -eq 0 ]; then
  if [ "$MODE_LIST" -eq 0 ]; then
    if [ "${#unchecked[@]}" -gt 0 ]; then
      printf 'PASS %s open issue(s) meet the standard on all checked fields (%s unchecked for project/body)\n' \
        "$total" "${#unchecked[@]}"
    else
      printf 'PASS all %s open issue(s) meet the issue-creation standard\n' "$total"
    fi
  fi
  exit 0
fi

[ "$MODE_LIST" -eq 1 ] || printf 'SUMMARY %s of %s open issue(s) have hygiene gaps — advisory; the standard is linear/issue-template.md\n' \
  "$flagged" "$total"
exit 1
