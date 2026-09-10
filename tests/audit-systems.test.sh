#!/usr/bin/env bash
# tests/audit-systems.test.sh — execute the exact Audit Systems fenced example.
#
# The scanner contract is documented behavior, so this extracts its fenced bash
# block from verification/audit-systems.md instead of copying the implementation.
# Each scanner result runs in its own minimal-PATH temp directory. The match
# sentinel is the stub's exit status, constructed at runtime; no repository or
# live index is mutated.

declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }

AS_TMP="$(mktemp -d)"
AS_EXAMPLE="$AS_TMP/audit-example.sh"
AS_DOC="$REPO_ROOT/verification/audit-systems.md"
AS_BASH="$(command -v bash)"

awk '
  { sub(/\r$/, "") }
  /^## Generic Example$/ { section = 1; next }
  section && /^```bash$/ { fence = 1; next }
  fence && /^```$/ { exit }
  fence { print }
' "$AS_DOC" > "$AS_EXAMPLE"
chmod +x "$AS_EXAMPLE"

as_run_example() { # <case> <scanner-exit|missing>
  local case_name scanner_state fixture bin
  case_name="$1"
  scanner_state="$2"
  fixture="$AS_TMP/$case_name"
  bin="$AS_TMP/$case_name-bin"
  mkdir "$fixture" "$bin"
  touch "$fixture/README.md" "$fixture/AGENTS.md"
  if [ "$scanner_state" != missing ]; then
    printf '#!/bin/sh\nexit %s\n' "$scanner_state" > "$bin/rg"
    chmod +x "$bin/rg"
  fi
  if ( cd "$fixture" && PATH="$bin" "$AS_BASH" "$AS_EXAMPLE" ) > "$AS_TMP/$case_name.out" 2>&1; then
    AS_RUN_RC=0
  else
    AS_RUN_RC=$?
  fi
  AS_RUN_OUT="$(cat "$AS_TMP/$case_name.out")"
}

as_run_example match 0
assert_eq "audit systems: an rg match exits 1" "1" "$AS_RUN_RC"
assert_contains "audit systems: an rg match reports a failure" "$AS_RUN_OUT" "FAIL likely secret pattern found"
assert_not_contains "audit systems: an rg match never reports a clean scan" "$AS_RUN_OUT" "PASS secret pattern scan clean"

as_run_example clean 1
assert_eq "audit systems: only rg exit 1 is clean" "0" "$AS_RUN_RC"
assert_contains "audit systems: rg exit 1 reports a clean scan" "$AS_RUN_OUT" "PASS secret pattern scan clean"

as_run_example error 2
assert_eq "audit systems: an rg error exits 1" "1" "$AS_RUN_RC"
assert_contains "audit systems: an rg error names its exit status" "$AS_RUN_OUT" "FAIL secret pattern scan error (exit 2)"
assert_not_contains "audit systems: an rg error never reports a clean scan" "$AS_RUN_OUT" "PASS secret pattern scan clean"

as_run_example unknown 126
assert_eq "audit systems: an unknown rg status exits 1" "1" "$AS_RUN_RC"
assert_contains "audit systems: an unknown rg status is named" "$AS_RUN_OUT" "FAIL secret pattern scan error (exit 126)"
assert_not_contains "audit systems: an unknown rg status never reports a clean scan" "$AS_RUN_OUT" "PASS secret pattern scan clean"

as_run_example missing missing
assert_eq "audit systems: an absent rg exits 1" "1" "$AS_RUN_RC"
assert_contains "audit systems: an absent rg is a named failure" "$AS_RUN_OUT" "FAIL required scanner unavailable: rg"
assert_not_contains "audit systems: an absent rg never reports a clean scan" "$AS_RUN_OUT" "PASS secret pattern scan clean"

rm -rf "$AS_TMP"
