#!/usr/bin/env bash
# scripts/check-linear-hygiene.sh — advisory Linear issue-hygiene signal.
#
# Answers: "do the workspace's OPEN issues meet the issue-creation standard in
# linear/issue-template.md?" Per open issue it flags:
#   no-project              (issue belongs to no project)
#   no-priority             (left at the "No priority" default)
#   no-labels               (no label applied)
#   no-assignee             (no owner)
#   no-acceptance-criteria  (description has no '## Acceptance criteria'
#                            H2 heading — line-anchored, case-insensitive, so a
#                            '###' heading or a prose mention does not count)
#
# The standard's documented escapes are honored: when the issue body contains
# "Deliberately projectless" / "Deliberately unassigned" (case-insensitive),
# the corresponding gap is suppressed — those are CONFORMING per
# linear/issue-template.md. The escapes live in the description, so they can
# only be honored for issues whose read succeeded (see --max-reads below).
#
# SCOPE: this checks the machine-visible subset of the standard. Team is
# enforced by the create command itself; parent/relations and body-section
# completeness beyond the AC heading are judgment calls the sweep does not
# police. The PASS line claims exactly the checked fields, nothing more.
# Open-only scope relies on lineark's documented default of hiding
# Done/Canceled in `issues list` (linear/linear-setup.md §4.1/§4.3).
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
# description, so those checks need a per-issue read. Reads run sequentially
# (Linear rate limits; see linear/linear-setup.md §7) and are capped by
# --max-reads; issues beyond the cap (or whose read fails) stay
# list-level-checked and are NAMED as unchecked — no silent truncation, in
# EITHER output mode.
#
# Usage:
#   check-linear-hygiene.sh [--max-reads <n>] [--list]
#
#   --max-reads <n>  cap on per-issue read calls for the project/body checks
#                    (default 50; 0 = list-level checks only).
#   --list           machine mode: one line per flagged OR unchecked issue,
#                    `IDENTIFIER<TAB>token[,token...]`. Tokens are the five
#                    gap slugs above plus `unchecked` (project/body state
#                    unknown — read capped or failed). Nothing when every
#                    issue is fully checked and clean.
#
# Exit codes (BOTH modes):
#   0  clean — no evaluated issue has a hygiene gap (unchecked-only is clean)
#   1  gaps  — at least one open issue has a hygiene gap (advisory WARN)
#   2  skip  — could not determine (no lineark / no jq / list call failed /
#              unparseable payload / bad argument). Callers treat exit 2 as
#              "say nothing".
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
rows_seen=0
evaluated=0
malformed=0
unchecked=()

# Iterate in the CURRENT shell via process substitution (not a pipe, which
# would subshell the counters — same pattern as check-freshness.sh). Empty
# fields become a "-" sentinel in jq BEFORE @tsv: tab is IFS whitespace, so
# adjacent tabs from empty middle fields would collapse and misalign `read`.
# The s() helper also tolerates the Linear-MCP-shaped payloads (arrays /
# objects where lineark returns flat strings) rather than crashing @tsv.
# rows_seen/evaluated are audited after the loop: a jq crash mid-stream or a
# payload of identifier-less entries must yield skip (2), never a false PASS.
while IFS=$'\t' read -r ident priority labels assignee; do
  rows_seen=$((rows_seen + 1))
  if [ -z "$ident" ] || [ "$ident" = "-" ]; then
    malformed=$((malformed + 1))
    continue
  fi
  evaluated=$((evaluated + 1))
  g_project=0; g_priority=0; g_labels=0; g_assignee=0; g_ac=0; is_unchecked=0
  case "$priority" in "No priority"|"-") g_priority=1 ;; esac
  [ "$labels" = "-" ] && g_labels=1
  [ "$assignee" = "-" ] && g_assignee=1

  if [ "$reads" -lt "$MAX_READS" ]; then
    reads=$((reads + 1))
    if read_json="$("$LINEARK_BIN" issues read "$ident" --format json 2>/dev/null)" \
       && printf '%s' "$read_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
      printf '%s' "$read_json" | jq -e '.project != null' >/dev/null 2>&1 || g_project=1
      # Line-anchored H2 match via split: this jq build's `^` anchors only at
      # STRING start (no per-line anchoring), so test alone would miss any
      # heading that is not the first line.
      printf '%s' "$read_json" | jq -e '(.description // "") | split("\n") | map(test("^##[ \\t]+acceptance criteria"; "i")) | any' >/dev/null 2>&1 || g_ac=1
      # Standard-blessed escapes (issue-template.md): a stated reason in the
      # body makes projectless / unassigned CONFORMING — suppress those gaps.
      if [ "$g_project" -eq 1 ] \
         && printf '%s' "$read_json" | jq -e '(.description // "") | ascii_downcase | contains("deliberately projectless")' >/dev/null 2>&1; then
        g_project=0
      fi
      if [ "$g_assignee" -eq 1 ] \
         && printf '%s' "$read_json" | jq -e '(.description // "") | ascii_downcase | contains("deliberately unassigned")' >/dev/null 2>&1; then
        g_assignee=0
      fi
    else
      # Read failed — project/body state is UNKNOWN, not a gap. Name it.
      is_unchecked=1
      unchecked+=("$ident")
    fi
  else
    is_unchecked=1
    unchecked+=("$ident")
  fi

  gaps=()
  [ "$g_project"  -eq 1 ] && gaps+=("no-project")
  [ "$g_priority" -eq 1 ] && gaps+=("no-priority")
  [ "$g_labels"   -eq 1 ] && gaps+=("no-labels")
  [ "$g_assignee" -eq 1 ] && gaps+=("no-assignee")
  [ "$g_ac"       -eq 1 ] && gaps+=("no-acceptance-criteria")
  [ "${#gaps[@]}" -gt 0 ] && flagged=$((flagged + 1))
  if [ "$MODE_LIST" -eq 1 ]; then
    tokens=()
    [ "${#gaps[@]}" -gt 0 ] && tokens=("${gaps[@]}")
    [ "$is_unchecked" -eq 1 ] && tokens+=("unchecked")
    if [ "${#tokens[@]}" -gt 0 ]; then
      joined="$(IFS=,; printf '%s' "${tokens[*]}")"
      printf '%s\t%s\n' "$ident" "$joined"
    fi
  else
    if [ "${#gaps[@]}" -gt 0 ]; then
      joined="$(IFS=,; printf '%s' "${gaps[*]}")"
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

# Stream/shape audit — never let a truncated or identifier-less payload read
# as a clean verdict.
[ "$rows_seen" -eq "$total" ] || skip "issues-list parse truncated ($rows_seen of $total rows processed)"
[ "$evaluated" -gt 0 ] || skip "no parseable issues in list payload ($malformed of $total entries lack an identifier)"

if [ "$MODE_LIST" -eq 0 ]; then
  [ "$malformed" -gt 0 ] && \
    printf 'NOTE %s list entr(y/ies) without an identifier skipped\n' "$malformed"
  [ "${#unchecked[@]}" -gt 0 ] && \
    printf 'NOTE %s open issue(s) not checked for project/body (read cap --max-reads=%s, or a failed read): %s\n' \
      "${#unchecked[@]}" "$MAX_READS" "${unchecked[*]}"
fi

if [ "$flagged" -eq 0 ]; then
  if [ "$MODE_LIST" -eq 0 ]; then
    if [ "${#unchecked[@]}" -gt 0 ] || [ "$malformed" -gt 0 ]; then
      printf 'PASS %s evaluated open issue(s) clean on the checked fields (%s unchecked for project/body)\n' \
        "$evaluated" "${#unchecked[@]}"
    else
      printf 'PASS all %s open issue(s) clean on the checked fields (project, priority, labels, assignee, acceptance-criteria heading)\n' \
        "$evaluated"
    fi
  fi
  exit 0
fi

[ "$MODE_LIST" -eq 1 ] || printf 'SUMMARY %s of %s evaluated open issue(s) have hygiene gaps — advisory; the standard is linear/issue-template.md\n' \
  "$flagged" "$evaluated"
exit 1
