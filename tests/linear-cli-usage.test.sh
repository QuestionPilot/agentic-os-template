#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/linear-cli-usage.test.sh — drift tripwire for the static `linear` CLI
# usage fixture (linear/linear-cli-usage.md), the token-cheap command reference
# agents load instead of running --help chains.
#
# Three layers, each catching a different drift class:
#   T1 (hermetic)  — the fixture exists, names the SAME version tag the
#                    installer pins, and stays under the size budget that makes
#                    it worth loading (<1k tokens ≈ 4500 bytes).
#   T2 (hermetic)  — the fixture still teaches the two load-bearing contracts
#                    (`.nodes` unwrap + explicit open states) — a rewrite that
#                    drops either recreates the silent-miscount failure class.
#   T3 (live-only) — when the PINNED binary is on PATH, every command group the
#                    fixture names must exist in `linear --help`. Skipped (not
#                    failed) when the binary is absent or a different version:
#                    CI has no binary, and a non-pinned local binary would
#                    report drift against the wrong target.
#
# Sourced by tests/run.sh; never call `exit` — failures bubble through
# assertion counters.

_lcu_fixture="$REPO_ROOT/linear/linear-cli-usage.md"
_lcu_installer="$REPO_ROOT/scripts/install-linear-cli.sh"

# --- T1: fixture exists, version-pinned, and small ---------------------------
assert_file "linear-cli-usage fixture exists" "$_lcu_fixture"

_lcu_pin="$(sed -nE 's/^LINEAR_CLI_DEFAULT_VERSION="([^"]+)"$/\1/p' "$_lcu_installer" | head -n 1)"
assert_contains "installer default pin parsed (sanity)" "v:${_lcu_pin}" "v:v"
assert_contains "usage fixture names the installer's pinned version (${_lcu_pin})" \
  "$(cat "$_lcu_fixture" 2>/dev/null)" "$_lcu_pin"

_lcu_bytes="$(wc -c < "$_lcu_fixture" | tr -d ' ')"
assert_exit "usage fixture stays under the 4500-byte load budget (${_lcu_bytes}B)" 0 \
  -- test "$_lcu_bytes" -le 4500

# --- T2: the two load-bearing contracts survive rewrites ---------------------
_lcu_body="$(cat "$_lcu_fixture" 2>/dev/null)"
assert_contains "usage fixture teaches the .nodes unwrap contract" "$_lcu_body" ".nodes"
assert_contains "usage fixture teaches the explicit open-states contract" \
  "$_lcu_body" "-s triage -s backlog -s unstarted -s started"
assert_contains "usage fixture teaches the team-scope contract" "$_lcu_body" "--all-teams"

# --- T3: live drift check against the pinned binary (skip when absent) -------
_lcu_live_version=""
if command -v linear >/dev/null 2>&1; then
  _lcu_live_version="$(linear --version 2>/dev/null \
    | LC_ALL=C sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' \
    | LC_ALL=C grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
fi

if [ -n "$_lcu_live_version" ] && [ "v$_lcu_live_version" = "$_lcu_pin" ]; then
  _lcu_help="$(linear --help 2>&1 | LC_ALL=C sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g')"
  for _lcu_grp in auth issue team user project project-update cycle milestone \
                  initiative initiative-update label document completions config \
                  schema api; do
    assert_contains "pinned binary still exposes command group: $_lcu_grp" \
      "$_lcu_help" "$_lcu_grp"
  done
  _lcu_ihelp="$(linear issue --help 2>&1 | LC_ALL=C sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g')"
  for _lcu_sub in query view create update comment relation; do
    assert_contains "pinned binary still exposes issue subcommand: $_lcu_sub" \
      "$_lcu_ihelp" "$_lcu_sub"
  done
  # orient's mine cut parses "Display name:" out of `auth whoami` TEXT output —
  # an upstream rewording would silently degrade that cut, so pin the field here
  # (auth state permitting; an unauthenticated box just prints an error, which
  # this assertion would catch as drift — acceptable: the fixture's live layer
  # already assumes a configured operator machine).
  _lcu_whoami="$(linear auth whoami 2>&1 | LC_ALL=C sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g')"
  assert_contains "pinned binary whoami still prints the Display name field" \
    "$_lcu_whoami" "Display name:"
else
  # A named skip, not a silent pass: absence and version-mismatch are both
  # legitimate local states (CI has no binary at all), but they must be
  # visible in the run log so "drift-checked" is never claimed vacuously.
  printf 'note: linear-cli-usage T3 live drift check skipped (binary %s, pin %s)\n' \
    "${_lcu_live_version:-absent}" "$_lcu_pin"
fi
