#!/usr/bin/env bash
# tests/check-linear-hygiene.test.sh — unit acceptance for
# scripts/check-linear-hygiene.sh.
#
# check-linear-hygiene sweeps the workspace's OPEN issues against the
# issue-creation standard in linear/issue-template.md and WARNs per gap
# (no-project / no-priority / no-labels / no-assignee / no-acceptance-criteria).
# Advisory, never a gate.
#
# Hermetic: $LINEARK_BIN is pointed at a stub that serves fixture JSON from
# its own directory — no live Linear access, no token. Verified here: clean→0,
# gappy→1 with the exact gap list, --list machine mode, the --max-reads cap
# (list-level checks still run; unchecked issues NAMED, project/body NOT
# false-flagged), read-failure→unchecked-not-flagged, empty workspace→0, and
# the fail-SOFT skip contract (exit 2) for no-lineark / failed-list / bad-arg.
#
# Sourced by tests/run.sh — must not call exit or set -e/-u/pipefail.

CLH="$REPO_ROOT/scripts/check-linear-hygiene.sh"

# clh_stub <dir> — write an executable lineark stub into <dir>/stub that serves
# <dir>/list.json for `issues list` and <dir>/read-<ID>.json for `issues read`.
clh_stub() {
  local d="$1"
  cat > "$d/stub" <<'STUB'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "issues" ] && [ "${2:-}" = "list" ]; then cat "$d/list.json"; exit 0; fi
if [ "${1:-}" = "issues" ] && [ "${2:-}" = "read" ]; then
  f="$d/read-${3:-}.json"
  [ -f "$f" ] && { cat "$f"; exit 0; }
  exit 1
fi
exit 1
STUB
  chmod +x "$d/stub"
}

# clh_fixture_mixed <dir> — ABC-1 fully conforming, ABC-9 gappy on all five checks.
clh_fixture_mixed() {
  local d="$1"
  clh_stub "$d"
  cat > "$d/list.json" <<'EOF'
[
  {"identifier": "ABC-1", "priority": "High", "labels": "Feature", "assignee": "Owner", "state": "Backlog"},
  {"identifier": "ABC-9", "priority": "No priority", "labels": "", "assignee": "", "state": "Backlog"}
]
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
o="$(LINEARK_BIN="$D1/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq           "check-linear-hygiene: mixed exits 1"                1 "$rc"
assert_contains     "check-linear-hygiene: gappy issue WARNs all five gaps" \
  "$o" "WARN ABC-9: $ALL_GAPS"
assert_not_contains "check-linear-hygiene: conforming issue not flagged" "$o" "WARN ABC-1"
assert_contains     "check-linear-hygiene: summary counts 1 of 2"        "$o" "SUMMARY 1 of 2"

# --- mixed --list: machine mode, exactly one tab-separated line --------------
o="$(LINEARK_BIN="$D1/stub" bash "$CLH" --list 2>/dev/null)"; rc=$?
assert_eq "check-linear-hygiene: --list exits 1"    1 "$rc"
assert_eq "check-linear-hygiene: --list line shape" "$(printf 'ABC-9\t%s' "$ALL_GAPS")" "$o"

# --- mixed --max-reads 0: list-level gaps only; unchecked NAMED, project/body
# --- NOT false-flagged ---------------------------------------------------------
o="$(LINEARK_BIN="$D1/stub" bash "$CLH" --max-reads 0 2>/dev/null)"; rc=$?
assert_eq           "check-linear-hygiene: --max-reads 0 still exits 1 (list-level gaps)" 1 "$rc"
assert_contains     "check-linear-hygiene: --max-reads 0 flags list-level gaps only" \
  "$o" "WARN ABC-9: no-priority,no-labels,no-assignee"
assert_not_contains "check-linear-hygiene: --max-reads 0 does not false-flag project" \
  "$o" "no-project"
assert_contains     "check-linear-hygiene: --max-reads 0 names both unchecked issues" \
  "$o" "NOTE 2 open issue(s) not checked"
rm -rf "$D1"

# --- clean workspace: PASS, exit 0, empty --list ------------------------------
D2="$(mktemp -d)"; clh_stub "$D2"
cat > "$D2/list.json" <<'EOF'
[{"identifier": "ABC-1", "priority": "High", "labels": "Feature", "assignee": "Owner", "state": "Backlog"}]
EOF
cat > "$D2/read-ABC-1.json" <<'EOF'
{"identifier": "ABC-1", "project": {"id": "p1", "name": "Some Project"},
 "description": "## Outcome\n\nx\n\n## Acceptance criteria\n\n- [ ] y\n"}
EOF
o="$(LINEARK_BIN="$D2/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: clean exits 0"        0 "$rc"
assert_contains "check-linear-hygiene: clean prints PASS"    "$o" "PASS all 1 open issue"
o="$(LINEARK_BIN="$D2/stub" bash "$CLH" --list 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: clean --list exits 0" 0 "$rc"
assert_eq       "check-linear-hygiene: clean --list is empty" "" "$o"
rm -rf "$D2"

# --- read failure: list-level clean, read fixture missing → unchecked, exit 0 -
D3="$(mktemp -d)"; clh_stub "$D3"
cat > "$D3/list.json" <<'EOF'
[{"identifier": "ABC-2", "priority": "Medium", "labels": "Improvement", "assignee": "Owner", "state": "Backlog"}]
EOF
o="$(LINEARK_BIN="$D3/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: read-failure exits 0 (unknown is not a gap)" 0 "$rc"
assert_contains "check-linear-hygiene: read-failure names the unchecked issue" "$o" "ABC-2"
assert_contains "check-linear-hygiene: read-failure PASS is qualified" "$o" "1 unchecked for project/body"
rm -rf "$D3"

# --- empty workspace ----------------------------------------------------------
D4="$(mktemp -d)"; clh_stub "$D4"
printf '[]\n' > "$D4/list.json"
o="$(LINEARK_BIN="$D4/stub" bash "$CLH" 2>/dev/null)"; rc=$?
assert_eq       "check-linear-hygiene: empty workspace exits 0" 0 "$rc"
assert_contains "check-linear-hygiene: empty workspace prints PASS" "$o" "PASS no open issues"
rm -rf "$D4"

# --- skip contract: fail-SOFT exit 2, never a crash or false verdict ----------
D5="$(mktemp -d)"
LINEARK_BIN="$D5/does-not-exist" bash "$CLH" >/dev/null 2>&1; rc=$?
assert_eq "check-linear-hygiene: missing lineark exits 2 (skip)" 2 "$rc"
cat > "$D5/broken" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$D5/broken"
LINEARK_BIN="$D5/broken" bash "$CLH" >/dev/null 2>&1; rc=$?
assert_eq "check-linear-hygiene: failed list call exits 2 (skip)" 2 "$rc"
cat > "$D5/notjson" <<'EOF'
#!/usr/bin/env bash
printf 'plain text, not json\n'
EOF
chmod +x "$D5/notjson"
LINEARK_BIN="$D5/notjson" bash "$CLH" >/dev/null 2>&1; rc=$?
assert_eq "check-linear-hygiene: non-array payload exits 2 (skip)" 2 "$rc"
bash "$CLH" --bogus >/dev/null 2>&1; rc=$?
assert_eq "check-linear-hygiene: unknown argument exits 2" 2 "$rc"
bash "$CLH" --max-reads >/dev/null 2>&1; rc=$?
assert_eq "check-linear-hygiene: value-less --max-reads exits 2" 2 "$rc"
bash "$CLH" --max-reads abc >/dev/null 2>&1; rc=$?
assert_eq "check-linear-hygiene: non-numeric --max-reads exits 2" 2 "$rc"
rm -rf "$D5"
