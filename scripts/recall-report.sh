#!/usr/bin/env bash
# scripts/recall-report.sh — read-only, deterministic ROLLING COUNT of recorded
# recall failures across the latest N meaningful session logs.
#
# WHY THIS EXISTS. capabilities/closeout.md's Q1a asks every closeout to record
# whether a rule that WAS available at orient failed to fire, and to classify the
# miss. Those records accumulate in the durable session logs and are then never
# read: nobody can say whether recall is getting better or worse, so "the memory
# system works" is an assertion, not an observation. This script turns the
# already-written records into a number that can be looked at over time.
#
# WHAT IT IS NOT. This is INFORMATIONAL. It is a rolling COUNT and a rolling
# RATE, not a score, a grade, a threshold, or a gate. There is deliberately no
# pass/fail verdict and no target number: the sample is small, the denominator
# is a proxy, and a metric that grades the operator's own honesty about their
# misses is a metric that stops being recorded honestly. Exit status reports
# whether the REPORT could be produced — never whether the number is "good".
#
# THE "MEANINGFUL SESSION LOG" MARKER, and why this one.
#   Marker: a line that is exactly `## Issues this session`.
# The denominator has to be "sessions that ran a real closeout", because only a
# real closeout writes a Q1a record at all — counting every file in the archive
# would silently deflate the rate with logs that never had the opportunity to
# record a miss. Two markers were candidates, both from the session-summary
# template (obsidian/ vault templates, `80-Templates/session-summary.md`):
#   `## TL;DR`               — present in essentially every file, including thin
#                              or aborted logs. Too permissive: it selects
#                              "a file exists", not "a closeout ran".
#   `## Issues this session`  — the template's work-content section. CHOSEN.
# On the corpus this was calibrated against, the two markers differed by five
# files, and every file the stricter marker excluded was a hand-shaped log that
# had dropped the template's section structure. The stricter marker is also the
# more stable string: `TL;DR` is generic prose that could plausibly appear as a
# heading in a non-session note dropped into the same folder, while
# `## Issues this session` is template-specific.
# HONEST LIMITATION: this therefore measures TEMPLATE-CONFORMANT closeout logs,
# not "meaningful sessions" in some deeper sense. A closeout that used a
# different heading is invisible to the denominator AND to the numerator, so it
# cannot skew the rate in either direction — but it does shrink the sample.
#
# THE EXTRACTION CONTRACT, biased hard toward UNDER-reporting.
# A recall-failure RECORD is a line that begins with the bold record marker:
#
#     **Recall failure, class not-loaded:** <prose>
#     **Recall failure, class loaded-but-ignored:** <prose>
#
# Only `^\*\*Recall failure` at the start of a line is a record at all. Prose
# ABOUT recall failures is not a record, and the corpus is full of prose that a
# looser scanner reads as one — negations ("Recall failure: none"), bulleted
# older formats, reversed word order, parenthetical classes, headings, and a
# bare class token used as a noun mid-sentence. Every one of those shapes is
# pinned as a restraint fixture in tests/recall-report.test.sh. The cost of the
# strictness is real (older bulleted records are NOT counted, so early windows
# under-report); the cost of the alternative is a number nobody trusts.
#
# A record whose class token is not one of the two known classes is NOT guessed
# at. It lands in a separate `unclassified` informational count, so a typo or a
# newly-invented class is visible as "something was recorded here that this
# scanner does not understand" rather than being silently binned into a class it
# may not belong to, or silently dropped.
#
# Usage:
#   recall-report.sh [--sessions-dir <path>] [--window N] [--list] [--isolated]
#   recall-report.sh --help
#
#   --sessions-dir <path>  directory of session logs to scan. Default:
#                          <vault>/30-Archive/Sessions, where <vault> is
#                          $OBSIDIAN_VAULT_PATH, falling back to the repo-root
#                          local.env OBSIDIAN_VAULT_PATH key.
#                          RESOLUTION ORDER: flag > ambient env > local.env.
#                          (Documented divergence: self-audit.sh's house order
#                          puts local.env ahead of ambient env. Here the ambient
#                          env wins, because this script is expected to be run
#                          ad hoc against a chosen vault by exporting the var,
#                          and a stale local.env silently overriding that export
#                          is the surprising outcome. The flag beats both.)
#   --window N             how many of the newest meaningful logs to scan
#                          (default 20). Must be a positive integer.
#   --list                 machine mode: tab-separated records, for self-audit.
#   --isolated             no ambient-env / local.env fallbacks (tests).
#   --help                 this text.
#
# ORDERING. Session-log filenames are `YYYY-MM-DD-HHMMSS-<host>-<id>.md`, so a
# byte-wise (LC_ALL=C) lexicographic sort IS chronological order. The window is
# the LAST N of that sort. No mtime is consulted: a vault that syncs through
# cloud storage rewrites mtimes on files whose content never changed.
#
# --list record shape (tab-separated, stable field order):
#   counts<TAB>window<TAB>considered<TAB>meaningful_total<TAB>scanned<TAB>not_loaded<TAB>loaded_but_ignored<TAB>unclassified
#   record<TAB>class<TAB>file:line
# Exactly one `counts` record is emitted, first, whenever a report was produced.
# Its ABSENCE (with exit 0) is how a caller detects a named skip.
#
# Exit codes:
#   0  report produced, OR a NAMED skip (reason on stderr as `SKIP <reason>`,
#      and in human mode also on stdout). A skip is never a silent zero-count
#      report: the counts block is omitted entirely rather than printed as zeros.
#      Skips: no sessions dir configured at all; zero meaningful logs found.
#   2  usage error (bad flag, bad --window) or SCAN error (fail closed, loud).
#      A scan error is a CONFIGURED sessions dir that does not exist or cannot
#      be read — a misspelled or unsynced path, whose zero-count report would be
#      indistinguishable from a genuinely clean window.
#
# Read-only: this script never writes, moves, or edits anything it scans.
#
# Tests: tests/recall-report.test.sh (+ the .ps1 twin).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The vault-relative location of the session-log archive.
SESSIONS_REL="30-Archive/Sessions"
# The meaningful-log marker. Line-anchored, exact heading (trailing whitespace
# tolerated). See the header for why this marker and not `## TL;DR`.
MEANINGFUL_RE='^## Issues this session[[:space:]]*$'
# The record marker. ONLY a line starting with this is a recall-failure record.
RECORD_RE='^\*\*Recall failure'

SESSIONS_DIR=""
WINDOW=20
MODE_LIST=0
ISOLATED=0

usage() {
  sed -nE 's|^# ?||p' "$0" | awk '/^Usage:/,/^Tests:/'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --sessions-dir)
      [ $# -ge 2 ] || { printf 'recall-report: --sessions-dir needs a path\n' >&2; exit 2; }
      SESSIONS_DIR="$2"; shift 2 ;;
    --window)
      [ $# -ge 2 ] || { printf 'recall-report: --window needs a value\n' >&2; exit 2; }
      WINDOW="$2"; shift 2 ;;
    --list) MODE_LIST=1; shift ;;
    --isolated) ISOLATED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'recall-report: unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$WINDOW" in
  ''|*[!0-9]*) printf 'recall-report: --window must be a positive integer, got: %s\n' "$WINDOW" >&2; exit 2 ;;
esac
[ "$WINDOW" -gt 0 ] || { printf 'recall-report: --window must be a positive integer, got: %s\n' "$WINDOW" >&2; exit 2; }

# _rr_localenv_get <path> <key> — read ONE key from local.env as DATA, without
# sourcing it. Byte-parity with self-audit.sh's _sa_localenv_get: sourcing the
# file would EXECUTE it, and a malformed or hostile local.env could then export
# a PATH that poisons the `grep`/`awk`/`sort` lookups below. Mirrors bash
# assignment semantics for one key: last assignment wins; one matching
# surrounding quote pair is stripped; otherwise an unquoted backslash-escape
# collapses (\<c> -> <c>), matching scripts/lib/local-env.ps1.
_rr_localenv_get() {
  local path="$1" key="$2" line t v f l inner result=""
  [ -f "$path" ] || { printf '%s' ""; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    t="${line#"${line%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    [ -z "$t" ] && continue
    case "$t" in '#'*) continue ;; esac
    case "$t" in
      export[[:space:]]*) t="${t#export}"; t="${t#"${t%%[![:space:]]*}"}" ;;
    esac
    case "$t" in
      "$key="*) v="${t#"$key="}" ;;
      *) continue ;;
    esac
    if [ "${#v}" -ge 2 ]; then
      f="${v:0:1}"; l="${v:$(( ${#v} - 1 )):1}"
      if { [ "$f" = '"' ] && [ "$l" = '"' ]; } || { [ "$f" = "'" ] && [ "$l" = "'" ]; }; then
        inner=$(( ${#v} - 2 )); v="${v:1:$inner}"
      else
        case "$v" in
          *'\'*) v="$(printf '%s' "$v" | sed -E 's/\\(.)/\1/g')" ;;
        esac
      fi
    fi
    result="$v"
  done < "$path"
  printf '%s' "$result"
}

# _rr_skip <reason> — a NAMED skip. Never a silent zero-count report: the counts
# block is omitted entirely, so no caller can mistake "could not measure" for
# "measured, and it was zero".
_rr_skip() {
  printf 'SKIP %s\n' "$1" >&2
  if [ "$MODE_LIST" -eq 0 ]; then
    printf '# recall-report — INFORMATIONAL rolling recall-failure count\n\n'
    printf 'SKIP — %s\n' "$1"
    printf '\nNo counts are reported. This is an indeterminate result, NOT a clean zero.\n'
  fi
  exit 0
}

# --- resolve the sessions dir -------------------------------------------------
SESSIONS_SRC=""
if [ -n "$SESSIONS_DIR" ]; then
  SESSIONS_SRC="--sessions-dir flag"
elif [ "$ISOLATED" -eq 0 ]; then
  _vault=""
  if [ -n "${OBSIDIAN_VAULT_PATH:-}" ]; then
    _vault="$OBSIDIAN_VAULT_PATH"; SESSIONS_SRC='$OBSIDIAN_VAULT_PATH'
  else
    _vault="$(_rr_localenv_get "$REPO_ROOT/local.env" OBSIDIAN_VAULT_PATH)"
    [ -n "$_vault" ] && SESSIONS_SRC='local.env OBSIDIAN_VAULT_PATH'
  fi
  if [ -n "$_vault" ]; then
    # Strip a trailing slash so the joined path never doubles it.
    _vault="${_vault%/}"
    SESSIONS_DIR="$_vault/$SESSIONS_REL"
  fi
fi

if [ -z "$SESSIONS_DIR" ]; then
  _rr_skip "no sessions directory configured (no --sessions-dir, no \$OBSIDIAN_VAULT_PATH, no local.env OBSIDIAN_VAULT_PATH) — nothing to scan"
fi

# A CONFIGURED but broken surface is a SCAN ERROR, not a skip. Same reasoning as
# closeout-gate.sh's configured-but-nonexistent vault: a misspelled or unsynced
# path would otherwise report a clean zero that looks exactly like a clean window.
if [ ! -d "$SESSIONS_DIR" ]; then
  printf 'recall-report: SCAN ERROR — configured sessions directory does not exist: %s\n' "$SESSIONS_DIR" >&2
  exit 2
fi
if [ ! -r "$SESSIONS_DIR" ] || [ ! -x "$SESSIONS_DIR" ]; then
  printf 'recall-report: SCAN ERROR — configured sessions directory is not readable: %s\n' "$SESSIONS_DIR" >&2
  exit 2
fi

# --- select the window --------------------------------------------------------
# LC_ALL=C throughout: `sort` and the byte-oriented `grep`/`awk` below must not
# change collation or character-class semantics with the caller's locale (the
# single-locale-blind-spot lesson). Filename order IS chronological under a
# byte-wise sort; it is NOT guaranteed under a locale-aware one.

ALL_FILES=()
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  ALL_FILES[${#ALL_FILES[@]}]="$_f"
done <<EOF
$(LC_ALL=C find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
EOF

CONSIDERED="${#ALL_FILES[@]}"
if [ "$CONSIDERED" -eq 0 ]; then
  _rr_skip "no .md files in $SESSIONS_DIR — nothing to scan"
fi

# ONE grep over the whole set (not a per-file loop): -l lists the files that
# carry the marker. `grep -l` exits 1 when NOTHING matches — an EXPECTED
# non-zero, distinguished from a real error by the exit code: only >=2 is a
# failure to read.
_MEANINGFUL_RAW="$(LC_ALL=C grep -lE "$MEANINGFUL_RE" "${ALL_FILES[@]}" 2>/dev/null)"
_grc=$?
# grep: 0 = matches, 1 = no matches (an EXPECTED outcome), >=2 = a file it could
# not read. An unreadable file would silently understate the denominator — the
# same false-clean shape as a misspelled dir — so it fails loud, not soft.
if [ "$_grc" -ge 2 ]; then
  printf 'recall-report: SCAN ERROR — a session log could not be read while scanning %s\n' "$SESSIONS_DIR" >&2
  exit 2
fi
MEANINGFUL=()
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  MEANINGFUL[${#MEANINGFUL[@]}]="$_f"
done <<EOF
$(printf '%s' "$_MEANINGFUL_RAW" | LC_ALL=C sort)
EOF

MEANINGFUL_TOTAL="${#MEANINGFUL[@]}"
if [ "$MEANINGFUL_TOTAL" -eq 0 ]; then
  _rr_skip "no meaningful session logs found in $SESSIONS_DIR ($CONSIDERED file(s) considered; none carry the marker '## Issues this session') — indeterminate, not a clean zero"
fi

# Newest $WINDOW of the chronological sort.
START=0
[ "$MEANINGFUL_TOTAL" -gt "$WINDOW" ] && START=$(( MEANINGFUL_TOTAL - WINDOW ))
SCANNED_FILES=("${MEANINGFUL[@]:$START}")
SCANNED="${#SCANNED_FILES[@]}"

# --- extract ------------------------------------------------------------------
# ONE grep pass over the window (line-anchored on the bold record marker), then
# ONE awk pass to classify. No per-line subshell pipelines.
#
# Class resolution: the token immediately after `, class ` must be a KNOWN class
# and must end at a non-class character, so `loaded-but-ignored + no act-time
# gate` still resolves to `loaded-but-ignored` while a longer unknown token
# (e.g. `not-loaded-ish`) does NOT masquerade as a known one.
RAW="$(LC_ALL=C grep -nE "$RECORD_RE" "${SCANNED_FILES[@]}" 2>/dev/null)"
_grc=$?
# Same loud-read contract as the meaningful pass: 1 = no records (expected),
# >=2 = a selected file could not be read — never a silently understated count.
if [ "$_grc" -ge 2 ]; then
  printf 'recall-report: SCAN ERROR — a session log could not be read while extracting from %s\n' "$SESSIONS_DIR" >&2
  exit 2
fi

# grep prefixes `file:line:` only when given 2+ files; with exactly one file it
# prints `line:` alone. Normalize by telling awk how many files were scanned.
CLASSIFIED="$(printf '%s' "$RAW" | LC_ALL=C awk -v multi="$( [ "$SCANNED" -gt 1 ] && printf 1 || printf 0 )" -v single="${SCANNED_FILES[0]}" '
  BEGIN { FS = ":"; OFS = "\t" }
  length($0) == 0 { next }
  {
    if (multi == 1) {
      # file may itself contain ":" — even ":<digits>:" (a directory named
      # "run:12:archive" is a valid POSIX path). Every scanned path ends in
      # ".md" (the find -name filter), so anchor the separator search on
      # ".md:<digits>:" instead of the first bare ":<digits>:". A DIRECTORY
      # component containing ".md:<digits>:" could still mis-anchor; that is
      # an accepted residual, strictly narrower than the bare form.
      if (match($0, /\.md:[0-9]+:/)) {
        loc = substr($0, 1, RSTART + 2) ":" substr($0, RSTART + 4, RLENGTH - 5)
        body = substr($0, RSTART + RLENGTH)
      } else { next }
    } else {
      if (match($0, /^[0-9]+:/)) {
        loc = single ":" substr($0, 1, RLENGTH - 1)
        body = substr($0, RLENGTH + 1)
      } else { next }
    }
    cls = "unclassified"
    if (body ~ /^\*\*Recall failure, class not-loaded([^A-Za-z0-9-]|$)/)            cls = "not-loaded"
    else if (body ~ /^\*\*Recall failure, class loaded-but-ignored([^A-Za-z0-9-]|$)/) cls = "loaded-but-ignored"
    print cls, loc
  }
')"

N_NOT_LOADED=0
N_IGNORED=0
N_UNCLASSIFIED=0
RECORDS=()
while IFS=$'\t' read -r _cls _loc; do
  [ -n "$_cls" ] || continue
  case "$_cls" in
    not-loaded)         N_NOT_LOADED=$(( N_NOT_LOADED + 1 )) ;;
    loaded-but-ignored) N_IGNORED=$(( N_IGNORED + 1 )) ;;
    *)                  N_UNCLASSIFIED=$(( N_UNCLASSIFIED + 1 )) ;;
  esac
  RECORDS[${#RECORDS[@]}]="$_cls"$'\t'"$_loc"
done <<EOF
$CLASSIFIED
EOF

CLASSIFIED_TOTAL=$(( N_NOT_LOADED + N_IGNORED ))
# LC_ALL=C on the awk that formats the rate: a comma-decimal locale would print
# "0,15" and every downstream numeric parse would break.
RATE="$(LC_ALL=C awk -v n="$CLASSIFIED_TOTAL" -v d="$SCANNED" 'BEGIN{ printf "%.2f", (d > 0 ? n / d : 0) }')"

# --- report -------------------------------------------------------------------
if [ "$MODE_LIST" -eq 1 ]; then
  printf 'counts\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$WINDOW" "$CONSIDERED" "$MEANINGFUL_TOTAL" "$SCANNED" \
    "$N_NOT_LOADED" "$N_IGNORED" "$N_UNCLASSIFIED"
  for _r in ${RECORDS[@]+"${RECORDS[@]}"}; do
    printf 'record\t%s\n' "$_r"
  done
  exit 0
fi

printf '# recall-report — INFORMATIONAL rolling recall-failure count\n\n'
printf 'sessions dir:            %s (%s)\n' "$SESSIONS_DIR" "${SESSIONS_SRC:-resolved}"
printf 'meaningful marker:       ## Issues this session\n'
printf 'window:                  %s\n' "$WINDOW"
printf 'files considered:        %s\n' "$CONSIDERED"
printf 'meaningful logs found:   %s\n' "$MEANINGFUL_TOTAL"
printf 'meaningful logs scanned: %s (the newest %s of them, by filename order)\n' "$SCANNED" "$SCANNED"
printf '\nrecall-failure records in window:\n'
printf -- '- not-loaded:          %s\n' "$N_NOT_LOADED"
printf -- '- loaded-but-ignored:  %s\n' "$N_IGNORED"
printf -- '- classified total:    %s\n' "$CLASSIFIED_TOTAL"
printf -- '- unclassified recall-failure mentions (informational, NOT assigned a class): %s\n' "$N_UNCLASSIFIED"
printf '\nrate: %s recall-failure records per meaningful session scanned (%s / %s)\n' \
  "$RATE" "$CLASSIFIED_TOTAL" "$SCANNED"

if [ "${#RECORDS[@]}" -gt 0 ]; then
  printf '\nrecords:\n'
  for _r in "${RECORDS[@]}"; do
    printf -- '- %s\n' "$(printf '%s' "$_r" | LC_ALL=C tr '\t' ' ')"
  done
fi

printf '\nINFORMATIONAL — this is a rolling rate, not a scored or graded metric.\n'
printf 'Nothing here passes, fails, or grades anything, and there is no target\n'
printf 'number. The extractor is deliberately strict (only line-leading\n'
printf '`**Recall failure, class <X>` records count), so the true count can only\n'
printf 'be HIGHER than what is reported here, never lower.\n'
exit 0
