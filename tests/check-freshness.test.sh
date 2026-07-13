#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/check-freshness.test.sh — unit acceptance for scripts/check-freshness.sh.
#
# check-freshness diffs the build manifest's recorded SOURCE hashes against the
# current repo and reports whether the install is built from STALE sources (a
# fixed hook/capability merged to main but install.sh never re-run). It is the
# freshness counterpart to check-drift's tamper detection.
#
# Verified here: fresh→0, changed→1, removed→1, multi-stale count, the --list
# machine mode, and the fail-SOFT skip contract (exit 2, never a crash or a
# false "fresh") for no-manifest / no-sources-map / no-jq / bad-arg.
#
# Sourced by tests/run.sh — must not call exit or set -e/-u/pipefail.

CF="$REPO_ROOT/scripts/check-freshness.sh"

# Local sha256 (mirror the script's tool resolution) so fixtures record the real
# hash of each source file.
if command -v sha256sum >/dev/null 2>&1; then _cf_sha() { sha256sum "$1" | cut -d' ' -f1; }
else _cf_sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

# cf_fixture <dir> — build <dir>/install/.build-manifest.json recording the
# CURRENT hashes of <dir>/repo/a.txt + <dir>/repo/sub/b.txt (i.e. a FRESH state).
cf_fixture() {
  local d="$1"
  mkdir -p "$d/install" "$d/repo/sub"
  printf 'alpha\n' > "$d/repo/a.txt"
  printf 'beta\n'  > "$d/repo/sub/b.txt"
  local ha hb
  ha="$(_cf_sha "$d/repo/a.txt")"
  hb="$(_cf_sha "$d/repo/sub/b.txt")"
  printf '{"harness":"claude","sources":{"a.txt":"%s","sub/b.txt":"%s"}}\n' "$ha" "$hb" \
    > "$d/install/.build-manifest.json"
}

# --- fresh -----------------------------------------------------------------
D1="$(mktemp -d)"; cf_fixture "$D1"
o="$(bash "$CF" --manifest "$D1/install" --repo "$D1/repo" 2>/dev/null)"; rc=$?
assert_eq       "check-freshness: fresh exits 0"            0 "$rc"
assert_contains "check-freshness: fresh prints PASS"        "$o" "PASS install is current"
o="$(bash "$CF" --manifest "$D1/install" --repo "$D1/repo" --list 2>/dev/null)"; rc=$?
assert_eq       "check-freshness: fresh --list exits 0"     0 "$rc"
assert_eq       "check-freshness: fresh --list is empty"    "" "$o"
rm -rf "$D1"

# --- changed source --------------------------------------------------------
D2="$(mktemp -d)"; cf_fixture "$D2"
printf 'CHANGED\n' > "$D2/repo/a.txt"
o="$(bash "$CF" --manifest "$D2/install" --repo "$D2/repo" 2>/dev/null)"; rc=$?
assert_eq       "check-freshness: changed exits 1"          1 "$rc"
assert_contains "check-freshness: changed prints STALE n/total" "$o" "STALE 1 of 2"
assert_contains "check-freshness: changed names the file"   "$o" "a.txt"
o="$(bash "$CF" --manifest "$D2/install" --repo "$D2/repo" --list 2>/dev/null)"; rc=$?
assert_eq       "check-freshness: changed --list exits 1"   1 "$rc"
assert_eq       "check-freshness: changed --list prints just the path" "a.txt" "$o"
rm -rf "$D2"

# --- removed source (manifest references a now-deleted file) ----------------
D3="$(mktemp -d)"; cf_fixture "$D3"
rm "$D3/repo/sub/b.txt"
o="$(bash "$CF" --manifest "$D3/install" --repo "$D3/repo" --list 2>/dev/null)"; rc=$?
assert_eq       "check-freshness: removed source exits 1"   1 "$rc"
assert_eq       "check-freshness: removed source listed"    "sub/b.txt" "$o"
rm -rf "$D3"

# --- both stale → count = 2 ------------------------------------------------
D4="$(mktemp -d)"; cf_fixture "$D4"
printf 'x\n' > "$D4/repo/a.txt"; printf 'y\n' > "$D4/repo/sub/b.txt"
o="$(bash "$CF" --manifest "$D4/install" --repo "$D4/repo" 2>/dev/null)"
assert_contains "check-freshness: both-stale count is 2 of 2" "$o" "STALE 2 of 2"
n="$(bash "$CF" --manifest "$D4/install" --repo "$D4/repo" --list 2>/dev/null | grep -c .)"
assert_eq       "check-freshness: both-stale --list has 2 lines" 2 "$n"
rm -rf "$D4"

# --- skip: no manifest (fail-soft, exit 2) ---------------------------------
D5="$(mktemp -d)"; cf_fixture "$D5"
o="$(bash "$CF" --manifest "$D5/nope" --repo "$D5/repo" 2>/dev/null)"; rc=$?
assert_eq       "check-freshness: missing manifest exits 2 (skip)" 2 "$rc"
o="$(bash "$CF" --manifest "$D5/nope" --repo "$D5/repo" --list 2>/dev/null)"; rc=$?
assert_eq       "check-freshness: missing manifest --list exits 2" 2 "$rc"
assert_eq       "check-freshness: missing manifest --list silent on stdout" "" "$o"
rm -rf "$D5"

# --- skip: manifest with no sources map (exit 2) ---------------------------
D6="$(mktemp -d)"; cf_fixture "$D6"
printf '{"harness":"claude"}\n' > "$D6/install/.build-manifest.json"
o="$(bash "$CF" --manifest "$D6/install" --repo "$D6/repo" 2>/dev/null)"; rc=$?
assert_eq       "check-freshness: no sources map exits 2 (skip)" 2 "$rc"
rm -rf "$D6"

# --- skip: jq absent (fail-soft, never a crash / false report) -------------
D7="$(mktemp -d)"; cf_fixture "$D7"
NOJQ="$(mktemp -d)"
for _b in bash cat grep sed cut printf env dirname shasum sha256sum; do
  _p="$(command -v "$_b" 2>/dev/null)" && ln -s "$_p" "$NOJQ/$_b"
done
o="$(PATH="$NOJQ" bash "$CF" --manifest "$D7/install" --repo "$D7/repo" 2>/dev/null)"; rc=$?
assert_eq       "check-freshness: no jq exits 2 (fail-soft skip)" 2 "$rc"
rm -rf "$D7" "$NOJQ"

# --- bad arg → exit 2 ------------------------------------------------------
o="$(bash "$CF" --bogus 2>/dev/null)"; rc=$?
assert_eq       "check-freshness: unknown argument exits 2" 2 "$rc"

# --- missing flag value → exit 2, must NOT spin (Codex adversarial #1) ------
# A value-less --manifest / --repo previously re-looped forever (bash leaves $#
# unchanged when `shift 2` exceeds $#, and there is no set -e). These run the
# real script; if the guard regresses they HANG the (sourced) suite — which is
# itself the loudest possible signal.
o="$(bash "$CF" --manifest 2>/dev/null)"; rc=$?
assert_eq       "check-freshness: value-less --manifest exits 2 (no spin)" 2 "$rc"
o="$(bash "$CF" --repo 2>/dev/null)"; rc=$?
assert_eq       "check-freshness: value-less --repo exits 2 (no spin)" 2 "$rc"
o="$(bash "$CF" --repo /tmp --manifest 2>/dev/null)"; rc=$?
assert_eq       "check-freshness: trailing value-less --manifest exits 2 (no spin)" 2 "$rc"
