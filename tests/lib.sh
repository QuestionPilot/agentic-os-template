#!/usr/bin/env bash
# tests/lib.sh — assertion helpers for the acceptance suite. Sourced by test files.
# Each assert_* prints PASS/FAIL and increments the global counters.

TESTS_RUN=0
TESTS_FAILED=0

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  PASS %s\n' "$1"; }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL %s\n' "$1" >&2
  shift
  for line in "$@"; do printf '       %s\n' "$line" >&2; done
}

# assert_eq <label> <expected> <actual>
assert_eq() {
  # [[]] — safe when a value starts with '-' (unlike the [] test command).
  if [[ "$2" == "$3" ]]; then _pass "$1"
  else _fail "$1" "expected: [$2]" "actual:   [$3]"; fi
}

# assert_exit <label> <expected-code> -- <command...>
assert_exit() {
  local label="$1" want="$2"; shift 3
  # Run directly and capture the status — no subshell, no command substitution
  # that could swallow the code if errexit were ever active.
  local got
  "$@" >/dev/null 2>&1 && got=0 || got=$?
  if [ "$got" -eq "$want" ]; then _pass "$label"
  else _fail "$label" "expected exit $want, got $got"; fi
}

# assert_contains <label> <haystack> <needle>
assert_contains() {
  case "$2" in *"$3"*) _pass "$1";; *) _fail "$1" "string does not contain: [$3]";; esac
}

# assert_not_contains <label> <haystack> <needle>
assert_not_contains() {
  case "$2" in *"$3"*) _fail "$1" "string unexpectedly contains: [$3]";; *) _pass "$1";; esac
}

# assert_file <label> <path>
assert_file() {
  if [ -f "$2" ]; then _pass "$1"; else _fail "$1" "file not found: $2"; fi
}

# make_local_env <env-file> <config-dir> [vault-dir]
# Writes a minimal but complete local.env for install.sh test builds. install.sh
# generates CLAUDE.md from a template that references OBSIDIAN_VAULT_PATH; a
# build fixture must supply that var or the build fails on the empty-placeholder
# gate. (: codegraph removed from framework — CODEGRAPH_BINARY no longer
# in the signature.)
make_local_env() {
  # %q shell-quotes the values — install.sh sources local.env, so a path with a
  # space or '&' must be quoted to round-trip intact.
  { printf 'CLAUDE_CONFIG_DIR=%q\n' "$2"
    printf 'OBSIDIAN_VAULT_PATH=%q\n' "${3:-/tmp/test-vault}"
  } > "$1"
}

# make_codex_env <env-file> <codex-home> [vault-dir]
# Writes a minimal local.env for `install.sh --harness codex` test builds.
# install.sh resolves the codex build target from CODEX_HOME; the generated
# AGENTS.md references OBSIDIAN_VAULT_PATH, so a fixture must supply it or the
# build fails on the empty-placeholder gate.
make_codex_env() {
  { printf 'CODEX_HOME=%q\n' "$2"
    printf 'OBSIDIAN_VAULT_PATH=%q\n' "${3:-/tmp/test-vault}"
  } > "$1"
}

# make_hermes_env <env-file> <hermes-home> [vault-dir]
# Writes a minimal local.env for `install.sh --harness hermes` test builds.
# install.sh resolves the hermes build target from HERMES_HOME; the generated
# SOUL.md references OBSIDIAN_VAULT_PATH, so a fixture must supply it or the
# build fails on the empty-placeholder gate.
make_hermes_env() {
  { printf 'HERMES_HOME=%q\n' "$2"
    printf 'OBSIDIAN_VAULT_PATH=%q\n' "${3:-/tmp/test-vault}"
  } > "$1"
}

# _skip <label> [<reason>]
_skip() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  SKIP %s (%s)\n' "$1" "${2:-not applicable}"; }

# make_stub_cli <dir> <name> <version-output>
# Creates <dir>/<name> as a stub that prints <version-output> and exits 0.
# get_cli_version uses grep -oE so the version just needs the number somewhere.
make_stub_cli() {
  local dir="$1" name="$2" ver="$3"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$ver" > "$dir/$name"
  chmod +x "$dir/$name"
}

# --- Test tiering -------------------------------------------------
# A test file opts into the SLOW tier with a marker comment line:
# # test-tier: slow
# Unmarked files are FAST and run in every tier. The runner consults the
# TEST_TIER env var (default 'full'): 'fast' runs only fast-tier files; any
# other value (incl. unset / 'full') runs everything. CI + `make verify` run
# the full tier unchanged; `make test-fast` is the inner-loop convenience.
# See tests/TIERS.md for the rationale and the current slow set.
#
# The marker is anchored to start-of-line (^#) so a reference to the marker
# string *inside* a test body (quoted, indented, in a heredoc) does NOT
# misclassify that file — see the self-trip guard in tests/tiers.test.sh.
# Portable ERE: [[:space:]] (not GNU-only \s); BSD + GNU grep both honor it.
_TIER_MARKER_RE='^#[[:space:]]*test-tier:[[:space:]]*slow[[:space:]]*$'

# _test_tier_of <file> — echo 'slow' if <file> carries the slow marker, else 'fast'.
_test_tier_of() {
  if grep -qE "$_TIER_MARKER_RE" "$1" 2>/dev/null; then printf 'slow\n'; else printf 'fast\n'; fi
}

# _tier_should_run <file> — return 0 if <file> runs under the current TEST_TIER,
# 1 if it should be skipped. fast tier skips slow-marked files; every other
# tier runs all files.
_tier_should_run() {
  case "${TEST_TIER:-full}" in
    fast) [ "$(_test_tier_of "$1")" = fast ] ;;
    *)    return 0 ;;
  esac
}

