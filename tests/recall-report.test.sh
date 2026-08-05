#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/recall-report.test.sh — behavioral tests for scripts/recall-report.sh.
#
# The reporter is an INFORMATIONAL rolling count of the Q1a recall-failure
# records already written into the durable session logs. What is under test:
#
#   - EXTRACTION: both classes counted; unknown classes bucketed, never guessed
#   - RESTRAINT:  every prose shape observed in the real corpus that a looser
#                 scanner would miscount stays silent (§4 below)
#   - SELECTION:  the meaningful-log filter, and window trimming
#   - SKIPS:      named, never a silent zero-count report
#   - EXITS:      0 report/named-skip, 2 usage-or-scan error
#   - WIRING:     the self-audit informational key, and its score neutrality
#
# WHY THE RESTRAINT SECTION IS THE BULK OF THIS FILE. The extractor was written
# against the real ~320-log session archive BEFORE these tests existed, and the
# first cut over that corpus surfaced far more prose ABOUT recall failures than
# actual records: negations, an older bulleted format, reversed word order,
# parenthetical classes, a section heading, and a bare class token used as a
# noun mid-sentence. Each shape below is a paraphrase of a line that really
# appears there. Every restraint fixture is scanned ALONGSIDE one true-positive
# record, so a fixture can never pass vacuously by the scanner having gone
# silent altogether — the expected counts are "exactly the true positive, and
# nothing the restraint line contributed".
#
# All fixtures are hermetic temp dirs. Nothing here touches the live git index
# or the operator's vault.
#
# Sourced by tests/run.sh; do NOT set -e or call exit.

RR_SCRIPT="$REPO_ROOT/scripts/recall-report.sh"
assert_file "recall-report: scripts/recall-report.sh exists" "$RR_SCRIPT"
# The header documents direct execution, so the file must carry the executable
# bit — a 644 script turns the documented invocation into "permission denied".
if [ -x "$RR_SCRIPT" ]; then
  _pass "recall-report: the reporter is executable (its documented usage is direct invocation)"
else
  _fail "recall-report: the reporter is executable (its documented usage is direct invocation)" \
    "not executable: $RR_SCRIPT"
fi

RR_TMP="$(mktemp -d)"

# _rr_log <dir> <name> <body...> — write a MEANINGFUL session log (one carrying
# the `## Issues this session` marker) whose Lessons section holds <body>.
_rr_log() {
  local dir="$1" name="$2"; shift 2
  mkdir -p "$dir"
  {
    printf -- '---\ntitle: fixture\n---\n\n'
    printf -- '# fixture session\n\n'
    printf -- '## TL;DR\n\nfixture.\n\n'
    printf -- '## Issues this session\n\n### FIX-1 — fixture\n\n'
    printf -- '## Lessons (Q1a recall-failure record)\n\n'
    local l
    for l in "$@"; do printf '%s\n\n' "$l"; done
  } > "$dir/$name"
}

# _rr_thin_log <dir> <name> <body...> — a NON-meaningful log: same content, but
# without the `## Issues this session` marker. The denominator must exclude it,
# and so must the numerator.
_rr_thin_log() {
  local dir="$1" name="$2"; shift 2
  mkdir -p "$dir"
  {
    printf -- '---\ntitle: fixture\n---\n\n'
    printf -- '# thin session\n\n'
    printf -- '## TL;DR\n\nfixture.\n\n'
    printf -- '## Issues\n\nnot the template heading.\n\n'
    printf -- '## Lessons (Q1a recall-failure record)\n\n'
    local l
    for l in "$@"; do printf '%s\n\n' "$l"; done
  } > "$dir/$name"
}

# _rr_counts <dir> [extra args...] — run --list and echo just the counts record.
# `grep` is expected to find exactly one; a missing counts record echoes empty,
# which every caller asserts against explicitly rather than silently tolerating.
_rr_counts() {
  local dir="$1"; shift
  LC_ALL=C bash "$RR_SCRIPT" --sessions-dir "$dir" "$@" --list 2>/dev/null \
    | LC_ALL=C grep '^counts' || true
}

# _rr_expect <window> <considered> <meaningful> <scanned> <not-loaded> <ignored> <unclassified>
_rr_expect() {
  printf 'counts\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

# The canonical true-positive records, in the exact shape closeout writes them.
RR_TP_NOT_LOADED='**Recall failure, class not-loaded:** the rule lived in a note that was never read at orient.'
RR_TP_IGNORED='**Recall failure, class loaded-but-ignored:** the rule was in context at orient but did not fire.'

# === 1. POSITIVE CONTROLS — both classes are counted, and located.
RR_BOTH="$RR_TMP/both"
_rr_log "$RR_BOTH" "2026-01-01-000000-host-aaaaaaaa.md" "$RR_TP_NOT_LOADED"
_rr_log "$RR_BOTH" "2026-01-02-000000-host-bbbbbbbb.md" "$RR_TP_IGNORED"
assert_eq "recall-report: both classes are counted (1 not-loaded, 1 loaded-but-ignored)" \
  "$(_rr_expect 20 2 2 2 1 1 0)" "$(_rr_counts "$RR_BOTH")"

RR_BOTH_LIST="$(bash "$RR_SCRIPT" --sessions-dir "$RR_BOTH" --list 2>/dev/null)"
assert_contains "recall-report: a not-loaded record is emitted with its file:line" \
  "$RR_BOTH_LIST" "record	not-loaded	$RR_BOTH/2026-01-01-000000-host-aaaaaaaa.md:"
assert_contains "recall-report: a loaded-but-ignored record is emitted with its file:line" \
  "$RR_BOTH_LIST" "record	loaded-but-ignored	$RR_BOTH/2026-01-02-000000-host-bbbbbbbb.md:"

# Two records in ONE log are two records — the count is per RECORD, not per file.
RR_TWO_IN_ONE="$RR_TMP/two-in-one"
_rr_log "$RR_TWO_IN_ONE" "2026-01-01-000000-host-aaaaaaaa.md" "$RR_TP_NOT_LOADED" "$RR_TP_IGNORED"
assert_eq "recall-report: two records in one log are counted separately" \
  "$(_rr_expect 20 1 1 1 1 1 0)" "$(_rr_counts "$RR_TWO_IN_ONE")"

# The human report states, in words, that it is not a scored metric. This is a
# CONTRACT of the driving issue (no premature scoring), not decoration.
RR_HUMAN="$(bash "$RR_SCRIPT" --sessions-dir "$RR_BOTH" 2>/dev/null)"
assert_contains "recall-report: the human report declares itself INFORMATIONAL" \
  "$RR_HUMAN" "INFORMATIONAL"
assert_contains "recall-report: the human report denies being a scored/graded metric" \
  "$RR_HUMAN" "not a scored or graded metric"
assert_contains "recall-report: the human report states the rolling rate" \
  "$RR_HUMAN" "rate: 1.00 recall-failure records per meaningful session scanned (2 / 2)"
assert_contains "recall-report: the human report names the window" "$RR_HUMAN" "window:                  20"
assert_contains "recall-report: the human report names how many files were considered" \
  "$RR_HUMAN" "files considered:        2"
assert_contains "recall-report: the human report names the meaningful-log count scanned" \
  "$RR_HUMAN" "meaningful logs scanned: 2"

# === 2. UNKNOWN CLASSES are bucketed, never guessed into a known class.
RR_UNK="$RR_TMP/unknown"
_rr_log "$RR_UNK" "2026-01-01-000000-host-aaaaaaaa.md" \
  "$RR_TP_IGNORED" \
  '**Recall failure, class wrong-shelf:** a class this scanner has never seen.' \
  '**Recall failure:** a record with no class token at all.'
assert_eq "recall-report: an unknown class goes to the unclassified bucket, not to a known class" \
  "$(_rr_expect 20 1 1 1 0 1 2)" "$(_rr_counts "$RR_UNK")"

# A LONGER token that merely starts with a known class must NOT be read as that
# class — the class boundary is enforced, so `not-loaded-ish` is unclassified.
RR_PREFIX="$RR_TMP/prefix"
_rr_log "$RR_PREFIX" "2026-01-01-000000-host-aaaaaaaa.md" \
  "$RR_TP_IGNORED" \
  '**Recall failure, class not-loaded-ish:** a near-miss token that must not be claimed.'
assert_eq "recall-report: a class token that merely PREFIXES a known class is unclassified" \
  "$(_rr_expect 20 1 1 1 0 1 1)" "$(_rr_counts "$RR_PREFIX")"

# A trailing qualifier after a KNOWN class still resolves to that class — this
# shape appears verbatim in the real corpus.
RR_QUAL="$RR_TMP/qualified"
_rr_log "$RR_QUAL" "2026-01-01-000000-host-aaaaaaaa.md" \
  '**Recall failure, class loaded-but-ignored + no act-time gate.** the rule existed and the gate did not.'
assert_eq "recall-report: a known class with a trailing qualifier still resolves to that class" \
  "$(_rr_expect 20 1 1 1 0 1 0)" "$(_rr_counts "$RR_QUAL")"

# === 3. SELECTION — the meaningful filter and window trimming.
#
# 3a. A non-meaningful log is excluded from BOTH the denominator and the
# numerator. It carries a real record, so a filter that leaked would be visible
# in the counts, not just in the file tally.
RR_FILTER="$RR_TMP/filter"
_rr_log      "$RR_FILTER" "2026-01-01-000000-host-aaaaaaaa.md" "$RR_TP_IGNORED"
_rr_thin_log "$RR_FILTER" "2026-01-02-000000-host-bbbbbbbb.md" "$RR_TP_NOT_LOADED"
assert_eq "recall-report: a non-meaningful log is excluded from the denominator AND the count" \
  "$(_rr_expect 20 2 1 1 0 1 0)" "$(_rr_counts "$RR_FILTER")"

# 3b. Window trimming: 5 meaningful logs, window 2 → only the NEWEST 2 scanned.
# The three older logs each carry a record, so a broken trim would show up as a
# higher count, not merely a different scanned tally.
RR_WIN="$RR_TMP/window"
_rr_log "$RR_WIN" "2026-01-01-000000-host-aaaaaaaa.md" "$RR_TP_NOT_LOADED"
_rr_log "$RR_WIN" "2026-01-02-000000-host-bbbbbbbb.md" "$RR_TP_NOT_LOADED"
_rr_log "$RR_WIN" "2026-01-03-000000-host-cccccccc.md" "$RR_TP_NOT_LOADED"
_rr_log "$RR_WIN" "2026-01-04-000000-host-dddddddd.md" "$RR_TP_IGNORED"
_rr_log "$RR_WIN" "2026-01-05-000000-host-eeeeeeee.md" "$RR_TP_IGNORED"
assert_eq "recall-report: --window trims to the NEWEST N meaningful logs" \
  "$(_rr_expect 2 5 5 2 0 2 0)" "$(_rr_counts "$RR_WIN" --window 2)"
assert_eq "recall-report: a window LARGER than the corpus scans everything, not N" \
  "$(_rr_expect 99 5 5 5 3 2 0)" "$(_rr_counts "$RR_WIN" --window 99)"
assert_eq "recall-report: --window 1 scans exactly the newest log" \
  "$(_rr_expect 1 5 5 1 0 1 0)" "$(_rr_counts "$RR_WIN" --window 1)"

# 3c. Chronology comes from the FILENAME sort, not from mtime — a vault synced
# through cloud storage rewrites mtimes on files whose content never changed.
# Touching the OLDEST file must not pull it into the window.
touch "$RR_WIN/2026-01-01-000000-host-aaaaaaaa.md"
assert_eq "recall-report: window selection ignores mtime (filename order is the clock)" \
  "$(_rr_expect 2 5 5 2 0 2 0)" "$(_rr_counts "$RR_WIN" --window 2)"

# === 4. RESTRAINT — real-corpus prose shapes that must NOT be counted.
#
# Each fixture pairs ONE restraint line with ONE true-positive record and
# asserts the counts are EXACTLY the true positive's. The paired true positive
# is what makes the assertion non-vacuous: a scanner that had simply stopped
# matching anything would fail these, not pass them.
_rr_restraint() { # _rr_restraint <slug> <label> <line>
  # Separate statements: in one `local`, bash declares every name before running
  # the assignments, so `dir=".../$slug"` would read an unset `slug` under -u.
  local slug="$1" label="$2" line="$3"
  local dir="$RR_TMP/restraint-$slug"
  _rr_log "$dir" "2026-01-01-000000-host-aaaaaaaa.md" "$line" "$RR_TP_IGNORED"
  assert_eq "recall-report: restraint — $label" \
    "$(_rr_expect 20 1 1 1 0 1 0)" "$(_rr_counts "$dir")"
}

_rr_restraint "negation-none" \
  "a bulleted 'Recall failure: none' negation is not a record" \
  '- Recall failure: none — the vault decision and operations lesson were loaded and applied.'

_rr_restraint "negation-no-action" \
  "a '[no-action] No recall failure occurred' line is not a record" \
  '- [no-action] No recall failure occurred; the existing session and review rules were loaded and applied.'

_rr_restraint "negation-inline" \
  "a negation buried mid-sentence is not a record" \
  '- [no-action] No new operating rule was needed. Recall failure: none this session.'

_rr_restraint "old-bulleted-classified" \
  "the OLDER bulleted classified format is deliberately not counted (documented under-report)" \
  '- [check] Recall failure, loaded-but-ignored: the lesson index already named the three-layer check.'

_rr_restraint "reversed-order" \
  "a reversed '[loaded-but-ignored recall failure]' bracket tag is not a record" \
  '- [loaded-but-ignored recall failure] The known working-directory rule was in context but the first run ignored it.'

_rr_restraint "prose-plural" \
  "prose describing misses as 'loaded-but-ignored recall failures' is not a record" \
  "- [inferred] The morning's discovery misses were loaded-but-ignored recall failures, not new rules."

_rr_restraint "section-heading" \
  "the section HEADING that introduces records is not itself a record" \
  '## Lessons (Q1a recall-failure record)'

_rr_restraint "parenthetical-class-agent" \
  "a bulleted parenthetical class '(Q1a, loaded-but-ignored)' is not a record" \
  '- [agent-summary] Recall failure (Q1a, loaded-but-ignored): the review rule was in context at orient but did not fire.'

_rr_restraint "parenthetical-class-bare" \
  "a bulleted parenthetical class '(loaded-but-ignored)' is not a record" \
  '- Recall failure (loaded-but-ignored): the pipe-exit rule was violated twice by the same shape.'

_rr_restraint "bare-class-token-in-prose" \
  "a bare class token used as a noun ('Surface class: not-loaded.') is not a record" \
  '- [inferred] Recall miss this session: the rule sat in a body that is not read at routing. Surface class: not-loaded.'

_rr_restraint "unbolded-line-start" \
  "an UNBOLDED line-start 'Recall failure, class ...' is not a record (the bold marker is the record)" \
  'Recall failure, class not-loaded: an unbolded line that predates the record marker.'

_rr_restraint "indented-record" \
  "an INDENTED record marker is not a line-start record" \
  '  **Recall failure, class not-loaded:** indented under another bullet, so not a top-level record.'

_rr_restraint "mid-line-marker" \
  "a record marker quoted mid-line is not a record" \
  'The template asks for a **Recall failure, class not-loaded:** line here.'

# Every restraint line together in ONE log, still alongside one true positive:
# proves the shapes do not combine into a match that none produced alone.
RR_ALL_FP="$RR_TMP/restraint-combined"
_rr_log "$RR_ALL_FP" "2026-01-01-000000-host-aaaaaaaa.md" \
  '- Recall failure: none — the lesson was loaded and applied.' \
  '- [no-action] No recall failure occurred; existing rules covered the work.' \
  '- [check] Recall failure, loaded-but-ignored: the older bulleted format.' \
  '- [loaded-but-ignored recall failure] reversed bracket tag.' \
  "- [inferred] The misses were loaded-but-ignored recall failures." \
  '## Lessons (Q1a recall-failure record)' \
  '- [agent-summary] Recall failure (Q1a, loaded-but-ignored): parenthetical.' \
  '- Recall failure (loaded-but-ignored): parenthetical, bare.' \
  '- [inferred] Recall miss this session. Surface class: not-loaded.' \
  'Recall failure, class not-loaded: unbolded line start.' \
  '  **Recall failure, class not-loaded:** indented.' \
  'The template asks for a **Recall failure, class not-loaded:** line.' \
  "$RR_TP_IGNORED"
assert_eq "recall-report: restraint — every false-positive shape at once still counts only the true positive" \
  "$(_rr_expect 20 1 1 1 0 1 0)" "$(_rr_counts "$RR_ALL_FP")"

# === 5. NAMED SKIPS — an unmeasurable window is never a silent zero-count report.
#
# 5a. A directory with no .md files at all.
RR_EMPTY="$RR_TMP/empty"
mkdir -p "$RR_EMPTY"
RR_EMPTY_OUT="$(bash "$RR_SCRIPT" --sessions-dir "$RR_EMPTY" --list 2>&1)"; RR_EMPTY_RC=$?
assert_eq "recall-report: an empty sessions dir exits 0 (a named skip, not an error)" "0" "$RR_EMPTY_RC"
assert_contains "recall-report: an empty sessions dir names the skip" "$RR_EMPTY_OUT" "SKIP no .md files in"
assert_not_contains "recall-report: an empty sessions dir emits NO counts record (never a zero report)" \
  "$RR_EMPTY_OUT" "counts	"

# 5b. .md files present, but NONE carry the meaningful marker.
RR_NOMARK="$RR_TMP/no-marker"
_rr_thin_log "$RR_NOMARK" "2026-01-01-000000-host-aaaaaaaa.md" "$RR_TP_IGNORED"
RR_NOMARK_OUT="$(bash "$RR_SCRIPT" --sessions-dir "$RR_NOMARK" --list 2>&1)"; RR_NOMARK_RC=$?
assert_eq "recall-report: zero MEANINGFUL logs exits 0 (a named skip)" "0" "$RR_NOMARK_RC"
assert_contains "recall-report: zero meaningful logs names the skip" \
  "$RR_NOMARK_OUT" "SKIP no meaningful session logs found"
assert_contains "recall-report: zero meaningful logs says it is indeterminate, not a clean zero" \
  "$RR_NOMARK_OUT" "indeterminate, not a clean zero"
assert_not_contains "recall-report: zero meaningful logs emits NO counts record" \
  "$RR_NOMARK_OUT" "counts	"

# 5c. Sessions dir entirely UNCONFIGURED — no flag, no env var, no local.env.
# --isolated is what suppresses the local.env fallback; without it this test
# would pass or fail depending on whether the operator's checkout has one.
RR_UNCONF_OUT="$(env -u OBSIDIAN_VAULT_PATH bash "$RR_SCRIPT" --isolated --list 2>&1)"; RR_UNCONF_RC=$?
assert_eq "recall-report: an unconfigured sessions dir exits 0 (a named skip)" "0" "$RR_UNCONF_RC"
assert_contains "recall-report: an unconfigured surface names the skip" \
  "$RR_UNCONF_OUT" "SKIP no sessions directory configured"
assert_not_contains "recall-report: an unconfigured surface emits NO counts record" \
  "$RR_UNCONF_OUT" "counts	"

# The human-mode skip is equally loud — a caller reading stdout must not see a
# report-shaped page with zeros in it.
RR_UNCONF_HUMAN="$(env -u OBSIDIAN_VAULT_PATH bash "$RR_SCRIPT" --isolated 2>/dev/null)"
assert_contains "recall-report: the human-mode skip is stated on stdout too" \
  "$RR_UNCONF_HUMAN" "SKIP — no sessions directory configured"
assert_contains "recall-report: the human-mode skip denies being a clean zero" \
  "$RR_UNCONF_HUMAN" "This is an indeterminate result, NOT a clean zero."
assert_not_contains "recall-report: the human-mode skip prints no rate line" \
  "$RR_UNCONF_HUMAN" "rate:"

# === 6. EXIT LAW — 0 for a report or a named skip, 2 for usage and scan errors.
#
# BASELINE FIRST: the same invocation shape with valid arguments exits 0. Without
# it, every exit-2 assertion below could be satisfied by a reporter that is
# simply broken for all inputs.
assert_exit "recall-report: BASELINE — a valid invocation exits 0" 0 -- \
  bash "$RR_SCRIPT" --sessions-dir "$RR_BOTH" --window 5 --list

assert_exit "recall-report: an unknown arg is a usage error (exit 2)" 2 -- \
  bash "$RR_SCRIPT" --sessions-dir "$RR_BOTH" --bogus
assert_exit "recall-report: --window 0 is a usage error (exit 2)" 2 -- \
  bash "$RR_SCRIPT" --sessions-dir "$RR_BOTH" --window 0
assert_exit "recall-report: a non-numeric --window is a usage error (exit 2)" 2 -- \
  bash "$RR_SCRIPT" --sessions-dir "$RR_BOTH" --window twenty
assert_exit "recall-report: a negative --window is a usage error (exit 2)" 2 -- \
  bash "$RR_SCRIPT" --sessions-dir "$RR_BOTH" --window -5
assert_exit "recall-report: --window without a value is a usage error (exit 2)" 2 -- \
  bash "$RR_SCRIPT" --window
assert_exit "recall-report: --sessions-dir without a value is a usage error (exit 2)" 2 -- \
  bash "$RR_SCRIPT" --sessions-dir
assert_exit "recall-report: --help exits 0" 0 -- bash "$RR_SCRIPT" --help

# A CONFIGURED but nonexistent sessions dir is a SCAN ERROR, not a skip: a
# misspelled or unsynced path would otherwise report a clean zero that looks
# exactly like a clean window.
RR_GHOST_OUT="$(bash "$RR_SCRIPT" --sessions-dir "$RR_TMP/no-such-dir" --list 2>&1)"; RR_GHOST_RC=$?
assert_eq "recall-report: a configured-but-nonexistent sessions dir FAILS loud (exit 2)" "2" "$RR_GHOST_RC"
assert_contains "recall-report: the scan error names the broken path" \
  "$RR_GHOST_OUT" "SCAN ERROR — configured sessions directory does not exist: $RR_TMP/no-such-dir"
assert_not_contains "recall-report: a scan error emits NO counts record" "$RR_GHOST_OUT" "counts	"

# A path containing ":<digits>:" is a valid POSIX directory name; the record
# separator search must not anchor on it (panel finding, reproduced live: the
# record came back unclassified with a truncated location before the .md-anchored
# separator fix).
RR_COLON="$RR_TMP/run:12:archive"
_rr_log "$RR_COLON" "2026-01-01-000000-host-aaaaaaaa.md" "$RR_TP_NOT_LOADED"
_rr_log "$RR_COLON" "2026-01-02-000000-host-bbbbbbbb.md" "$RR_TP_IGNORED"
RR_COLON_OUT="$(bash "$RR_SCRIPT" --sessions-dir "$RR_COLON" --list 2>/dev/null)"
assert_contains "recall-report: a ':<digits>:' directory still classifies both records" \
  "$RR_COLON_OUT" "$(_rr_expect 20 2 2 2 1 1 0)"
assert_contains "recall-report: a ':<digits>:' directory keeps the full record location" \
  "$RR_COLON_OUT" "$(printf 'record\tnot-loaded\t%s/2026-01-01-000000-host-aaaaaaaa.md:' "$RR_COLON")"

# An unreadable SELECTED file is the same false-clean shape as a misspelled dir:
# silently skipping it would understate the count with exit 0 (panel finding).
if [ "$(id -u)" -eq 0 ]; then
  _skip "recall-report: an unreadable session log fails loud" "running as root (permission bits are not enforced)"
else
  RR_UNREAD="$RR_TMP/unreadable"
  _rr_log "$RR_UNREAD" "2026-01-01-000000-host-aaaaaaaa.md" "$RR_TP_IGNORED"
  _rr_log "$RR_UNREAD" "2026-01-02-000000-host-bbbbbbbb.md" "$RR_TP_IGNORED"
  chmod 000 "$RR_UNREAD/2026-01-02-000000-host-bbbbbbbb.md"
  RR_UNREAD_OUT="$(bash "$RR_SCRIPT" --sessions-dir "$RR_UNREAD" --list 2>&1)"; RR_UNREAD_RC=$?
  chmod 644 "$RR_UNREAD/2026-01-02-000000-host-bbbbbbbb.md"
  assert_eq "recall-report: an unreadable session log fails loud (exit 2), never an understated count" \
    "2" "$RR_UNREAD_RC"
  assert_contains "recall-report: the unreadable-file scan error is named" \
    "$RR_UNREAD_OUT" "SCAN ERROR — a session log could not be read"
  assert_not_contains "recall-report: an unreadable-file scan emits NO counts record" \
    "$RR_UNREAD_OUT" "counts	"
fi

# === 7. RESOLUTION — $OBSIDIAN_VAULT_PATH supplies <vault>/30-Archive/Sessions.
RR_VAULT="$RR_TMP/vault"
_rr_log "$RR_VAULT/30-Archive/Sessions" "2026-01-01-000000-host-aaaaaaaa.md" "$RR_TP_IGNORED"
RR_ENV_OUT="$(OBSIDIAN_VAULT_PATH="$RR_VAULT" bash "$RR_SCRIPT" --list 2>/dev/null)"
assert_contains "recall-report: \$OBSIDIAN_VAULT_PATH resolves to <vault>/30-Archive/Sessions" \
  "$RR_ENV_OUT" "$(_rr_expect 20 1 1 1 0 1 0)"
# The explicit flag beats the environment.
RR_FLAG_OUT="$(OBSIDIAN_VAULT_PATH="$RR_VAULT" bash "$RR_SCRIPT" --sessions-dir "$RR_BOTH" --list 2>/dev/null)"
assert_contains "recall-report: --sessions-dir overrides \$OBSIDIAN_VAULT_PATH" \
  "$RR_FLAG_OUT" "$(_rr_expect 20 2 2 2 1 1 0)"

# === 8. SELF-AUDIT WIRING — the informational key, and its SCORE NEUTRALITY.
#
# Hermetic: a stub stands in for the reporter via $SELF_AUDIT_RECALL_BIN (the
# same convention $SELF_AUDIT_CURRENTNESS_BIN uses for the semantic checker), so
# what is under test is the WIRING contract, not the extractor. The load-bearing
# assertion is the one nobody would notice breaking: an informational count must
# NEVER move total, a pillar score, or the gap list. A count that could depress
# the score is a count operators would stop producing.
_rr_mk_fixture_repo() { # a minimal, internally consistent repo for self-audit
  local root="$1"
  mkdir -p "$root/capabilities" "$root/verification" \
           "$root/harnesses/claude/capabilities" "$root/harnesses/codex/capabilities"
  cat > "$root/capabilities/example.md" <<'EOF'
---
name: example
summary: example capability for fixture
triggers: [test]
verification: example
harnesses: [claude, codex]
kind: native
lifecycle: shipped
---

# Example
EOF
  printf -- '---\nlifecycle: shipped\n---\n\n## Claude realization — example\n' \
    > "$root/harnesses/claude/capabilities/example.md"
  printf -- '---\nlifecycle: shipped\n---\n\n## Codex realization — example\n' \
    > "$root/harnesses/codex/capabilities/example.md"
  printf '# Example verification recipe\n' > "$root/verification/example.md"
}

# _rr_stub <path> <exit> [stdout lines...] — a fake reporter replaying a chosen
# exit code and --list payload, with a named SKIP reason on stderr.
_rr_stub() {
  local p="$1" rc="$2"; shift 2
  {
    printf '#!/usr/bin/env bash\n'
    local l
    for l in "$@"; do printf 'printf %s\n' "'%s\\n' \"$l\""; done
    printf 'printf %s >&2\n' "'SKIP stub reason\\n'"
    printf 'exit %s\n' "$rc"
  } > "$p"
  chmod +x "$p"
}

_rr_test_selfaudit_wiring() {
  command -v jq >/dev/null 2>&1 || { _skip "recall-report: self-audit wiring" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _rr_mk_fixture_repo "$fixture"
  local stub="$fixture/stub.sh" sa="$REPO_ROOT/scripts/self-audit.sh"

  # BASELINE, taken WITHOUT the reporter wired, so score neutrality is proved by
  # comparison rather than asserted against a hard-coded number.
  local base base_total base_gaps
  base="$(bash "$sa" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  base_total="$(printf '%s' "$base" | jq -r '.total')"
  base_gaps="$(printf '%s' "$base" | jq -r '.gaps | length')"
  assert_eq "recall-report: BASELINE — the isolated fixture audit produces a total" \
    "number" "$(printf '%s' "$base" | jq -r '.total | type')"

  # 1. A reported window — the key appears, carries the counts, and moves nothing.
  local counts out
  counts="$(printf 'counts\t20\t323\t316\t20\t2\t3\t1')"
  _rr_stub "$stub" 0 "$counts" "$(printf 'record\tnot-loaded\tlog.md:12')"
  out="$(SELF_AUDIT_RECALL_BIN="$stub" bash "$sa" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  assert_eq "recall-report: self-audit exposes a recall_failures key" \
    "reported" "$(printf '%s' "$out" | jq -r '.recall_failures.status')"
  assert_eq "recall-report: self-audit carries the not-loaded count" \
    "2" "$(printf '%s' "$out" | jq -r '.recall_failures.not_loaded')"
  assert_eq "recall-report: self-audit carries the loaded-but-ignored count" \
    "3" "$(printf '%s' "$out" | jq -r '.recall_failures.loaded_but_ignored')"
  assert_eq "recall-report: self-audit carries the unclassified count" \
    "1" "$(printf '%s' "$out" | jq -r '.recall_failures.unclassified')"
  assert_eq "recall-report: the counts are numbers, not strings" \
    "number" "$(printf '%s' "$out" | jq -r '.recall_failures.scanned | type')"
  assert_eq "recall-report: the key declares itself unscored" \
    "false" "$(printf '%s' "$out" | jq -r '.recall_failures.scored')"
  assert_eq "recall-report: a record lands in the records array" \
    "not-loaded" "$(printf '%s' "$out" | jq -r '.recall_failures.records[0].class')"
  # The whole point: informational means informational.
  assert_eq "recall-report: counts do NOT change the total score" \
    "$base_total" "$(printf '%s' "$out" | jq -r '.total')"
  assert_eq "recall-report: counts do NOT enter the gap list" \
    "$base_gaps" "$(printf '%s' "$out" | jq -r '.gaps | length')"
  assert_eq "recall-report: counts do NOT change any pillar score" \
    "$(printf '%s' "$base" | jq -c '.pillars')" "$(printf '%s' "$out" | jq -c '.pillars')"

  local md
  md="$(SELF_AUDIT_RECALL_BIN="$stub" bash "$sa" --isolated --repo-root "$fixture" 2>/dev/null)"
  assert_contains "recall-report: the markdown has its own section" "$md" "## Recall failures"
  assert_contains "recall-report: the markdown renders the class counts" "$md" "- loaded-but-ignored: 3"
  assert_contains "recall-report: the markdown states the informational boundary" \
    "$md" "Informational only; never scored"

  # 2. A named SKIP (exit 0, no counts record) — degraded, NAMED, score-neutral.
  _rr_stub "$stub" 0
  out="$(SELF_AUDIT_RECALL_BIN="$stub" bash "$sa" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  assert_eq "recall-report: exit 0 without a counts record degrades to skipped" \
    "skipped" "$(printf '%s' "$out" | jq -r '.recall_failures.status')"
  assert_eq "recall-report: the degraded entry names its reason, never anonymous" \
    "stub reason" "$(printf '%s' "$out" | jq -r '.recall_failures.reason')"
  assert_eq "recall-report: a skipped window reports NULL counts, never zeros" \
    "null" "$(printf '%s' "$out" | jq -r '.recall_failures.loaded_but_ignored')"
  assert_eq "recall-report: a skip preserves the filesystem score" \
    "$base_total" "$(printf '%s' "$out" | jq -r '.total')"

  # 3. A SCAN ERROR (exit 2) — same degraded, named, score-neutral shape.
  _rr_stub "$stub" 2
  out="$(SELF_AUDIT_RECALL_BIN="$stub" bash "$sa" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  assert_eq "recall-report: a reporter scan error degrades to skipped" \
    "skipped" "$(printf '%s' "$out" | jq -r '.recall_failures.status')"
  assert_eq "recall-report: a scan error preserves the filesystem score" \
    "$base_total" "$(printf '%s' "$out" | jq -r '.total')"

  # 3b. A MALFORMED counts record (non-numeric field) is a reporter CONTRACT
  # BREAK — a named skip, never `reported` with null counts (panel finding).
  _rr_stub "$stub" 0 "$(printf 'counts\t20\t323\t316\t20\tx\t3\t1')"
  out="$(SELF_AUDIT_RECALL_BIN="$stub" bash "$sa" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  assert_eq "recall-report: a malformed counts record degrades to skipped, not reported" \
    "skipped" "$(printf '%s' "$out" | jq -r '.recall_failures.status')"
  assert_eq "recall-report: the malformed-counts skip names the contract break" \
    "reporter emitted a malformed counts record" "$(printf '%s' "$out" | jq -r '.recall_failures.reason')"
  assert_eq "recall-report: malformed counts stay null, never partial" \
    "null" "$(printf '%s' "$out" | jq -r '.recall_failures.not_loaded')"
  assert_eq "recall-report: a malformed counts record preserves the filesystem score" \
    "$base_total" "$(printf '%s' "$out" | jq -r '.total')"

  # 4. The key is present even with NO reporter wired at all — an absent section
  # would read as "measured, and there was nothing", which is the opposite claim.
  assert_eq "recall-report: an isolated run with no reporter still names the skip" \
    "isolated run — recall failures not measured" \
    "$(printf '%s' "$base" | jq -r '.recall_failures.reason')"
  assert_contains "recall-report: the markdown section exists even when unmeasured" \
    "$(bash "$sa" --isolated --repo-root "$fixture" 2>/dev/null)" "## Recall failures"

  # 5. PRESENCE vs ABSENCE of the key changes nothing about scoring — the JSON
  # with every other key stripped must be identical either way.
  assert_eq "recall-report: the scorecard minus recall_failures is byte-identical with and without it" \
    "$(printf '%s' "$base" | jq -S 'del(.recall_failures)')" \
    "$(SELF_AUDIT_RECALL_BIN="$stub" bash "$sa" --isolated --repo-root "$fixture" --json 2>/dev/null | jq -S 'del(.recall_failures)')"

  rm -rf "$fixture"
}
_rr_test_selfaudit_wiring

rm -rf "$RR_TMP"
