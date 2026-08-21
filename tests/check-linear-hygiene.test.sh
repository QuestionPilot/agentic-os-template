#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/check-linear-hygiene.test.sh — unit acceptance for
# scripts/check-linear-hygiene.sh.
#
# check-linear-hygiene sweeps the workspace's OPEN issues against the
# issue-creation standard in linear/issue-template.md and WARNs per gap
# (no-project / no-priority / no-labels / no-assignee / no-acceptance-criteria).
# Advisory, never a gate.
#
# Hermetic: $LINEAR_CLI_BIN is pointed at a stub that serves fixture JSON from
# its own directory — no live Linear access, no token. The stub answers the
# schpet/linear-cli surface: `issue query ... --json` (list) and
# `issue view <IDENT> --json` (per-issue read). Verified here: clean→0,
# gappy→1 with the exact gap list, the deprecated $LINEARK_BIN fallback and
# the LINEAR_CLI_BIN-wins precedence, the realistic {nodes:[...]} payload
# shape plus the bare-array / flat-string fixture tolerance, priorityLabel
# preference with numeric 0 → "No priority", --list machine mode (incl. the
# `unchecked` token — no silent truncation in machine mode), the --max-reads
# cap at 0 and at a partial boundary (list-level checks still run; unchecked
# issues NAMED, never false-flagged for unread fields), the standard's
# deliberately-projectless / deliberately-unassigned escapes, the
# line-anchored AC-heading match (a '###' heading does not count),
# read-failure and non-object-read → unchecked-not-flagged, null /
# identifier-less list entries (skipped + NOTEd, all-malformed → skip 2),
# empty workspace→0, and the fail-SOFT skip contract (exit 2) for no-jq /
# no-linear-CLI / failed-list / non-array / bad-arg.
#
# Sourced by tests/run.sh — must not call exit or set -e/-u/pipefail.

CLH="$REPO_ROOT/scripts/check-linear-hygiene.sh"

# clh_stub <dir> — write an executable linear-CLI stub into <dir>/stub that
# serves <dir>/list.json for `issue query` and <dir>/read-<ID>.json for
# `issue view <ID>`. Matches on the leading subcommand words only; flags
# (--all-teams, -s ..., --limit, --json) are ignored. Anything else exits 1.
clh_stub() {
  local d="$1"
  cat > "$d/stub" <<'STUB'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "query" ]; then cat "$d/list.json"; exit 0; fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  f="$d/read-${3:-}.json"
  [ -f "$f" ] && { cat "$f"; exit 0; }
  exit 1
fi
exit 1
STUB
  chmod +x "$d/stub"
}

# clh_fixture_mixed <dir> — ABC-1 fully conforming, ABC-9 gappy on all five
# checks. Realistic linear-CLI payload: {nodes:[...]} wrapper, state/assignee
# objects, priority as NUMBER + priorityLabel string, labels as
# {nodes:[{name}]}. ABC-9 carries priority 0 with NO priorityLabel to pin the
# numeric 0 → "No priority" fallback.
clh_fixture_mixed() {
  local d="$1"
  clh_stub "$d"
  cat > "$d/list.json" <<'EOF'
{"nodes": [
  {"identifier": "ABC-1", "priority": 2, "priorityLabel": "High",
   "labels": {"nodes": [{"name": "Feature"}]},
   "assignee": {"name": "Owner"}, "state": {"name": "Backlog"}},
  {"identifier": "ABC-9", "priority": 0,
   "labels": {"nodes": []},
   "assignee": null, "state": {"name": "Backlog"}}
]}
EOF
  cat > "$d/read-ABC-1.json" <<'EOF'
{"identifier": "ABC-1", "project": {"id": "p1", "name": "Some Project"},
 "description": "## Outcome\n\nDone state.\n\n## Acceptance criteria\n\n- [ ] observable\n"}
EOF
  cat > "$d/read-ABC-9.json" <<'EOF'
{"identifier": "ABC-9", "project": null, "description": "a prose blob with no structure"}
EOF
}

ALL_GAPS="no-project,no-priority,no-labels,no-assignee,no-acceptance-criteria"

# --- mixed: gappy issue flagged with the exact ordered gap list --------------
D1="$(mktemp -d)"; clh_fixture_mixed "$D1"
o="$(LINEAR_CLI_BIN="$D1/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq           "check-linear-hygiene: mixed exits 1"                1 "$rc"
assert_contains     "check-linear-hygiene: gappy issue WARNs all five gaps" \
  "$o" "WARN ABC-9: $ALL_GAPS"
assert_not_contains "check-linear-hygiene: conforming issue not flagged" "$o" "WARN ABC-1"
assert_contains     "check-linear-hygiene: summary counts 1 of 2"        "$o" "SUMMARY 1 of 2"

# --- binary seam: deprecated $LINEARK_BIN fallback still honored (one
# --- transition release: lineark → schpet/linear-cli) ---------------
o="$(LINEARK_BIN="$D1/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: deprecated LINEARK_BIN fallback exits 1" 1 "$rc"
assert_contains "check-linear-hygiene: deprecated LINEARK_BIN fallback flags gaps" \
  "$o" "WARN ABC-9: $ALL_GAPS"

# --- binary seam precedence: LINEAR_CLI_BIN wins over LINEARK_BIN ------------
o="$(LINEAR_CLI_BIN="$D1/stub" LINEARK_BIN="$D1/does-not-exist" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: LINEAR_CLI_BIN wins over LINEARK_BIN" 1 "$rc"
assert_contains "check-linear-hygiene: precedence run still flags gaps" \
  "$o" "WARN ABC-9: $ALL_GAPS"

# --- mixed --list: machine mode, exactly one tab-separated line --------------
o="$(LINEAR_CLI_BIN="$D1/stub" bash "$CLH" --list 2>/dev/null)"; rc=$?
assert_eq "check-linear-hygiene: --list exits 1"    1 "$rc"
assert_eq "check-linear-hygiene: --list line shape" "$(printf 'ABC-9\t%s' "$ALL_GAPS")" "$o"

# --- mixed --max-reads 0: list-level gaps only; unchecked NAMED in BOTH modes,
# --- project/body NOT false-flagged -------------------------------------------
o="$(LINEAR_CLI_BIN="$D1/stub" bash "$CLH" --max-reads 0 2>/dev/null)"; rc=$?
assert_eq           "check-linear-hygiene: --max-reads 0 still exits 1 (list-level gaps)" 1 "$rc"
assert_contains     "check-linear-hygiene: --max-reads 0 flags list-level gaps only" \
  "$o" "WARN ABC-9: no-priority,no-labels,no-assignee"
assert_not_contains "check-linear-hygiene: --max-reads 0 does not false-flag project" \
  "$o" "no-project"
assert_contains     "check-linear-hygiene: --max-reads 0 names both unchecked issues" \
  "$o" "NOTE 2 open issue(s) not checked"
o="$(LINEAR_CLI_BIN="$D1/stub" bash "$CLH" --max-reads 0 --list 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: --list --max-reads 0 exits 1" 1 "$rc"
assert_contains "check-linear-hygiene: --list emits clean-but-unchecked issue" \
  "$o" "$(printf 'ABC-1\tunchecked')"
assert_contains "check-linear-hygiene: --list appends unchecked to gappy issue tokens" \
  "$o" "$(printf 'ABC-9\tno-priority,no-labels,no-assignee,unchecked')"
rm -rf "$D1"

# --- CRLF-emitting jq: sentinels and counts stay comparison-clean -------------
# A Windows-built jq emits \r\n line endings. The @tsv loop already guards its
# fields (tr -d '\r'); this pins that end-to-end under a CRLF jq wrapper the
# mixed verdict is unchanged, the --list line is byte-identical (no \r reached
# output), and — the count path — an EMPTY workspace still takes the
# [ "$total" -eq 0 ] branch to PASS/exit 0 instead of erroring on "0\r".
DCR="$(mktemp -d)"; clh_fixture_mixed "$DCR"
mk_crlf_jq "$DCR"
o="$(PATH="$DCR:$PATH" LINEAR_CLI_BIN="$DCR/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: CRLF jq — mixed still exits 1" 1 "$rc"
assert_contains "check-linear-hygiene: CRLF jq — all five gaps still fire (no-assignee included)" \
  "$o" "WARN ABC-9: $ALL_GAPS"
o="$(PATH="$DCR:$PATH" LINEAR_CLI_BIN="$DCR/stub" bash "$CLH" --list 2>/dev/null)"
assert_eq "check-linear-hygiene: CRLF jq — --list line is byte-identical (no trailing \\r)" \
  "$(printf 'ABC-9\t%s' "$ALL_GAPS")" "$o"
printf '{"nodes": []}\n' > "$DCR/list.json"
o="$(PATH="$DCR:$PATH" LINEAR_CLI_BIN="$DCR/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: CRLF jq — empty workspace still exits 0" 0 "$rc"
assert_contains "check-linear-hygiene: CRLF jq — empty workspace still prints PASS" \
  "$o" "PASS no open issues"
rm -rf "$DCR"

# --- clean workspace: PASS, exit 0, empty --list. Deliberately keeps the OLD
# --- bare-array + flat-string fixture shape — the script tolerates both, and
# --- this case pins that tolerance ------------------------------------------
D2="$(mktemp -d)"; clh_stub "$D2"
cat > "$D2/list.json" <<'EOF'
[{"identifier": "ABC-1", "priority": "High", "labels": "Feature", "assignee": "Owner", "state": "Backlog"}]
EOF
cat > "$D2/read-ABC-1.json" <<'EOF'
{"identifier": "ABC-1", "project": {"id": "p1", "name": "Some Project"},
 "description": "## Outcome\n\nx\n\n## Acceptance criteria\n\n- [ ] y\n"}
EOF
o="$(LINEAR_CLI_BIN="$D2/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: clean exits 0 (bare-array flat fixture tolerated)" 0 "$rc"
assert_contains "check-linear-hygiene: clean prints PASS"    "$o" "PASS all 1 open issue"
o="$(LINEAR_CLI_BIN="$D2/stub" bash "$CLH" --list 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: clean --list exits 0" 0 "$rc"
assert_eq       "check-linear-hygiene: clean --list is empty" "" "$o"
rm -rf "$D2"

# --- standard's escapes: deliberately projectless + unassigned conform --------
D6="$(mktemp -d)"; clh_stub "$D6"
cat > "$D6/list.json" <<'EOF'
{"nodes": [{"identifier": "ABC-3", "priority": 3, "priorityLabel": "Medium",
 "labels": {"nodes": [{"name": "Improvement"}]}, "assignee": null, "state": {"name": "Backlog"}}]}
EOF
cat > "$D6/read-ABC-3.json" <<'EOF'
{"identifier": "ABC-3", "project": null,
 "description": "## Outcome\n\nx. Deliberately projectless: standalone maintenance sweep. Deliberately unassigned: next free agent picks it up.\n\n## Acceptance criteria\n\n- [ ] y\n"}
EOF
o="$(LINEAR_CLI_BIN="$D6/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq           "check-linear-hygiene: documented escapes exit 0"    0 "$rc"
assert_not_contains "check-linear-hygiene: stated projectless not flagged" "$o" "no-project"
assert_not_contains "check-linear-hygiene: stated unassigned not flagged"  "$o" "no-assignee"
rm -rf "$D6"

# --- AC heading is line-anchored H2: '###' or prose mention does NOT count ----
D7="$(mktemp -d)"; clh_stub "$D7"
cat > "$D7/list.json" <<'EOF'
{"nodes": [{"identifier": "ABC-7", "priority": 2, "priorityLabel": "High",
 "labels": {"nodes": [{"name": "Bug"}]}, "assignee": {"name": "Owner"}, "state": {"name": "Backlog"}}]}
EOF
cat > "$D7/read-ABC-7.json" <<'EOF'
{"identifier": "ABC-7", "project": {"id": "p1", "name": "Some Project"},
 "description": "### Acceptance criteria\n\n- x\n\nprose saying ## acceptance criteria inline does not count\n"}
EOF
o="$(LINEAR_CLI_BIN="$D7/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: H3/prose AC mention exits 1"      1 "$rc"
assert_contains "check-linear-hygiene: H3/prose AC mention is flagged"   "$o" "WARN ABC-7: no-acceptance-criteria"
rm -rf "$D7"

# --- partial read cap (--max-reads 1): first read, second NAMED unchecked -----
D8="$(mktemp -d)"; clh_stub "$D8"
cat > "$D8/list.json" <<'EOF'
{"nodes": [
  {"identifier": "ABC-1", "priority": 2, "priorityLabel": "High",
   "labels": {"nodes": [{"name": "Feature"}]}, "assignee": {"name": "Owner"}, "state": {"name": "Backlog"}},
  {"identifier": "ABC-5", "priority": 4, "priorityLabel": "Low",
   "labels": {"nodes": [{"name": "Improvement"}]}, "assignee": {"name": "Owner"}, "state": {"name": "Backlog"}}
]}
EOF
cat > "$D8/read-ABC-1.json" <<'EOF'
{"identifier": "ABC-1", "project": {"id": "p1", "name": "Some Project"},
 "description": "## Acceptance criteria\n\n- [ ] y\n"}
EOF
o="$(LINEAR_CLI_BIN="$D8/stub" bash "$CLH" --max-reads 1 2>/dev/null)"; rc=$?
assert_eq           "check-linear-hygiene: partial cap exits 0"          0 "$rc"
assert_contains     "check-linear-hygiene: partial cap names the capped issue" "$o" "ABC-5"
assert_contains     "check-linear-hygiene: partial cap NOTE counts 1"    "$o" "NOTE 1 open issue(s) not checked"
assert_not_contains "check-linear-hygiene: partial cap does not flag the read issue" "$o" "WARN ABC-1"
rm -rf "$D8"

# --- read failure: list-level clean, read fixture missing → unchecked, exit 0 -
D3="$(mktemp -d)"; clh_stub "$D3"
cat > "$D3/list.json" <<'EOF'
{"nodes": [{"identifier": "ABC-2", "priority": 3, "priorityLabel": "Medium",
 "labels": {"nodes": [{"name": "Improvement"}]}, "assignee": {"name": "Owner"}, "state": {"name": "Backlog"}}]}
EOF
o="$(LINEAR_CLI_BIN="$D3/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: read-failure exits 0 (unknown is not a gap)" 0 "$rc"
assert_contains "check-linear-hygiene: read-failure names the unchecked issue" "$o" "ABC-2"
assert_contains "check-linear-hygiene: read-failure PASS is qualified" "$o" "1 unchecked for project/body"
# non-object read payload → same unchecked path, and --list carries the token
cat > "$D3/read-ABC-2.json" <<'EOF'
[1, 2]
EOF
o="$(LINEAR_CLI_BIN="$D3/stub" bash "$CLH" --list 2>/dev/null)"; rc=$?
assert_eq "check-linear-hygiene: non-object read exits 0 (unchecked, not a gap)" 0 "$rc"
assert_eq "check-linear-hygiene: --list names non-object-read issue unchecked" \
  "$(printf 'ABC-2\tunchecked')" "$o"
rm -rf "$D3"

# --- null / identifier-less list entries: skipped + NOTEd; all-malformed → 2 --
D9="$(mktemp -d)"; clh_stub "$D9"
cat > "$D9/list.json" <<'EOF'
{"nodes": [null, {"identifier": "ABC-1", "priority": 2, "priorityLabel": "High",
 "labels": {"nodes": [{"name": "Feature"}]}, "assignee": {"name": "Owner"}, "state": {"name": "Backlog"}}]}
EOF
cat > "$D9/read-ABC-1.json" <<'EOF'
{"identifier": "ABC-1", "project": {"id": "p1", "name": "Some Project"},
 "description": "## Acceptance criteria\n\n- [ ] y\n"}
EOF
o="$(LINEAR_CLI_BIN="$D9/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: null list entry exits 0"          0 "$rc"
assert_contains "check-linear-hygiene: null list entry NOTEd as malformed" "$o" "NOTE 1 list entr"
cat > "$D9/list.json" <<'EOF'
{"nodes": [{}, null]}
EOF
o="$(LINEAR_CLI_BIN="$D9/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq "check-linear-hygiene: all-malformed payload exits 2 (skip, not false PASS)" 2 "$rc"
rm -rf "$D9"

# --- empty workspace ----------------------------------------------------------
D4="$(mktemp -d)"; clh_stub "$D4"
printf '{"nodes": []}\n' > "$D4/list.json"
o="$(LINEAR_CLI_BIN="$D4/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: empty workspace exits 0" 0 "$rc"
assert_contains "check-linear-hygiene: empty workspace prints PASS" "$o" "PASS no open issues"
rm -rf "$D4"

# --- skip contract: fail-SOFT exit 2, never a crash or false verdict ----------
D5="$(mktemp -d)"
# jq unavailable (empty PATH dir; LINEAR_CLI_BIN is absolute so only jq lookup
# fails). Invoke via "$BASH" — an assignment-prefixed PATH also governs the
# COMMAND lookup itself, so a bare `bash` would resolve to nothing (rc 127).
clh_stub "$D5"; printf '{"nodes": []}\n' > "$D5/list.json"
PATH="$D5/emptypath" LINEAR_CLI_BIN="$D5/stub" "${BASH:-bash}" "$CLH" >/dev/null 2>&1; rc=$?
assert_eq "check-linear-hygiene: missing jq exits 2 (skip)" 2 "$rc"
LINEAR_CLI_BIN="$D5/does-not-exist" bash "$CLH" >/dev/null 2>&1; rc=$?
assert_eq "check-linear-hygiene: missing linear CLI exits 2 (skip)" 2 "$rc"
cat > "$D5/broken" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$D5/broken"
LINEAR_CLI_BIN="$D5/broken" bash "$CLH" >/dev/null 2>&1; rc=$?
assert_eq "check-linear-hygiene: failed query call exits 2 (skip)" 2 "$rc"
cat > "$D5/notjson" <<'EOF'
#!/usr/bin/env bash
printf 'plain text, not json\n'
EOF
chmod +x "$D5/notjson"
LINEAR_CLI_BIN="$D5/notjson" bash "$CLH" >/dev/null 2>&1; rc=$?
assert_eq "check-linear-hygiene: no-rows-array payload exits 2 (skip)" 2 "$rc"
bash "$CLH" --bogus >/dev/null 2>&1; rc=$?
assert_eq "check-linear-hygiene: unknown argument exits 2" 2 "$rc"
bash "$CLH" --max-reads >/dev/null 2>&1; rc=$?
assert_eq "check-linear-hygiene: value-less --max-reads exits 2" 2 "$rc"
bash "$CLH" --max-reads abc >/dev/null 2>&1; rc=$?
assert_eq "check-linear-hygiene: non-numeric --max-reads exits 2" 2 "$rc"
bash "$CLH" --max-reads -1 >/dev/null 2>&1; rc=$?
assert_eq "check-linear-hygiene: negative --max-reads exits 2" 2 "$rc"
rm -rf "$D5"
