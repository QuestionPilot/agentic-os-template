#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/standalone-guard.test.sh — meta-test for the standalone-invocation
# guard and the runner's targeted-run filter.
#
# Three things are pinned:
# (a) SHAPE: every tests/*.test.sh carries the bash guard marker and every
#     tests/*.test.ps1 carries the PS guard marker — so a future test file that
#     forgets the guard (and would false-green when run standalone) fails here.
# (b) BEHAVIOR: a standalone invocation of one real test file per language exits
#     non-zero and prints the run-via-runner message (the guard actually fires).
# (c) FILTER: the runner's targeted-run filter selects only the matching file and
#     exits 0 — the legitimate supported path for a targeted run.
#
# The markers are the byte-identical guard lines the guard block ends with:
#   bash → `declare -F assert_exit`   ps → `Get-Command Assert-Exit`
# This file necessarily contains BOTH literals (its own guard + the PS marker it
# greps for); that is fine — it is a .sh file, so the *.test.ps1 enumeration in
# (a) never scans it, and it matches its own bash marker as every twin must.
#
# Sourced by tests/run.sh — must not call `exit` or set `-e`. The guard above is
# the sole exception, and it never fires in the sourced path (helper present).

_sg_bash_marker='declare -F assert_exit'
_sg_ps_marker='Get-Command Assert-Exit'

# --- (a) every twin carries its guard marker ---------------------------------
_sg_missing_sh=""
for _sg_f in "$REPO_ROOT"/tests/*.test.sh; do
  grep -Fq "$_sg_bash_marker" "$_sg_f" || _sg_missing_sh="$_sg_missing_sh $(basename "$_sg_f")"
done
assert_eq "every tests/*.test.sh carries the standalone guard" "" "$_sg_missing_sh"

_sg_missing_ps=""
for _sg_f in "$REPO_ROOT"/tests/*.test.ps1; do
  grep -Fq "$_sg_ps_marker" "$_sg_f" || _sg_missing_ps="$_sg_missing_ps $(basename "$_sg_f")"
done
assert_eq "every tests/*.test.ps1 carries the standalone guard" "" "$_sg_missing_ps"

# --- (b) a standalone invocation actually bails ------------------------------
# Run a real test file directly (NOT via the runner). The guard is the file's
# first executable statement, so it exits before any assertion or REPO_ROOT use.
_sg_out="$(bash "$REPO_ROOT/tests/drift.test.sh" 2>&1)"; _sg_rc=$?
[ "$_sg_rc" -ne 0 ] && _sg_nz=yes || _sg_nz=no
assert_eq "standalone bash test file exits non-zero" "yes" "$_sg_nz"
assert_contains "standalone bash test file prints the run-via-runner message" \
  "$_sg_out" "run via tests/run.sh"

# --- (c) the targeted-run filter selects only the matching file --------------
# `tiers` matches exactly one fast test stem (tiers.test.sh) — cheap, so no slow
# candidate to skip. Nested runner runs in its own subprocess (own counters);
# only its exit code + output are inspected here.
_sg_filter_out="$(bash "$REPO_ROOT/tests/run.sh" tiers 2>&1)"; _sg_filter_rc=$?
assert_eq "targeted-run filter (tiers) exits 0" "0" "$_sg_filter_rc"
assert_contains "targeted-run filter actually ran the matched file" \
  "$_sg_filter_out" "tiers.test.sh"
assert_not_contains "targeted-run filter excluded non-matching files" \
  "$_sg_filter_out" "drift.test.sh"

unset _sg_bash_marker _sg_ps_marker _sg_missing_sh _sg_missing_ps _sg_f \
  _sg_out _sg_rc _sg_nz _sg_filter_out _sg_filter_rc
