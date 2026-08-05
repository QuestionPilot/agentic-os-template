#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/check-state-currentness.test.sh — unit acceptance for
# scripts/check-state-currentness.sh.
#
# The checker compares tracker-state CLAIMS in memory/vault notes against live
# tracker state, and flags project-status/child contradictions. Advisory, never
# a gate, and it never edits anything.
#
# Hermetic: $LINEARK_BIN is pointed at a stub serving fixture JSON from its own
# directory — no live tracker access, no token.
#
# Two halves, and the second matters as much as the first:
#   DETECTION — the three classes the checker exists to catch (a memory note
#   asserting In Progress for a Done issue; a vault note calling a Done issue
#   open; a Completed project with open children) must actually fire.
#   RESTRAINT — the false positives that sank the first implementation are
#   pinned as regression anchors: prose containing a state word near an
#   identifier ("mixes effective and cancelled actions"), a headline whose state
#   describes the PROJECT before listing issue IDs, a future CONDITION ("exits
#   only after all child issues are Done"), and history-log sections. A checker
#   that cries wolf is worse than no checker; these assertions are why the
#   extractor may never be loosened casually.
#
# Sourced by tests/run.sh — must not call exit or set -e/-u/pipefail.

CSC="$REPO_ROOT/scripts/check-state-currentness.sh"

# csc_stub <dir> — lineark stub. Serves:
#   issues list [--project P]  -> list.json / projissues-P.json
#   issues read ID             -> read-ID.json
#   projects list              -> projects.json
#   projects read ID           -> proj-ID.json
csc_stub() {
  local d="$1"
  cat > "$d/stub" <<'STUB'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
proj=""
prev=""
for a in "$@"; do
  [ "$prev" = "--project" ] && proj="$a"
  prev="$a"
done
if [ "${1:-}" = "issues" ] && [ "${2:-}" = "list" ]; then
  if [ -n "$proj" ]; then
    f="$d/projissues-$proj.json"; [ -f "$f" ] && { cat "$f"; exit 0; }; exit 1
  fi
  cat "$d/list.json"; exit 0
fi
if [ "${1:-}" = "issues" ] && [ "${2:-}" = "read" ]; then
  f="$d/read-${3:-}.json"; [ -f "$f" ] && { cat "$f"; exit 0; }; exit 1
fi
if [ "${1:-}" = "projects" ] && [ "${2:-}" = "list" ]; then
  [ -f "$d/projects.json" ] && { cat "$d/projects.json"; exit 0; }; exit 1
fi
if [ "${1:-}" = "projects" ] && [ "${2:-}" = "read" ]; then
  f="$d/proj-${3:-}.json"; [ -f "$f" ] && { cat "$f"; exit 0; }; exit 1
fi
exit 1
STUB
  chmod +x "$d/stub"
}

# Live state used by every fixture below: ABC-1 Done, ABC-2 Done, ABC-3 In
# Progress, ABC-4 Backlog.
csc_states() {
  cat > "$1/list.json" <<'EOF'
[
  {"identifier": "ABC-1", "state": "Done"},
  {"identifier": "ABC-2", "state": "Done"},
  {"identifier": "ABC-3", "state": "In Progress"},
  {"identifier": "ABC-4", "state": "Backlog"}
]
EOF
}

run_csc() { # run_csc <stubdir> <memdir> [extra args...]
  local sd="$1" md="$2"; shift 2
  LINEARK_BIN="$sd/stub" bash "$CSC" --isolated --prefix ABC --memory-dir "$md" "$@" 2>/dev/null
}

# ============================ DETECTION ======================================

# --- class 1: memory note asserts In Progress for a Done issue ---------------
D1="$(mktemp -d)"; M1="$D1/mem"; mkdir -p "$M1"; csc_stub "$D1"; csc_states "$D1"
cat > "$M1/project-thing.md" <<'EOF'
---
name: project-thing
---

ABC-1 is In Progress and gating the rest of the wave.
EOF
o="$(run_csc "$D1" "$M1" --no-projects)"; rc=$?
assert_eq       "check-state-currentness: stale claim exits 1" 1 "$rc"
assert_contains "check-state-currentness: catches In-Progress claim on a Done issue" \
  "$o" 'WARN stale-claim ABC-1: note says "In Progress", tracker says "Done"'

# --- class 2: a note calls a Done issue open; dated vs undated classification --
D2="$(mktemp -d)"; M2="$D2/mem"; mkdir -p "$M2"; csc_stub "$D2"; csc_states "$D2"
cat > "$M2/notes.md" <<'EOF'
---
name: notes
---

## Open issues as of 2026-08-04 (verified against the tracker)

- ABC-2 — open, blocking the release.

## Current state

ABC-1 remains Backlog.
EOF
o="$(run_csc "$D2" "$M2" --no-projects)"; rc=$?
assert_eq       "check-state-currentness: mixed claims exit 1" 1 "$rc"
assert_contains "check-state-currentness: dated snapshot classified as stale-snapshot" \
  "$o" 'WARN stale-snapshot ABC-2: note says "OPEN", tracker says "Done" (as-of 2026-08-04)'
assert_contains "check-state-currentness: undated assertion classified as stale-claim" \
  "$o" 'WARN stale-claim ABC-1: note says "Backlog", tracker says "Done" (as-of -)'
assert_contains "check-state-currentness: summary separates the two classes" \
  "$o" "1 stale claim(s), 1 stale snapshot(s)"

# --- class 3: project status vs child states ---------------------------------
D3="$(mktemp -d)"; M3="$D3/mem"; mkdir -p "$M3"; csc_stub "$D3"; csc_states "$D3"
cat > "$M3/quiet.md" <<'EOF'
---
name: quiet
---

Nothing asserted here about any identifier.
EOF
cat > "$D3/projects.json" <<'EOF'
[{"id": "p-closed", "name": "Shipped Thing"},
 {"id": "p-idle", "name": "Sleepy Thing"},
 {"id": "p-active", "name": "Busy Thing"}]
EOF
printf '{"id":"p-closed","name":"Shipped Thing","status":{"name":"Completed"}}\n'   > "$D3/proj-p-closed.json"
printf '{"id":"p-idle","name":"Sleepy Thing","status":{"name":"Backlog"}}\n'        > "$D3/proj-p-idle.json"
printf '{"id":"p-active","name":"Busy Thing","status":{"name":"In Progress"}}\n'    > "$D3/proj-p-active.json"
printf '[{"identifier":"ABC-4","state":"Backlog"}]\n'                                > "$D3/projissues-p-closed.json"
printf '[{"identifier":"ABC-3","state":"In Progress"}]\n'                            > "$D3/projissues-p-idle.json"
printf '[]\n'                                                                        > "$D3/projissues-p-active.json"
o="$(run_csc "$D3" "$M3")"; rc=$?
assert_eq       "check-state-currentness: project contradictions exit 1" 1 "$rc"
assert_contains "check-state-currentness: Completed project with open children" \
  "$o" 'WARN project-closed-with-open-children "Shipped Thing": status "Completed" with 1 open child'
assert_contains "check-state-currentness: Backlog project with active children" \
  "$o" 'WARN project-idle-with-active-children "Sleepy Thing": status "Backlog" with 1 open child'
assert_contains "check-state-currentness: In Progress project with no open children" \
  "$o" 'WARN project-active-with-no-open-children "Busy Thing"'

# --- --list machine mode: stable TSV shape -----------------------------------
o="$(run_csc "$D1" "$M1" --no-projects --list)"; rc=$?
assert_eq "check-state-currentness: --list exits 1" 1 "$rc"
assert_contains "check-state-currentness: --list claim record shape" \
  "$o" "$(printf 'claim\tstale-claim\tABC-1\tIn Progress\tDone\t-\t')"
o="$(run_csc "$D3" "$M3" --list)"
assert_contains "check-state-currentness: --list project record shape" \
  "$o" "$(printf 'project\tproject-closed-with-open-children\tShipped Thing\tCompleted\t1\t0')"

# ============================ RESTRAINT ======================================
# Every fixture below WOULD have been flagged by the first implementation.

# --- prose containing a state word near an identifier ------------------------
D4="$(mktemp -d)"; M4="$D4/mem"; mkdir -p "$M4"; csc_stub "$D4"; csc_states "$D4"
cat > "$M4/prose.md" <<'EOF'
---
name: prose
description: "LIVE arc — the workstream is In Progress as of 2026-08-04: parent ABC-1; chain ABC-2 -> ABC-4"
---

The parallel ABC-1 source lane mixes effective and cancelled actions, so it was rejected.
The separately authorized disposable ABC-2 runtime proof then passed on Postgres 16.4.
Phase 2 exits only after all four child issues are Done, and the operator signs off.
Verification gate: ABC-4 exits when the economics memo lands and the review is complete.

ABC-3 is In Progress.
EOF
# The accurate ABC-3 line is load-bearing for this fixture, not decoration: it
# supplies the one comparable claim that makes the run produce a verdict at all.
# Without it the checker (correctly) exits 2 "no comparable evidence" and every
# assert_not_contains below would pass against empty output — a vacuous green.
o="$(run_csc "$D4" "$M4" --no-projects)"; rc=$?
assert_eq           "check-state-currentness: prose yields no findings, only the one true claim (exit 0)" 0 "$rc"
assert_not_contains "check-state-currentness: 'cancelled actions' prose is not a Canceled claim" "$o" "ABC-1"
assert_not_contains "check-state-currentness: project-level state in a headline does not distribute to listed IDs" "$o" "ABC-2"
assert_not_contains "check-state-currentness: a future condition is not a present claim" "$o" "ABC-4"

# --- history-log sections are records, not claims ----------------------------
D5="$(mktemp -d)"; M5="$D5/mem"; mkdir -p "$M5"; csc_stub "$D5"; csc_states "$D5"
cat > "$M5/history.md" <<'EOF'
---
name: history
---

## State Deltas

- 2026-07-01: ABC-1 was In Progress and ABC-2 remained Backlog at the time.

## Audit log

- 2026-07-02: ABC-3 Done, ABC-4 Done.
EOF
o="$(run_csc "$D5" "$M5" --no-projects)"; rc=$?
assert_eq "check-state-currentness: history-only note yields no comparable claims (skip 2)" 2 "$rc"

# --- fenced code is syntax documentation, never a claim ----------------------
D6="$(mktemp -d)"; M6="$D6/mem"; mkdir -p "$M6"; csc_stub "$D6"; csc_states "$D6"
cat > "$M6/fenced.md" <<'EOF'
---
name: fenced
---

Run this to close it:

```bash
tracker issues update ABC-1 --state Done   # ABC-2 is Backlog
```

ABC-3 is In Progress.
EOF
o="$(run_csc "$D6" "$M6" --no-projects)"; rc=$?
assert_eq           "check-state-currentness: fenced code + one true claim → clean (exit 0)" 0 "$rc"
assert_not_contains "check-state-currentness: fenced example is not a claim" "$o" "ABC-1"

# --- correct claims stay silent ----------------------------------------------
D7="$(mktemp -d)"; M7="$D7/mem"; mkdir -p "$M7"; csc_stub "$D7"; csc_states "$D7"
cat > "$M7/accurate.md" <<'EOF'
---
name: accurate
---

- **ABC-1 — Done:** shipped.
- **ABC-3 — In Progress (High):** the active lane.
- ABC-4 remains Backlog.

**Done:** ABC-1, ABC-2.
EOF
o="$(run_csc "$D7" "$M7" --no-projects)"; rc=$?
assert_eq "check-state-currentness: accurate note passes (exit 0)" 0 "$rc"
assert_contains "check-state-currentness: PASS names the compared-claim count" "$o" "PASS"

# --- vault scope: only `status: active` project notes are scanned -------------
# The vault half of the source set. A completed project note is a historical
# record by definition, so its claims must not be read as present-tense
# assertions — the same reason `## State Deltas` sections are skipped.
D9="$(mktemp -d)"; V9="$D9/vault"; mkdir -p "$V9/01-Projects"; csc_stub "$D9"; csc_states "$D9"
cat > "$V9/01-Projects/live.md" <<'EOF'
---
status: active
---

ABC-3 is In Progress.
EOF
cat > "$V9/01-Projects/shipped.md" <<'EOF'
---
status: completed
---

ABC-1 is In Progress.
EOF
o="$(LINEARK_BIN="$D9/stub" bash "$CSC" --isolated --prefix ABC --vault-dir "$V9" --no-projects 2>/dev/null)"; rc=$?
assert_eq           "check-state-currentness: active vault note scanned, completed one skipped (exit 0)" 0 "$rc"
assert_not_contains "check-state-currentness: completed vault project note is not a present claim" "$o" "ABC-1"

# ============================ SKIP CONTRACT ==================================

# --- no lineark on PATH -------------------------------------------------------
o="$(LINEARK_BIN="$D1/definitely-absent" bash "$CSC" --isolated --prefix ABC --memory-dir "$M1" 2>&1)"; rc=$?
assert_eq       "check-state-currentness: absent lineark skips (2)" 2 "$rc"
assert_contains "check-state-currentness: absent lineark names the reason" "$o" "SKIP lineark not found"

# The skip reason must reach STDERR in --list mode too — self-audit reports a
# NAMED skip, and stdout must stay pure TSV so the machine parse is unaffected.
e="$(LINEARK_BIN="$D1/definitely-absent" bash "$CSC" --isolated --prefix ABC --memory-dir "$M1" --list 2>&1 >/dev/null)"
o="$(LINEARK_BIN="$D1/definitely-absent" bash "$CSC" --isolated --prefix ABC --memory-dir "$M1" --list 2>/dev/null)"
assert_contains "check-state-currentness: --list names the skip reason on stderr" "$e" "SKIP lineark not found"
assert_eq       "check-state-currentness: --list keeps stdout empty on skip" "" "$o"

# --- bulk list call fails ------------------------------------------------------
D8="$(mktemp -d)"; M8="$D8/mem"; mkdir -p "$M8"; csc_stub "$D8"   # no list.json written
cp "$M1/project-thing.md" "$M8/"
o="$(LINEARK_BIN="$D8/stub" bash "$CSC" --isolated --prefix ABC --memory-dir "$M8" 2>&1)"; rc=$?
assert_eq "check-state-currentness: failed bulk list skips (2)" 2 "$rc"

# --- no prefix ----------------------------------------------------------------
o="$(LINEARK_BIN="$D1/stub" bash "$CSC" --isolated --memory-dir "$M1" 2>&1)"; rc=$?
assert_eq       "check-state-currentness: missing prefix skips (2)" 2 "$rc"
assert_contains "check-state-currentness: missing prefix names the reason" "$o" "no tracker issue prefix"

# --- no sources ---------------------------------------------------------------
o="$(LINEARK_BIN="$D1/stub" bash "$CSC" --isolated --prefix ABC 2>&1)"; rc=$?
assert_eq "check-state-currentness: no sources skips (2)" 2 "$rc"

# --- bad arguments -------------------------------------------------------------
o="$(bash "$CSC" --nope 2>&1)"; rc=$?
assert_eq "check-state-currentness: unknown argument skips (2)" 2 "$rc"
o="$(bash "$CSC" --max-reads 2>&1)"; rc=$?
assert_eq "check-state-currentness: value-less --max-reads skips (2)" 2 "$rc"
o="$(bash "$CSC" --max-reads abc 2>&1)"; rc=$?
assert_eq "check-state-currentness: non-numeric --max-reads skips (2)" 2 "$rc"

# --- a prefix that could poison the scan pattern is refused -------------------
o="$(LINEARK_BIN="$D1/stub" bash "$CSC" --isolated --prefix 'A.*' --memory-dir "$M1" 2>&1)"; rc=$?
assert_eq "check-state-currentness: non-alphanumeric prefix skips (2)" 2 "$rc"

rm -rf "$D1" "$D2" "$D3" "$D4" "$D5" "$D6" "$D7" "$D8" "$D9"
