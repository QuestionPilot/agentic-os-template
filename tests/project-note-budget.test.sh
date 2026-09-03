#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/project-note-budget.test.sh — behavioral tests for
# scripts/check-project-note-budget.sh, the fourth check in the closeout
# pre-write gate.
#
# The check fails CLOSED on a `type: project` memory note whose file size exceeds
# the per-note budget. Three properties carry the weight, and each is pinned both
# ways (a positive that fires AND a negative that must not):
#
#   TYPE-GATED     only frontmatter `type: project` is in scope — an equally
#                  oversize reference note, and a `node_type:` near-miss, must
#                  pass. Without the negatives this degrades into a blanket
#                  note-size cap.
#   SURFACE        no --memory-dir at all is a named SKIP (exit 0); a given dir
#                  that does not exist is a FAILURE. Scanning nothing while
#                  reporting clean is the fail-open case.
#   DENOMINATOR    every run says how many notes it measured, so a PASS over an
#                  empty store is distinguishable from a PASS over a full one.
#
# Sourced by tests/run.sh; do NOT set -e or call exit.

PNB_SCRIPT="$REPO_ROOT/scripts/check-project-note-budget.sh"
assert_file "pnb: scripts/check-project-note-budget.sh exists" "$PNB_SCRIPT"
# The header documents direct execution, so the file must carry the executable
# bit — a 644 script turns the documented invocation into "permission denied".
if [ -x "$PNB_SCRIPT" ]; then
  _pass "pnb: the check is executable (its documented usage is direct invocation)"
else
  _fail "pnb: the check is executable (its documented usage is direct invocation)" \
    "not executable: $PNB_SCRIPT"
fi

PNB_TMP="$(mktemp -d)"
# Isolate the budget knob for the WHOLE file, mirroring the PS twin: the check
# reads PROJECT_NOTE_BODY_WARN_KB from repo-root local.env (as data) and from
# the ambient env, so a run inside an operator clone whose local.env pins a
# non-default budget would flip every "16 KB" verdict below. Pin
# AI_CONFIG_LOCAL_ENV at a path that does not exist (the no-key shape) and
# clear the ambient knob; the precedence sections re-set both explicitly per
# invocation. Restored at the bottom so later test files see the caller's env.
PNB_SAVED_LENV="${AI_CONFIG_LOCAL_ENV-__unset__}"
PNB_SAVED_CAP="${PROJECT_NOTE_BODY_WARN_KB-__unset__}"
export AI_CONFIG_LOCAL_ENV="$PNB_TMP/no-such-local.env"
unset PROJECT_NOTE_BODY_WARN_KB

# _pnb_note <path> <type-line> <pad-bytes> — a memory note with the given
# frontmatter type line, padded to roughly <pad-bytes>.
_pnb_note() {
  { printf -- '---\nmetadata:\n'
    printf '  %s\n' "$2"
    printf -- '---\n'
    head -c "$3" /dev/zero | tr '\0' 'x'
    printf '\n'; } > "$1"
}

# _pnb_raw_note <path> <frontmatter-printf-fmt> <pad-bytes> — a note whose WHOLE
# frontmatter block (fences included) is given verbatim, for the nesting cases
# _pnb_note's fixed `metadata:` shape cannot express.
_pnb_raw_note() {
  { printf -- "$2"
    head -c "$3" /dev/zero | tr '\0' 'x'
    printf '\n'; } > "$1"
}

# _pnb_exact_note <path> <total-bytes> — a `type: project` note whose FILE SIZE
# is exactly <total-bytes>, frontmatter included. The budget compares file size,
# so an off-by-a-few fixture cannot test a boundary at all.
_pnb_exact_note() {
  local f="$1" total="$2" hdr pad
  printf -- '---\nmetadata:\n  type: project\n---\n' > "$f"
  hdr="$(wc -c < "$f" | tr -d ' ')"
  pad=$(( total - hdr ))
  [ "$pad" -gt 0 ] && head -c "$pad" /dev/zero | tr '\0' 'x' >> "$f"
  return 0
}

# === 1. No --memory-dir at all → a NAMED skip with the denominator, exit 0.
PNB_NONE_OUT="$(bash "$PNB_SCRIPT" 2>&1)"; PNB_NONE_RC=$?
assert_eq "pnb: no --memory-dir exits 0 (inapplicable surface, not a failure)" "0" "$PNB_NONE_RC"
assert_contains "pnb: the absent surface is a NAMED skip" \
  "$PNB_NONE_OUT" "SKIP no --memory-dir given"
assert_contains "pnb: the skip still prints its denominator" \
  "$PNB_NONE_OUT" "scanned 0 project note(s) in 0 dir(s)"

# === 2. A store whose project notes are all within budget → PASS with the count.
PNB_OK="$PNB_TMP/store-ok"
mkdir -p "$PNB_OK"
_pnb_note "$PNB_OK/arc-one.md" 'type: project' 512
_pnb_note "$PNB_OK/arc-two.md" 'type: project' 1024
printf -- '- [Arc one](arc-one.md)\n' > "$PNB_OK/MEMORY.md"
PNB_OK_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_OK" 2>&1)"; PNB_OK_RC=$?
assert_eq "pnb: a within-budget store exits 0" "0" "$PNB_OK_RC"
assert_contains "pnb: the clean verdict names the budget" \
  "$PNB_OK_OUT" "PASS every project-type note is within the 16 KB budget"
assert_contains "pnb: the denominator counts the project notes it measured" \
  "$PNB_OK_OUT" "scanned 2 project note(s) in 1 dir(s) against a 16 KB budget"

# === 3. An over-budget project note fails closed, naming the file and the size.
PNB_BIG="$PNB_TMP/store-over"
mkdir -p "$PNB_BIG"
_pnb_note "$PNB_BIG/oversize.md" 'type: project' 17408
PNB_BIG_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_BIG" 2>&1)"; PNB_BIG_RC=$?
assert_eq "pnb: an over-budget project note exits 1 (fail closed)" "1" "$PNB_BIG_RC"
assert_contains "pnb: the offending note is named by full path" \
  "$PNB_BIG_OUT" "FAIL project note over budget: $PNB_BIG/oversize.md"
assert_contains "pnb: the finding states the measured size against the cap" \
  "$PNB_BIG_OUT" "B > 16 KB)"
assert_contains "pnb: the finding points at the remediation rule" \
  "$PNB_BIG_OUT" "trim per capabilities/closeout.md memory-hygiene rule 4"
assert_contains "pnb: the verdict separates over-budget notes from missing dirs" \
  "$PNB_BIG_OUT" "FAIL 1 note(s) over the 16 KB budget, 0 memory dir(s) unusable, 0 note(s) unreadable"

# === 3b. The EXACT boundary. The comparison is `size > cap`, so a note of
# exactly 16*1024 bytes is within budget and one byte more is not. An off-by-one
# here would either nag every note that merely reaches the cap or wave through
# the first note that breaches it, and no order-of-magnitude fixture can tell.
PNB_EDGE="$PNB_TMP/store-edge"
mkdir -p "$PNB_EDGE/at" "$PNB_EDGE/over"
_pnb_exact_note "$PNB_EDGE/at/exactly-16k.md" 16384
_pnb_exact_note "$PNB_EDGE/over/one-byte-over.md" 16385
# The fixtures must really be those sizes — a mis-built fixture would make both
# assertions below vacuous.
assert_eq "pnb: the at-cap fixture is exactly 16384 bytes" "16384" \
  "$(wc -c < "$PNB_EDGE/at/exactly-16k.md" | tr -d ' ')"
assert_eq "pnb: the over-cap fixture is exactly 16385 bytes" "16385" \
  "$(wc -c < "$PNB_EDGE/over/one-byte-over.md" | tr -d ' ')"
PNB_AT_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_EDGE/at" 2>&1)"; PNB_AT_RC=$?
assert_eq "pnb: a note of exactly 16*1024 bytes is WITHIN budget" "0" "$PNB_AT_RC"
assert_contains "pnb: the at-cap note was really measured (denominator is 1)" \
  "$PNB_AT_OUT" "scanned 1 project note(s) in 1 dir(s)"
PNB_OVER1_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_EDGE/over" 2>&1)"; PNB_OVER1_RC=$?
assert_eq "pnb: one byte over the cap FAILS" "1" "$PNB_OVER1_RC"
assert_contains "pnb: the one-byte-over finding reports the exact size" \
  "$PNB_OVER1_OUT" "(16385 B > 16 KB)"

# === 4. TYPE-GATED, both negatives. An equally oversize `type: reference` note is
# out of scope, and `node_type: project` is a near-miss the detector must NOT
# claim — the anchored `type:` match is what keeps this from becoming a blanket
# note-size cap.
PNB_TYPE="$PNB_TMP/store-types"
mkdir -p "$PNB_TYPE"
_pnb_note "$PNB_TYPE/big-reference.md" 'type: reference' 17408
_pnb_note "$PNB_TYPE/big-nodetype.md"  'node_type: project' 17408
PNB_TYPE_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_TYPE" 2>&1)"; PNB_TYPE_RC=$?
assert_eq "pnb: oversize non-project notes pass (type-gated)" "0" "$PNB_TYPE_RC"
assert_contains "pnb: neither near-miss note is counted in the denominator" \
  "$PNB_TYPE_OUT" "scanned 0 project note(s) in 1 dir(s)"
assert_not_contains "pnb: an oversize reference note is never reported" \
  "$PNB_TYPE_OUT" "big-reference.md"
assert_not_contains "pnb: a node_type: near-miss is never reported" \
  "$PNB_TYPE_OUT" "big-nodetype.md"

# === 4b. WHICH `type:` wins — the nesting rule. A frontmatter block can carry
# several `type:` keys under different parents, so "the first `type:` at any
# indent" reads the wrong one: a note whose `source:` provenance block names
# `type: project` above its real `metadata: type: reference` was classified
# project. Negatives first, each oversize so a mis-classification cannot hide.
PNB_NEST_NO="$PNB_TMP/store-nesting-negative"
mkdir -p "$PNB_NEST_NO"
_pnb_raw_note "$PNB_NEST_NO/source-nested.md" \
  '---\nsource:\n  type: project\nmetadata:\n  type: reference\n---\n' 17408
_pnb_raw_note "$PNB_NEST_NO/source-only.md" \
  '---\nsource:\n  type: project\n---\n' 17408
_pnb_raw_note "$PNB_NEST_NO/capital-type.md" \
  '---\nmetadata:\n  Type: project\n---\n' 17408
_pnb_raw_note "$PNB_NEST_NO/body-mention.md" \
  '---\nmetadata:\n  type: reference\n---\ntype: project\n' 17408
# An UNCLOSED opening fence is not frontmatter at all — the whole file is body,
# so a body line `type: project` must not classify it. Without the closed-block
# guard the walker fell off the end of the file still holding the body's value.
_pnb_raw_note "$PNB_NEST_NO/unclosed.md" \
  '---\ntitle: an arc\ntype: project\n' 17408
# A `type:` DEEPER than metadata's own first indent level belongs to a sub-key,
# not to the note. Here `metadata: source: type: project` sits under `source:`
# while the note's real direct child says reference.
_pnb_raw_note "$PNB_NEST_NO/deep-nested.md" \
  '---\nmetadata:\n  source:\n    type: project\n  type: reference\n---\n' 17408
# Same sub-key `type:`, but with NO direct child at all — the note simply has no
# type, and must not inherit its provenance block's.
_pnb_raw_note "$PNB_NEST_NO/deep-only.md" \
  '---\nmetadata:\n  source:\n    type: project\n---\n' 17408
PNB_NEST_NO_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_NEST_NO" 2>&1)"; PNB_NEST_NO_RC=$?
assert_eq "pnb: none of the seven near-miss shapes classify as project" "0" "$PNB_NEST_NO_RC"
assert_contains "pnb: the near-miss store measures ZERO project notes" \
  "$PNB_NEST_NO_OUT" "scanned 0 project note(s) in 1 dir(s)"
for _pnb_miss in source-nested.md source-only.md capital-type.md body-mention.md \
                 unclosed.md deep-nested.md deep-only.md; do
  assert_not_contains "pnb: '$_pnb_miss' is never reported" "$PNB_NEST_NO_OUT" "$_pnb_miss"
done

# The POSITIVES, so the negatives above cannot pass by the detector simply
# having stopped working: `metadata.type` wins, and a TOP-LEVEL `type:` counts
# when there is no metadata block at all.
PNB_NEST_YES="$PNB_TMP/store-nesting-positive"
mkdir -p "$PNB_NEST_YES"
_pnb_raw_note "$PNB_NEST_YES/metadata-type.md" \
  '---\nsource:\n  type: reference\nmetadata:\n  type: project\n---\n' 17408
_pnb_raw_note "$PNB_NEST_YES/toplevel-type.md" \
  '---\ntype: project\ntitle: an arc\n---\n' 17408
# The non-vacuity control for the direct-child rule: metadata carries BOTH a
# sub-key `type:` and a direct one. A fix that simply ignored everything under
# `metadata:` would satisfy every negative above and still fail here.
_pnb_raw_note "$PNB_NEST_YES/deep-plus-direct.md" \
  '---\nmetadata:\n  source:\n    type: reference\n  type: project\n---\n' 17408
PNB_NEST_YES_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_NEST_YES" 2>&1)"; PNB_NEST_YES_RC=$?
assert_eq "pnb: metadata.type and a top-level type: both classify as project" "1" "$PNB_NEST_YES_RC"
assert_contains "pnb: all three positive shapes are measured" \
  "$PNB_NEST_YES_OUT" "scanned 3 project note(s) in 1 dir(s)"
assert_contains "pnb: metadata.type wins over a source-nested type" \
  "$PNB_NEST_YES_OUT" "$PNB_NEST_YES/metadata-type.md"
assert_contains "pnb: a top-level type: with no metadata block counts" \
  "$PNB_NEST_YES_OUT" "$PNB_NEST_YES/toplevel-type.md"
assert_contains "pnb: a DIRECT metadata child still counts beside a deeper sub-key type" \
  "$PNB_NEST_YES_OUT" "$PNB_NEST_YES/deep-plus-direct.md"

# === 5. A QUOTED type value still classifies as a project note — the store
# writes `type: "project"` as often as the bare form, and a detector that misses
# the quoted spelling silently exempts half the notes it exists to measure.
PNB_QUOTED="$PNB_TMP/store-quoted"
mkdir -p "$PNB_QUOTED"
_pnb_note "$PNB_QUOTED/quoted.md" 'type: "project"' 17408
PNB_QUOTED_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_QUOTED" 2>&1)"; PNB_QUOTED_RC=$?
assert_eq "pnb: a quoted type: \"project\" note is in scope" "1" "$PNB_QUOTED_RC"
assert_contains "pnb: the quoted-type note is the reported offender" \
  "$PNB_QUOTED_OUT" "$PNB_QUOTED/quoted.md"

# === 5b. An INLINE YAML COMMENT on the type value. `type: project # active arc`
# is ordinary YAML and ordinary operator practice, and the old value extractor
# handed back `project # active arc` — so the note the comment describes as an
# active arc was the one note the budget never measured. Quoted and bare
# spellings both, plus the negative that a `#` with no space before it (or one
# inside the quotes) is part of the value, not a comment.
PNB_CMT="$PNB_TMP/store-comments"
mkdir -p "$PNB_CMT"
_pnb_raw_note "$PNB_CMT/bare-comment.md" \
  '---\nmetadata:\n  type: project # active arc\n---\n' 17408
_pnb_raw_note "$PNB_CMT/quoted-comment.md" \
  '---\nmetadata:\n  type: "project"   # active arc\n---\n' 17408
_pnb_raw_note "$PNB_CMT/toplevel-comment.md" \
  '---\ntype: project  # top-level, commented\n---\n' 17408
PNB_CMT_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_CMT" 2>&1)"; PNB_CMT_RC=$?
assert_eq "pnb: a commented type value still classifies as project" "1" "$PNB_CMT_RC"
assert_contains "pnb: all three commented spellings are measured" \
  "$PNB_CMT_OUT" "scanned 3 project note(s) in 1 dir(s)"

# The negatives: a `#` that is NOT a comment must stay in the value, so these
# notes are NOT project notes. Without them the fix could be "strip everything
# from the first #", which silently rewrites legitimate values.
PNB_CMT_NEG="$PNB_TMP/store-comments-negative"
mkdir -p "$PNB_CMT_NEG"
_pnb_raw_note "$PNB_CMT_NEG/hash-in-quotes.md" \
  '---\nmetadata:\n  type: "project #1"\n---\n' 17408
_pnb_raw_note "$PNB_CMT_NEG/hash-no-space.md" \
  '---\nmetadata:\n  type: project#1\n---\n' 17408
_pnb_raw_note "$PNB_CMT_NEG/reference-comment.md" \
  '---\nmetadata:\n  type: reference # still an arc\n---\n' 17408
PNB_CMT_NEG_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_CMT_NEG" 2>&1)"; PNB_CMT_NEG_RC=$?
assert_eq "pnb: a non-comment '#' stays in the value (none of these are project)" \
  "0" "$PNB_CMT_NEG_RC"
assert_contains "pnb: the non-comment store measures ZERO project notes" \
  "$PNB_CMT_NEG_OUT" "scanned 0 project note(s) in 1 dir(s)"

# === 6. MEMORY.md is the INDEX, never a note — excluded even when it carries
# project frontmatter and is oversize (its own cap is the self-audit's, not this
# one's).
PNB_IDX="$PNB_TMP/store-index"
mkdir -p "$PNB_IDX"
_pnb_note "$PNB_IDX/MEMORY.md" 'type: project' 17408
PNB_IDX_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_IDX" 2>&1)"; PNB_IDX_RC=$?
assert_eq "pnb: an oversize MEMORY.md is not a project note" "0" "$PNB_IDX_RC"
assert_contains "pnb: MEMORY.md is excluded from the denominator" \
  "$PNB_IDX_OUT" "scanned 0 project note(s) in 1 dir(s)"

# === 7. A given memory dir that does not exist is a FAILURE, not a skip.
PNB_GHOST_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_TMP/no-such-store" 2>&1)"; PNB_GHOST_RC=$?
assert_eq "pnb: a nonexistent --memory-dir exits 1 (configured but broken)" "1" "$PNB_GHOST_RC"
assert_contains "pnb: the missing store is named" \
  "$PNB_GHOST_OUT" "FAIL memory dir not found: $PNB_TMP/no-such-store"
assert_not_contains "pnb: a missing given store is never reported as a skip" \
  "$PNB_GHOST_OUT" "SKIP"

# === 7b. A store that EXISTS but cannot be ENUMERATED must FAIL. `find` on an
# unsearchable directory yields nothing and exits quietly, so the run reported
# `scanned 0` and PASSed over a store it never opened — a clean verdict from a
# measurement that never happened, which is the exact fail-open shape this check
# exists to close. Same for a note that cannot be read: it classifies as "no
# type" and would drop out silently, indistinguishable from a reference note.
# Root can read a 000 directory, so both cases are skipped rather than
# false-failed when the revoke does not take.
PNB_PERM="$PNB_TMP/store-perm"
mkdir -p "$PNB_PERM"
_pnb_note "$PNB_PERM/arc.md" 'type: project' 512
chmod 000 "$PNB_PERM/arc.md" 2>/dev/null
if [ -r "$PNB_PERM/arc.md" ]; then
  _skip "pnb: an unreadable NOTE fails the scan" "cannot revoke read (running as root?)"
  _skip "pnb: the unreadable note is named" "cannot revoke read (running as root?)"
else
  PNB_PERMNOTE_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_PERM" 2>&1)"; PNB_PERMNOTE_RC=$?
  assert_eq "pnb: an unreadable NOTE fails the scan" "1" "$PNB_PERMNOTE_RC"
  assert_contains "pnb: the unreadable note is named" \
    "$PNB_PERMNOTE_OUT" "FAIL memory note not readable: $PNB_PERM/arc.md"
fi
chmod 644 "$PNB_PERM/arc.md" 2>/dev/null

chmod 000 "$PNB_PERM" 2>/dev/null
if [ -r "$PNB_PERM" ] && [ -x "$PNB_PERM" ]; then
  chmod 755 "$PNB_PERM" 2>/dev/null
  _skip "pnb: an unreadable STORE fails the scan" "cannot revoke read (running as root?)"
  _skip "pnb: the unreadable store is named" "cannot revoke read (running as root?)"
  _skip "pnb: an unreadable store never reports a clean PASS" "cannot revoke read (running as root?)"
else
  PNB_PERMDIR_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_PERM" 2>&1)"; PNB_PERMDIR_RC=$?
  chmod 755 "$PNB_PERM" 2>/dev/null
  assert_eq "pnb: an unreadable STORE fails the scan" "1" "$PNB_PERMDIR_RC"
  assert_contains "pnb: the unreadable store is named" \
    "$PNB_PERMDIR_OUT" "FAIL memory dir not readable: $PNB_PERM"
  assert_not_contains "pnb: an unreadable store never reports a clean PASS" \
    "$PNB_PERMDIR_OUT" "PASS every project-type note"
fi

# === 7c. The scan is DEPTH-1 by contract: a memory store is a flat directory of
# notes, and its subdirectories (attachments, archives, a nested store with its
# own index) are not this store's notes. Pinned because `find -maxdepth 1` is one
# character away from recursing into an operator's whole archive tree.
PNB_DEPTH="$PNB_TMP/store-depth"
mkdir -p "$PNB_DEPTH/archive"
_pnb_note "$PNB_DEPTH/arc.md" 'type: project' 512
_pnb_note "$PNB_DEPTH/archive/retired-arc.md" 'type: project' 17408
PNB_DEPTH_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_DEPTH" 2>&1)"; PNB_DEPTH_RC=$?
assert_eq "pnb: an over-budget note in a SUBDIRECTORY does not fail the scan" "0" "$PNB_DEPTH_RC"
assert_contains "pnb: the subdirectory note is not counted in the denominator" \
  "$PNB_DEPTH_OUT" "scanned 1 project note(s) in 1 dir(s)"
assert_not_contains "pnb: the subdirectory note is never reported" \
  "$PNB_DEPTH_OUT" "retired-arc.md"

# === 8. --memory-dir is REPEATABLE: one verdict over every store, each finding
# attributed to the store it fired in, and the denominator counting both dirs.
PNB_MULTI_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_OK" --memory-dir "$PNB_BIG" 2>&1)"; PNB_MULTI_RC=$?
assert_eq "pnb: a repeated --memory-dir with one bad store exits 1" "1" "$PNB_MULTI_RC"
assert_contains "pnb: the denominator counts both stores" \
  "$PNB_MULTI_OUT" "scanned 3 project note(s) in 2 dir(s)"
assert_contains "pnb: the finding is attributed to its own store" \
  "$PNB_MULTI_OUT" "$PNB_BIG/oversize.md"

# === 9. --warn-kb raises the cap and the SAME store then passes — proving the
# knob is really consulted, not decoration.
PNB_KB_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_BIG" --warn-kb 20 2>&1)"; PNB_KB_RC=$?
assert_eq "pnb: --warn-kb 20 passes the store that fails at 16" "0" "$PNB_KB_RC"
assert_contains "pnb: the raised cap is echoed in the denominator" \
  "$PNB_KB_OUT" "against a 20 KB budget"

# === 10. local.env supplies the cap, read as DATA — never sourced. The fixture
# carries a command substitution that would create a sentinel file if the file
# were executed. BOTH halves matter: the sentinel must NOT appear (never
# sourced), and the cap MUST take effect (the file really was read) — without the
# second half the first would pass just as happily against a parser that ignores
# local.env entirely.
PNB_LENV="$PNB_TMP/local-env-cap.env"
PNB_SENTINEL="$PNB_TMP/sourced-sentinel"
printf 'EVIL=$(touch "%s")\nPROJECT_NOTE_BODY_WARN_KB="20"\n' "$PNB_SENTINEL" > "$PNB_LENV"
PNB_LENV_OUT="$(AI_CONFIG_LOCAL_ENV="$PNB_LENV" bash "$PNB_SCRIPT" --memory-dir "$PNB_BIG" 2>&1)"; PNB_LENV_RC=$?
assert_eq "pnb: the local.env cap takes effect (the file really was read)" "0" "$PNB_LENV_RC"
assert_contains "pnb: the local.env cap is echoed in the denominator" \
  "$PNB_LENV_OUT" "against a 20 KB budget"
if [ -e "$PNB_SENTINEL" ]; then
  _fail "pnb: local.env is read as DATA, never sourced" "sentinel created: $PNB_SENTINEL"
else
  _pass "pnb: local.env is read as DATA, never sourced"
fi

# === 11. Cap PRECEDENCE: flag > local.env > ambient env > default. The local.env
# fixture sets 20 and the ambient var sets 1, so an inversion flips the verdict —
# neither assertion can pass vacuously.
PNB_PREC1_OUT="$(AI_CONFIG_LOCAL_ENV="$PNB_LENV" PROJECT_NOTE_BODY_WARN_KB=1 \
  bash "$PNB_SCRIPT" --memory-dir "$PNB_BIG" 2>&1)"
assert_contains "pnb: local.env beats the ambient env var" "$PNB_PREC1_OUT" "against a 20 KB budget"
PNB_PREC2_OUT="$(AI_CONFIG_LOCAL_ENV="$PNB_LENV" bash "$PNB_SCRIPT" \
  --memory-dir "$PNB_BIG" --warn-kb 32 2>&1)"
assert_contains "pnb: --warn-kb beats local.env" "$PNB_PREC2_OUT" "against a 32 KB budget"
PNB_PREC3_OUT="$(AI_CONFIG_LOCAL_ENV="$PNB_TMP/no-such-local.env" PROJECT_NOTE_BODY_WARN_KB=20 \
  bash "$PNB_SCRIPT" --memory-dir "$PNB_BIG" 2>&1)"
assert_contains "pnb: the ambient env var is used when local.env has no key" \
  "$PNB_PREC3_OUT" "against a 20 KB budget"

# === 12. An UNUSABLE cap degrades to the default SILENTLY. The digit bound is
# load-bearing: `KB * 1024` is 64-bit signed arithmetic, so a huge value wraps
# the product to 0 and every note on disk lands "over budget" — a knob typed to
# RAISE the threshold silently driving it to zero.
for _pnb_bad in 0 abc -5 18014398509481984; do
  _pnb_bad_out="$(PROJECT_NOTE_BODY_WARN_KB="$_pnb_bad" AI_CONFIG_LOCAL_ENV="$PNB_TMP/no-such-local.env" \
    bash "$PNB_SCRIPT" --memory-dir "$PNB_OK" 2>&1)"
  assert_contains "pnb: an unusable cap '$_pnb_bad' falls back to the 16 KB default" \
    "$_pnb_bad_out" "against a 16 KB budget"
done

# === 12b. LEADING-ZERO cap values. bash reads a leading-zero literal as OCTAL:
# `08` was an arithmetic ERROR that aborted the run before the denominator ever
# printed, and `0000016` silently meant 14 — while the PS twin's [int] parse read
# both as decimal, so the two shells disagreed on the same operator input. Both
# now normalize to base 10 and echo the NORMALIZED value. The whole output is
# compared against the plain-decimal spelling, so a normalization that fixed only
# the denominator line would still fail here.
PNB_Z08_OUT="$(AI_CONFIG_LOCAL_ENV="$PNB_TMP/no-such-local.env" \
  bash "$PNB_SCRIPT" --memory-dir "$PNB_OK" --warn-kb 08 2>&1)"; PNB_Z08_RC=$?
PNB_D8_OUT="$(AI_CONFIG_LOCAL_ENV="$PNB_TMP/no-such-local.env" \
  bash "$PNB_SCRIPT" --memory-dir "$PNB_OK" --warn-kb 8 2>&1)"
assert_eq "pnb: --warn-kb 08 completes (no octal arithmetic abort)" "0" "$PNB_Z08_RC"
assert_contains "pnb: --warn-kb 08 echoes the NORMALIZED cap" "$PNB_Z08_OUT" "against a 8 KB budget"
assert_eq "pnb: --warn-kb 08 and --warn-kb 8 produce identical output" "$PNB_D8_OUT" "$PNB_Z08_OUT"
PNB_Z16_OUT="$(AI_CONFIG_LOCAL_ENV="$PNB_TMP/no-such-local.env" \
  bash "$PNB_SCRIPT" --memory-dir "$PNB_OK" --warn-kb 0000016 2>&1)"; PNB_Z16_RC=$?
PNB_D16_OUT="$(AI_CONFIG_LOCAL_ENV="$PNB_TMP/no-such-local.env" \
  bash "$PNB_SCRIPT" --memory-dir "$PNB_OK" --warn-kb 16 2>&1)"
assert_eq "pnb: --warn-kb 0000016 completes" "0" "$PNB_Z16_RC"
assert_contains "pnb: --warn-kb 0000016 is decimal 16, not octal 14" "$PNB_Z16_OUT" "against a 16 KB budget"
assert_eq "pnb: --warn-kb 0000016 and --warn-kb 16 produce identical output" "$PNB_D16_OUT" "$PNB_Z16_OUT"

# === 13. A store path containing a SPACE is handled intact (this framework's own
# home carries one).
PNB_SPACED="$PNB_TMP/store with space"
mkdir -p "$PNB_SPACED"
_pnb_note "$PNB_SPACED/oversize.md" 'type: project' 17408
PNB_SPACED_OUT="$(bash "$PNB_SCRIPT" --memory-dir "$PNB_SPACED" 2>&1)"; PNB_SPACED_RC=$?
assert_eq "pnb: a spaced store path exits 1" "1" "$PNB_SPACED_RC"
assert_contains "pnb: the spaced path is reported intact" \
  "$PNB_SPACED_OUT" "$PNB_SPACED/oversize.md"

# === 14. Usage errors exit 2 (distinct from a finding, so a caller can tell "the
# check said no" from "you invoked it wrong").
assert_exit "pnb: an unknown arg is a usage error" 2 -- bash "$PNB_SCRIPT" --bogus
assert_exit "pnb: --memory-dir without a value is a usage error" 2 -- bash "$PNB_SCRIPT" --memory-dir
# An EXPLICIT empty value is a usage error too, never a silent fallback to the
# named SKIP: `--memory-dir "$SOME_UNSET_VAR"` must fail loudly, not report a
# clean run over nothing.
PNB_EMPTY_OUT="$(bash "$PNB_SCRIPT" --memory-dir "" 2>&1)"; PNB_EMPTY_RC=$?
assert_eq "pnb: an explicitly EMPTY --memory-dir is a usage error" "2" "$PNB_EMPTY_RC"
assert_contains "pnb: the empty --memory-dir message names the requirement" \
  "$PNB_EMPTY_OUT" "FAIL --memory-dir requires a non-empty value"
assert_not_contains "pnb: an empty --memory-dir never degrades to the named SKIP" \
  "$PNB_EMPTY_OUT" "SKIP"
assert_exit "pnb: --warn-kb without a value is a usage error" 2 -- bash "$PNB_SCRIPT" --warn-kb
assert_exit "pnb: --help exits 0" 0 -- bash "$PNB_SCRIPT" --help

# === 15. Wiring, so a future refactor that drops the check is caught here: the
# gate's check set names this script, and the capability body carries the rule
# the finding points operators at.
PNB_GATE_BODY="$(cat "$REPO_ROOT/scripts/closeout-gate.sh")"
assert_contains "pnb: closeout-gate.sh runs check-project-note-budget.sh in its check set" \
  "$PNB_GATE_BODY" "check-project-note-budget.sh"
PNB_CLOSEOUT_BODY="$(cat "$REPO_ROOT/capabilities/closeout.md")"
assert_contains "pnb: closeout.md carries the project-note budget memory-hygiene rule" \
  "$PNB_CLOSEOUT_BODY" "**Project-note budget.**"
assert_contains "pnb: closeout.md names the knob the check reads" \
  "$PNB_CLOSEOUT_BODY" "PROJECT_NOTE_BODY_WARN_KB"

rm -rf "$PNB_TMP"
# Restore the caller's knob state (mirror of the PS twin's finally block).
if [ "$PNB_SAVED_LENV" = "__unset__" ]; then unset AI_CONFIG_LOCAL_ENV; else export AI_CONFIG_LOCAL_ENV="$PNB_SAVED_LENV"; fi
if [ "$PNB_SAVED_CAP" = "__unset__" ]; then unset PROJECT_NOTE_BODY_WARN_KB; else export PROJECT_NOTE_BODY_WARN_KB="$PNB_SAVED_CAP"; fi
unset PNB_SAVED_LENV PNB_SAVED_CAP
unset PNB_SCRIPT PNB_TMP PNB_OK PNB_BIG PNB_TYPE PNB_QUOTED PNB_IDX PNB_SPACED \
      PNB_LENV PNB_SENTINEL PNB_EDGE PNB_NEST_NO PNB_NEST_YES PNB_EMPTY_OUT PNB_EMPTY_RC \
      PNB_CMT PNB_CMT_NEG PNB_PERM PNB_DEPTH _pnb_bad _pnb_bad_out _pnb_miss
unset -f _pnb_note _pnb_raw_note _pnb_exact_note
