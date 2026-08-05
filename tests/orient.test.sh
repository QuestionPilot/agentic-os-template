#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/orient.test.sh — unit acceptance for scripts/orient.sh.
#
# The helper collects session-agent Mode 1's kickoff state (project-first Linear
# cut, global-open reconciliation, project anomalies, memory pointers, named
# degraded surfaces) into ONE `orient/v1` JSON document.
#
# Hermetic: --lineark is pointed at a stub serving the JSON fixtures under
# tests/fixtures/orient/ — no live tracker, no token. Both twins read the SAME
# fixture files, so a shape disagreement between them cannot hide behind
# differently-worded inline heredocs.
#
# Three things are pinned, and the second and third matter as much as the first:
#   SHAPE — the emitted document always carries every top-level key with the
#   right TYPE (a structural jq assertion, not a prose match). A caller parses
#   one shape or none; a key that vanishes under a degraded surface is the bug
#   this suite exists to prevent.
#   PAYLOAD SHAPE TOLERANCE — lineark's `issues list` returns `.state` as a BARE
#   STRING while `issues read` returns it as an OBJECT {id,name}. One normalizer
#   must accept both, so nothing ever calls `.state.name` on list output.
#   DEGRADATION — lineark absent, lineark erroring, memory dir absent: each must
#   still emit a valid document on exit 0 with a NAMED `degraded` entry. A
#   helper that dies when a surface is down moves the outage into the caller.
#
# Sourced by tests/run.sh — must not call exit or set -e/-u/pipefail.

ORIENT="$REPO_ROOT/scripts/orient.sh"
ORIENT_FIX="$REPO_ROOT/tests/fixtures/orient"
assert_file "orient.sh present" "$ORIENT"

_orient_have_jq=0
command -v jq >/dev/null 2>&1 && _orient_have_jq=1

# orient_stub <dir> — write the lineark stub into <dir>. It serves, from its own
# directory: projects list -> projects.json; issues list -> issues-global.json;
# issues list --mine -> issues-mine.json; issues list --project P ->
# projissues-P.json; issues read ID -> read-ID.json. A missing file exits 1, so a
# fixture set can make any single cut fail on purpose.
orient_stub() {
  local d="$1"
  cat > "$d/stub" <<'STUB'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
printf 'CALL %s\n' "$*" >> "$d/calls.log"
proj=""; mine=0; prev=""
for a in "$@"; do
  [ "$prev" = "--project" ] && proj="$a"
  [ "$a" = "--mine" ] && mine=1
  prev="$a"
done
if [ "${1:-}" = "projects" ] && [ "${2:-}" = "list" ]; then
  [ -f "$d/projects.json" ] && { cat "$d/projects.json"; exit 0; }
  exit 1
fi
if [ "${1:-}" = "issues" ] && [ "${2:-}" = "list" ]; then
  if [ -n "$proj" ]; then f="$d/projissues-$proj.json"
  elif [ "$mine" = 1 ]; then f="$d/issues-mine.json"
  else f="$d/issues-global.json"; fi
  [ -f "$f" ] && { cat "$f"; exit 0; }
  exit 1
fi
if [ "${1:-}" = "issues" ] && [ "${2:-}" = "read" ]; then
  f="$d/read-${3:-}.json"
  [ -f "$f" ] && { cat "$f"; exit 0; }
  exit 1
fi
exit 1
STUB
  chmod +x "$d/stub"
}

# orient_fixtures <dir> [file…] — copy the named fixture files into the stub dir
# (default: the full nominal set).
orient_fixtures() {
  local d="$1"; shift
  if [ $# -eq 0 ]; then
    set -- projects.json projissues-p-alpha.json projissues-p-beta.json \
           issues-global.json issues-mine.json read-ABC-5.json
  fi
  local f
  for f in "$@"; do cp "$ORIENT_FIX/$f" "$d/"; done
}

run_orient() { # run_orient <stubdir> [extra args…]
  local sd="$1"; shift
  bash "$ORIENT" --lineark "$sd/stub" "$@" 2>/dev/null
}

if [ "$_orient_have_jq" -eq 0 ]; then
  _skip "orient: whole suite" "jq not installed (orient.sh requires it)"
else

# ============================ SHAPE ==========================================
# A STRUCTURAL assertion, not a prose match: every top-level key present with
# the right JSON type. Run on the NOMINAL document here and re-run on every
# degraded document below — the contract is that the shape never varies.
_orient_schema_ok() { # _orient_schema_ok <json> -> echoes ok|BAD
  printf '%s' "$1" | jq -r '
    if (.schema == "orient/v1")
       and (.surfaces | type == "object")
       and (.surfaces.linear.status | type == "string")
       and ((.surfaces.linear.status | IN("ok","absent","error")))
       and (.surfaces.linear.detail | type == "string")
       and ((.surfaces.memory.status | IN("ok","absent","error")))
       and (.surfaces.memory.detail | type == "string")
       and (.projects | type == "array")
       and ([ .projects[] | (.id|type=="string") and (.name|type=="string")
              and (.slug_id|type=="string") and (.open_issues|type=="array")
              and ([ .open_issues[] | (.identifier|type=="string") and (.title|type=="string")
                     and (.state|type=="string") and (.priority|type=="string")
                     and (.assignee|type=="string") and (.url|type=="string") ] | all) ] | all)
       and (.projectless_open_issues | type == "array")
       and (.mine_in_progress | type == "array")
       and (.anomalies | type == "array")
       and ([ .anomalies[] | (.type|type=="string") and (.subject|type=="string") and (.detail|type=="string") ] | all)
       and (.memory_pointers | type == "array")
       and ([ .memory_pointers[] | (.file|type=="string") and (.name|type=="string") and (.description|type=="string") ] | all)
       and (.degraded | type == "array")
       and ([ .degraded[] | type == "string" ] | all)
    then "ok" else "BAD" end' 2>/dev/null || printf 'BAD'
}

# ============================ NOMINAL ========================================
O1="$(mktemp -d)"; orient_stub "$O1"; orient_fixtures "$O1"
o="$(run_orient "$O1" --memory-dir "$ORIENT_FIX/memory")"; rc=$?

assert_eq "orient: nominal run exits 0" 0 "$rc"
assert_eq "orient: nominal document satisfies the orient/v1 schema" "ok" "$(_orient_schema_ok "$o")"

# --- project-first Linear cut -------------------------------------------------
assert_eq "orient: projects are emitted in tracker order with slug ids" \
  "p-alpha:Alpha Arc:alpha-1 p-beta:Beta Arc:beta-2" \
  "$(printf '%s' "$o" | jq -r '[ .projects[] | "\(.id):\(.name):\(.slug_id)" ] | join(" ")')"
assert_eq "orient: per-project open issues carry the bare-string state verbatim" \
  "ABC-1=In Progress ABC-2=Backlog" \
  "$(printf '%s' "$o" | jq -r '[ .projects[0].open_issues[] | "\(.identifier)=\(.state)" ] | join(" ")')"
assert_eq "orient: a null priority normalizes to an empty string, not null" \
  "" "$(printf '%s' "$o" | jq -r '.projects[1].open_issues[1].priority')"

# --- global-open reconciliation ----------------------------------------------
# ABC-9 is in the global sweep and in NO project's list. A projects-only orient
# drops it silently; this is the cut that catches it.
assert_eq "orient: an issue in the global sweep but in no project is projectless" \
  "ABC-9" "$(printf '%s' "$o" | jq -r '[ .projectless_open_issues[].identifier ] | join(" ")')"
assert_eq "orient: issues that DO belong to a project are not projectless" \
  "0" "$(printf '%s' "$o" | jq -r '[ .projectless_open_issues[] | select(.identifier | IN("ABC-1","ABC-2","ABC-3","ABC-4")) ] | length')"

# --- mine + In Progress -------------------------------------------------------
# The --mine fixture also contains ABC-9 (Todo); only the In Progress row counts.
assert_eq "orient: mine_in_progress is assigned AND In Progress, nothing else" \
  "ABC-1" "$(printf '%s' "$o" | jq -r '[ .mine_in_progress[].identifier ] | join(" ")')"

# --- anomalies ----------------------------------------------------------------
assert_eq "orient: a project whose whole open set is unassigned Backlog is an anomaly" \
  "all-issues-backlog-no-assignee:Beta Arc" \
  "$(printf '%s' "$o" | jq -r '[ .anomalies[] | "\(.type):\(.subject)" ] | join(" ")')"
assert_not_contains "orient: a consistent sweep raises no count mismatch" \
  "$o" "open-issue-count-mismatch"

# --- memory pointers ----------------------------------------------------------
# metadata.type AND top-level type both count; reference/feedback notes and the
# untyped MEMORY.md index do not.
assert_eq "orient: project-type memory notes are the only pointers emitted" \
  "project-alpha.md project-beta.md" \
  "$(printf '%s' "$o" | jq -r '[ .memory_pointers[].file ] | join(" ")')"
assert_eq "orient: a memory pointer carries name + description from frontmatter" \
  "project-alpha|Alpha Arc — LIVE, two open issues" \
  "$(printf '%s' "$o" | jq -r '.memory_pointers[0] | "\(.name)|\(.description)"')"
assert_eq "orient: a healthy run names no degraded surface" \
  "0" "$(printf '%s' "$o" | jq -r '.degraded | length')"

# --- output modes -------------------------------------------------------------
assert_eq "orient: default output is ONE compact JSON line" \
  "1" "$(printf '%s\n' "$o" | LC_ALL=C grep -c .)"
o_pretty="$(run_orient "$O1" --memory-dir "$ORIENT_FIX/memory" --pretty)"
assert_eq "orient: --pretty still parses as the same document" \
  "ok" "$(_orient_schema_ok "$o_pretty")"
_orient_pretty_lines="$(printf '%s\n' "$o_pretty" | LC_ALL=C grep -c .)"
if [ "$_orient_pretty_lines" -gt 1 ]; then
  _pass "orient: --pretty indents across multiple lines"
else
  _fail "orient: --pretty indents across multiple lines" "got $_orient_pretty_lines line(s)"
fi

# ============================ PAYLOAD SHAPE TOLERANCE ========================
# `issues list` returns `.state` as a BARE STRING; `issues read` returns it as an
# OBJECT {id,name}. One normalizer must accept both — a `.state.name` on list
# output would emit null, and a `tostring` on read output would emit the whole
# object. Serve the OBJECT-shaped payload through the issue path and require the
# state name back as a plain string.
O2="$(mktemp -d)"; orient_stub "$O2"
orient_fixtures "$O2" projects.json issues-global.json issues-mine.json read-ABC-5.json
cp "$ORIENT_FIX/issues-objstate.json" "$O2/projissues-p-alpha.json"
cp "$ORIENT_FIX/issues-objstate.json" "$O2/projissues-p-beta.json"
o="$(run_orient "$O2")"
assert_eq "orient: an OBJECT-shaped state (the issues-read shape) flattens to its name" \
  "In Progress" "$(printf '%s' "$o" | jq -r '.projects[0].open_issues[0].state')"
assert_eq "orient: object-state payloads still satisfy the schema" "ok" "$(_orient_schema_ok "$o")"

# An object-shaped field with NO `name` (e.g. `assignee: {"id": "usr_123"}`)
# flattens to the EMPTY STRING, never to a stringified object. This is the bash
# CONTROL for the PS-twin regression: the PS port fell through to "$v" and emitted
# the object's own rendering (`@{id=usr_123}`) where jq's `.name // ""` yields "".
O2N="$(mktemp -d)"; orient_stub "$O2N"
orient_fixtures "$O2N" projects.json issues-global.json issues-mine.json
cp "$ORIENT_FIX/issues-nameless-object.json" "$O2N/projissues-p-alpha.json"
cp "$ORIENT_FIX/issues-nameless-object.json" "$O2N/projissues-p-beta.json"
o="$(run_orient "$O2N")"
assert_eq "orient: an object field with no name flattens to the empty string" \
  "" "$(printf '%s' "$o" | jq -r '.projects[0].open_issues[0].assignee')"
assert_not_contains "orient: a nameless object is never stringified into the document" \
  "$o" "id=usr_123"
assert_eq "orient: nameless-object payloads still satisfy the schema" "ok" "$(_orient_schema_ok "$o")"

# ============================ COUNT MISMATCH =================================
# The global sweep sees only ABC-1 while the projects list ABC-1..4 — the two
# cuts disagree about what is open (a truncated sweep, or a scope filter that
# dropped rows). Reported as an anomaly rather than silently reconciled away.
O3="$(mktemp -d)"; orient_stub "$O3"
orient_fixtures "$O3" projects.json projissues-p-alpha.json projissues-p-beta.json issues-mine.json
cp "$ORIENT_FIX/issues-global-short.json" "$O3/issues-global.json"
o="$(run_orient "$O3")"; rc=$?
assert_eq "orient: a disagreeing sweep still exits 0" 0 "$rc"
assert_contains "orient: project issues absent from the global sweep raise open-issue-count-mismatch" \
  "$(printf '%s' "$o" | jq -r '[ .anomalies[] | "\(.type)|\(.detail)" ] | join("\n")')" \
  "open-issue-count-mismatch|3 identifier(s) listed under a project but absent from the global open sweep (global=1, project-union=4): ABC-2, ABC-3, ABC-4"
assert_eq "orient: the short sweep leaves nothing projectless" \
  "0" "$(printf '%s' "$o" | jq -r '.projectless_open_issues | length')"

# ============================ DEGRADATION ====================================

# --- lineark not on PATH ------------------------------------------------------
o="$(bash "$ORIENT" --lineark "$O1/definitely-absent" --memory-dir "$ORIENT_FIX/memory" 2>/dev/null)"; rc=$?
assert_eq "orient: absent lineark still exits 0" 0 "$rc"
assert_eq "orient: absent lineark still emits a schema-valid document" "ok" "$(_orient_schema_ok "$o")"
assert_eq "orient: absent lineark marks the surface absent" \
  "absent" "$(printf '%s' "$o" | jq -r '.surfaces.linear.status')"
assert_contains "orient: absent lineark is NAMED in degraded" \
  "$(printf '%s' "$o" | jq -r '.degraded | join("\n")')" "linear: lineark not on PATH"
assert_eq "orient: absent lineark yields empty Linear arrays, not missing keys" \
  "0 0 0" "$(printf '%s' "$o" | jq -r '[ (.projects|length), (.projectless_open_issues|length), (.mine_in_progress|length) ] | join(" ")')"
assert_eq "orient: the memory surface still reports when Linear is absent" \
  "2" "$(printf '%s' "$o" | jq -r '.memory_pointers | length')"

# --- lineark on PATH but every call fails -------------------------------------
# The stub exits 1 when its fixture file is missing, so an empty stub dir is a
# tracker that answers with failures rather than one that is not installed —
# a DIFFERENT surface status, and the distinction is the operator's next action.
O4="$(mktemp -d)"; orient_stub "$O4"   # no fixtures copied
o="$(run_orient "$O4")"; rc=$?
assert_eq "orient: an erroring lineark still exits 0" 0 "$rc"
assert_eq "orient: an erroring lineark still emits a schema-valid document" "ok" "$(_orient_schema_ok "$o")"
assert_eq "orient: an erroring lineark is 'error', distinct from 'absent'" \
  "error" "$(printf '%s' "$o" | jq -r '.surfaces.linear.status')"
assert_eq "orient: every failed lineark cut is named separately in degraded" \
  "linear: projects list failed|linear: global issues list failed|linear: issues list --mine failed|linear: reconciliation unavailable — incomplete project cut" \
  "$(printf '%s' "$o" | jq -r '[ .degraded[] | select(startswith("linear:")) ] | join("|")')"

# --- one project's issue list fails -------------------------------------------
# The project must still appear (with an empty open set) and the failure must be
# named against that project, not collapsed into a generic tracker outage.
O5="$(mktemp -d)"; orient_stub "$O5"
orient_fixtures "$O5" projects.json projissues-p-alpha.json issues-global.json issues-mine.json
o="$(run_orient "$O5")"
assert_eq "orient: a project whose issue list fails still appears with an empty open set" \
  "Alpha Arc=2 Beta Arc=0" \
  "$(printf '%s' "$o" | jq -r '[ .projects[] | "\(.name)=\(.open_issues|length)" ] | join(" ")')"
assert_contains "orient: the failing project is named in degraded" \
  "$(printf '%s' "$o" | jq -r '.degraded | join("\n")')" "linear: issues list failed for project Beta Arc"
# RECONCILIATION INTEGRITY. The projectless cut is a set difference against the
# project union, and Beta's rows (ABC-3, ABC-4) are missing from that union only
# because Beta's CALL failed. Computing the difference anyway would report two
# correctly-filed issues as projectless AND raise a count-mismatch — both phantoms
# manufactured from the same hole. The reconciliation is reported unavailable.
assert_eq "orient: an incomplete project cut emits NO projectless set, not a partial one" \
  "0" "$(printf '%s' "$o" | jq -r '.projectless_open_issues | length')"
assert_contains "orient: the unavailable reconciliation is NAMED in degraded" \
  "$(printf '%s' "$o" | jq -r '.degraded | join("\n")')" \
  "linear: reconciliation unavailable — incomplete project cut"
assert_not_contains "orient: no phantom count-mismatch from an incomplete project cut" \
  "$o" "open-issue-count-mismatch"
# Neither of the two rows Beta's failed call hid may be named as projectless.
assert_eq "orient: rows hidden by the failed project call are not named projectless" \
  "0" "$(printf '%s' "$o" | jq -r '[ .projectless_open_issues[] | select(.identifier | IN("ABC-3","ABC-4")) ] | length')"
assert_eq "orient: an incomplete project cut still exits 0 with a schema-valid document" \
  "ok" "$(_orient_schema_ok "$o")"
# The cuts that DID succeed are untouched — this suppresses a derived claim, not
# the collected data.
assert_eq "orient: the successful project cut survives the suppressed reconciliation" \
  "2" "$(printf '%s' "$o" | jq -r '.projects[0].open_issues | length')"
assert_eq "orient: mine_in_progress survives the suppressed reconciliation" \
  "ABC-1" "$(printf '%s' "$o" | jq -r '[ .mine_in_progress[].identifier ] | join(" ")')"

# --- memory dir absent / not given --------------------------------------------
o="$(run_orient "$O1" --memory-dir "$O1/no-such-memory-dir")"
assert_eq "orient: an absent memory dir still emits a schema-valid document" "ok" "$(_orient_schema_ok "$o")"
assert_eq "orient: an absent memory dir marks the surface absent with no pointers" \
  "absent 0" "$(printf '%s' "$o" | jq -r '[ .surfaces.memory.status, (.memory_pointers|length|tostring) ] | join(" ")')"
assert_contains "orient: an absent memory dir is NAMED in degraded" \
  "$(printf '%s' "$o" | jq -r '.degraded | join("\n")')" "memory: dir absent"

o="$(run_orient "$O1")"
assert_contains "orient: omitting --memory-dir is a named degraded surface, not a silent skip" \
  "$(printf '%s' "$o" | jq -r '.degraded | join("\n")')" "memory: no --memory-dir given"

# ============================ VALID EMPTY TRACKER ============================
# An empty tracker is a legitimate ANSWER, not a failure: a fresh workspace, a
# project with nothing open, a --mine cut with nothing assigned. `[]` back from
# every cut must read as `ok` with ZERO degraded entries and empty arrays.
# This is the bash CONTROL for the PS-twin regression (the PS port collapsed a
# returned empty array to $null on the way out of its tracker wrapper, so every
# empty cut counted as a call failure and the surface reported `error`).
O6="$(mktemp -d)"; orient_stub "$O6"
orient_fixtures "$O6" projects.json
for _oe in issues-global.json issues-mine.json projissues-p-alpha.json projissues-p-beta.json; do
  cp "$ORIENT_FIX/issues-empty.json" "$O6/$_oe"
done
o="$(run_orient "$O6")"; rc=$?
assert_eq "orient: an all-empty tracker exits 0" 0 "$rc"
assert_eq "orient: an all-empty tracker still emits a schema-valid document" "ok" "$(_orient_schema_ok "$o")"
assert_eq "orient: a valid empty answer is 'ok', never 'error'" \
  "ok" "$(printf '%s' "$o" | jq -r '.surfaces.linear.status')"
assert_eq "orient: an empty cut is NOT a degraded surface" \
  "0" "$(printf '%s' "$o" | jq -r '[ .degraded[] | select(startswith("linear:")) ] | length')"
assert_eq "orient: every issue array is empty, and every project still reports" \
  "2 0 0 0" \
  "$(printf '%s' "$o" | jq -r '[ (.projects|length), ([.projects[].open_issues[]]|length), (.projectless_open_issues|length), (.mine_in_progress|length) ] | join(" ")')"
# Nothing open anywhere is not an anomaly — the empty-project carve-out in the
# backlog anomaly must hold when EVERY project is empty.
assert_eq "orient: an all-empty tracker raises no anomalies" \
  "0" "$(printf '%s' "$o" | jq -r '.anomalies | length')"

# The same with an empty PROJECTS list too — all six array keys empty at once.
O7="$(mktemp -d)"; orient_stub "$O7"
for _oe in projects.json issues-global.json issues-mine.json; do
  cp "$ORIENT_FIX/issues-empty.json" "$O7/$_oe"
done
o="$(run_orient "$O7")"; rc=$?
assert_eq "orient: an empty projects list exits 0" 0 "$rc"
assert_eq "orient: an empty projects list keeps the surface ok with no degraded entries" \
  "ok 0" \
  "$(printf '%s' "$o" | jq -r '[ .surfaces.linear.status, ([ .degraded[] | select(startswith("linear:")) ] | length | tostring) ] | join(" ")')"
assert_eq "orient: every array-typed key is an empty ARRAY, never null" \
  "array array array array array array" \
  "$(printf '%s' "$o" | jq -r '[ (.projects|type), (.projectless_open_issues|type), (.mine_in_progress|type), (.anomalies|type), (.memory_pointers|type), (.degraded|type) ] | join(" ")')"

# ============================ MALFORMED PAYLOAD ==============================
# lk() validates only that the payload is a top-level ARRAY. A well-formed-but-
# wrong body (`["unexpected"]` — a CLI version change, an error envelope, a
# truncated write) therefore reaches the normalizers, where `.identifier` on a
# STRING is a jq hard error. That left the downstream file empty and the slurped
# key null: `"mine_in_progress": null` in a document that still claimed
# orient/v1 and exited 0. Every array key must survive as an ARRAY.
O8="$(mktemp -d)"; orient_stub "$O8"
orient_fixtures "$O8" projects.json projissues-p-alpha.json projissues-p-beta.json issues-mine.json
cp "$ORIENT_FIX/issues-nonobject.json" "$O8/issues-global.json"
o="$(run_orient "$O8" --memory-dir "$ORIENT_FIX/memory")"; rc=$?
assert_eq "orient: a non-object payload element still exits 0" 0 "$rc"
assert_eq "orient: a non-object payload element still emits a schema-valid document" \
  "ok" "$(_orient_schema_ok "$o")"
assert_eq "orient: the document is parseable JSON, not a truncated write" \
  "orient/v1" "$(printf '%s' "$o" | jq -r '.schema')"
assert_eq "orient: every array-typed key survives a malformed payload as an ARRAY" \
  "array array array array array array" \
  "$(printf '%s' "$o" | jq -r '[ (.projects|type), (.projectless_open_issues|type), (.mine_in_progress|type), (.anomalies|type), (.memory_pointers|type), (.degraded|type) ] | join(" ")')"
assert_eq "orient: no top-level key is null after a malformed payload" \
  "0" "$(printf '%s' "$o" | jq -r '[ to_entries[] | select(.value == null) ] | length')"
# The non-object element is DROPPED, not normalized into an empty-string row —
# an all-empty issue row would be indistinguishable from a real issue with
# missing fields.
assert_eq "orient: the non-object element is dropped, not normalized into a blank row" \
  "0" "$(printf '%s' "$o" | jq -r '.projectless_open_issues | length')"
# The surfaces that were fine must still report their real content.
assert_eq "orient: a malformed global sweep does not erase the per-project cut" \
  "2" "$(printf '%s' "$o" | jq -r '.projects | length')"
assert_eq "orient: a malformed global sweep does not erase the memory surface" \
  "2" "$(printf '%s' "$o" | jq -r '.memory_pointers | length')"

# A non-object element in the PROJECTS payload is the same class of defect.
O9="$(mktemp -d)"; orient_stub "$O9"
orient_fixtures "$O9" issues-global.json issues-mine.json
cp "$ORIENT_FIX/issues-nonobject.json" "$O9/projects.json"
o="$(run_orient "$O9")"; rc=$?
assert_eq "orient: a non-object projects element still exits 0" 0 "$rc"
assert_eq "orient: a non-object projects element still emits a schema-valid document" \
  "ok" "$(_orient_schema_ok "$o")"
assert_eq "orient: the non-object project is dropped rather than emitted as a blank project" \
  "0" "$(printf '%s' "$o" | jq -r '.projects | length')"

# ============================ ARGUMENT CONTRACT ==============================
# A non-zero exit means the SCRIPT could not run — never that a surface was down.
o="$(bash "$ORIENT" --nope 2>&1)"; rc=$?
assert_eq "orient: unknown argument exits 2" 2 "$rc"
assert_contains "orient: unknown argument names itself" "$o" "unknown argument: --nope"
o="$(bash "$ORIENT" --memory-dir 2>&1)"; rc=$?
assert_eq "orient: value-less --memory-dir exits 2 (no self-loop)" 2 "$rc"
o="$(bash "$ORIENT" --lineark 2>&1)"; rc=$?
assert_eq "orient: value-less --lineark exits 2 (no self-loop)" 2 "$rc"

rm -rf "$O1" "$O2" "$O2N" "$O3" "$O4" "$O5" "$O6" "$O7" "$O8" "$O9"
fi
