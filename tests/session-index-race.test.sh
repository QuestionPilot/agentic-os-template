#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }

if ! command -v node >/dev/null 2>&1; then
  _skip "session-index race regression" "node not installed"
else
  sir_out="$(node "$REPO_ROOT/tests/session-index-race.test.js" \
    "$REPO_ROOT/obsidian/vault-scaffolding/bin/generate-session-index.js" 2>&1)"
  sir_rc=$?
  assert_eq "session-index race fixture exits 0" "0" "$sir_rc"
  assert_contains "session-index race fixture proves stale writer is blocked" \
    "$sir_out" "PASS concurrent writer refuses active owner"
  assert_contains "session-index race fixture proves new receipt is reconciled once" \
    "$sir_out" "PASS final view contains B once"
  assert_contains "session-index race fixture proves failed rename keeps old bytes" \
    "$sir_out" "PASS failed rename preserves prior view"
fi
