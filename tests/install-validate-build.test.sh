#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/install-validate-build.test.sh — regression coverage for install.sh's
# validate_build() unresolved-@@PLACEHOLDER@@ guard (<TEAM>-318).
#
# <TEAM>-315 (PR #58) changed that guard from `grep -rlE … | grep -q .` to
# `grep -rqE …`. The old form had a latent SIGPIPE false-PASS under `pipefail`:
# when MANY files matched, the downstream `grep -q` exited early and SIGPIPE'd
# the upstream `grep -rl`, flipping the pipeline non-zero and SHIPPING unresolved
# tokens. The cross-model review of PR #58 confirmed the fix correct but flagged
# the absence of a test — the highest-impact change in that PR was untested.
#
# This test exercises the real validate_build by SOURCING install.sh: PR for
# <TEAM>-318 added a `if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi` guard so the
# file's function definitions load without running the build/swap. install.sh's
# top-level setup still runs on source (it resolves a target + makes an empty
# build dir but compiles nothing), so we point AI_CONFIG_LOCAL_ENV at a throwaway
# local.env that resolves CLAUDE_CONFIG_DIR to a temp dir.
#
# This regression is bash-specific: the SIGPIPE-under-pipefail race only exists
# in the `grep | grep` pipeline. install.ps1's twin (Test-Build) uses
# Select-String with no pipeline, so there is no PS-side analogue to guard — the
# PS placeholder gate is already exercised by the full-script install.test.ps1.
#
# Sentinels (the @@TOKEN@@ markers) are constructed at runtime from a split `@@`
# so this test source carries no literal unresolved placeholder of its own.

# A throwaway local.env so sourcing install.sh's top-level setup resolves a temp
# target instead of dying on a missing local.env / unset CLAUDE_CONFIG_DIR.
IVB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/aos-ivb.XXXXXX")"
mkdir -p "$IVB_TMP/cfg"
printf 'CLAUDE_CONFIG_DIR=%s\n' "$IVB_TMP/cfg" > "$IVB_TMP/local.env"

# Run validate_build (sourced from install.sh) against a prepared $1=build dir.
# validate_build's die() calls `exit`, so it runs in its OWN inner subshell —
# `( validate_build )` — and the surrounding $() captures that subshell's exit.
# stderr is folded to stdout via $2 ("exit" → print the code; "msg" → print the
# die message) so one helper serves both the exit-code and message assertions.
ivb_run() {  # $1 = build dir, $2 = "exit"|"msg"
  local _bd="$1" _mode="$2"
  (
    export AI_CONFIG_LOCAL_ENV="$IVB_TMP/local.env"
    set --                                   # no args → arg-parse no-ops on source
    # shellcheck disable=SC1090
    . "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1   # main is guarded → no install
    set +e                                   # relax install.sh's set -e for the asserts
    # install.sh's top-level setup (which still runs on source) registered
    # `trap 'rm -rf "$BUILD"' EXIT` against its own temp build dir. Clear it
    # before pointing BUILD at our fixture — otherwise this subshell's exit would
    # delete the fixture out from under a later assertion.
    trap - EXIT
    BUILD="$_bd"
    MANAGED_PATHS="skills"                    # no *.json members → JSON loop is inert
    if [ "$_mode" = msg ]; then
      ( validate_build ) 2>&1 1>/dev/null
    else
      ( validate_build ) >/dev/null 2>&1
      echo "$?"
    fi
  )
}

# Runtime-built unresolved-placeholder token (split `@@` so this file is clean).
ivb_ph='@@'

# --- Scenario 1: MANY files with unresolved tokens → validate_build FAILs ---
# This is the actual SIGPIPE-under-pipefail regression the <TEAM>-315 fix closed
# (and that a future revert to `grep -rlE … | grep -q .` would reintroduce). With
# the OLD pipeline form, `grep -q` exits after the first match and closes the
# pipe; the upstream `grep -rlE`, still streaming the long match list, takes
# SIGPIPE; under `set -o pipefail` (which install.sh sets and this sourced
# subshell keeps — we only clear `set -e`) that flips the pipeline non-zero and
# the `if … ; then die; fi` FALSE-PASSES, shipping the tokens.
#
# Reproducing that race needs the match list to exceed one pipe buffer (~64 KiB)
# so `grep -rlE` must do a second write AFTER `grep -q` has closed the read end —
# a 2-file fixture (as the issue sketched) would not, and the old buggy form
# would pass it too (cross-model review finding). ~1200 token-bearing files with
# padded names push the path list well past 64 KiB. The CURRENT `grep -rqE` form
# has no pipe, so it FAILs deterministically here regardless of file count — this
# test is not flaky on correct code; it only bites a regression.
IVB_DIRTY="$IVB_TMP/dirty"
mkdir -p "$IVB_DIRTY/skills"
ivb_i=0
while [ "$ivb_i" -lt 1200 ]; do
  printf 'unresolved %sTOKEN%s marker\n' "$ivb_ph" "$ivb_ph" \
    > "$IVB_DIRTY/unresolved_placeholder_fixture_file_$ivb_i.txt"
  ivb_i=$((ivb_i + 1))
done
unset ivb_i
assert_eq "install.sh validate_build FAILs on unresolved tokens across many files (SIGPIPE-race guard)" \
  "1" "$(ivb_run "$IVB_DIRTY" exit)"
assert_contains "install.sh validate_build names the unresolved-placeholder failure" \
  "$(ivb_run "$IVB_DIRTY" msg)" "unresolved"

# --- Scenario 2: a clean build → validate_build passes ---
IVB_CLEAN="$IVB_TMP/clean"
mkdir -p "$IVB_CLEAN/skills"
printf 'fully resolved content, no markers\n' > "$IVB_CLEAN/ok.txt"
printf '# a normal skill body\n' > "$IVB_CLEAN/skills/SKILL.md"
assert_eq "install.sh validate_build passes on a clean build" \
  "0" "$(ivb_run "$IVB_CLEAN" exit)"

# --- Scenario 3: a single-file token is still caught (boundary) ---
# Guards against an over-correction that only fires on multi-file matches.
IVB_ONE="$IVB_TMP/onefile"
mkdir -p "$IVB_ONE/skills"
printf 'solo %sONLY%s marker\n' "$ivb_ph" "$ivb_ph" > "$IVB_ONE/just.txt"
assert_eq "install.sh validate_build FAILs on a single unresolved token" \
  "1" "$(ivb_run "$IVB_ONE" exit)"

# Inline cleanup (NOT trap EXIT — run.sh sources test files, so an EXIT trap
# would persist across sibling test files).
rm -rf "$IVB_TMP"
unset IVB_TMP IVB_DIRTY IVB_CLEAN IVB_ONE ivb_ph
unset -f ivb_run
