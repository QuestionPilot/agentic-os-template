#!/usr/bin/env bash
# tests/run.sh — discovers and runs every tests/*.test.sh, prints a summary.
#
# Test files are SOURCED, not executed: a bare `exit` in a *.test.sh file would
# kill this runner and suppress the summary. Test files must only call assert_*
# helpers and must never call `exit` directly. (Each test file carries a
# standalone-invocation guard that DOES exit non-zero, but only when the assert_*
# helpers are absent — i.e. never when sourced here. See any tests/*.test.sh top.)
#
# Optional first argument: a targeted-run FILTER — a substring matched against
# each test file's basename, so `bash tests/run.sh drift` runs only the files
# whose name contains "drift". This is the supported path for a targeted run (a
# bare `bash tests/foo.test.sh` bails via that file's guard). With no argument
# every test file runs, byte-for-byte unchanged.
#
# TEST_TIER (env, default 'full'): 'fast' skips slow-marked files (clone/build-
# heavy) for a quick inner loop; 'full' runs everything. CI and `make verify`
# run full. See tests/TIERS.md and the tier helpers in tests/lib.sh.
set -uo pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$tests_dir/.." && pwd)"
export REPO_ROOT="$repo_root"

# Targeted-run filter. Empty = match every file (the *""* pattern
# below matches all basenames), so the no-argument path is unchanged.
filter="${1:-}"

# Isolate the harness config-dir env vars for the WHOLE suite. A test that renders
# a harness (scripts/install.sh) resolves its build target from CLAUDE_CONFIG_DIR /
# CODEX_HOME / HERMES_HOME whenever its fixture local.env does not set them. When
# the suite runs from the operator's live co-located folder, the shell exports
# those to <repo>/.claude, <repo>/.codex, <repo>/.hermes — so an un-set fixture var
# leaks the LIVE config dir into a throwaway build and overwrites the operator's
# real entrypoint with test content (a temp OBSIDIAN_VAULT_PATH). Unsetting them
# here makes a live-folder run behave EXACTLY like a clean clone: the canonical CI
# gate already runs `env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u HERMES_HOME`; baking
# it into the runner makes that isolation intrinsic for every entry point (make
# test, CI, a direct `bash tests/run.sh`). Tests that need a config dir set it
# themselves per-invocation (env VAR=… / a fixture local.env), so this is safe.
unset CLAUDE_CONFIG_DIR CODEX_HOME HERMES_HOME

# shellcheck source=tests/lib.sh
. "$tests_dir/lib.sh"

shopt -s nullglob
found=0
matched=0
sourced=0
for tf in "$tests_dir"/*.test.sh; do
  found=1
  # Targeted-run filter: skip files whose basename does not contain $filter.
  # Empty $filter matches every basename, so the no-argument path is unchanged.
  case "$(basename "$tf")" in *"$filter"*) ;; *) continue ;; esac
  matched=1
  if ! _tier_should_run "$tf"; then
    printf '\n== %s == — skipped (TEST_TIER=%s)\n' "$(basename "$tf")" "${TEST_TIER:-full}"
    continue
  fi
  sourced=1
  printf '\n== %s ==\n' "$(basename "$tf")"
  # shellcheck disable=SC1090
  . "$tf"
done

if [ "$found" -eq 0 ]; then
  printf 'FAIL no test files found in %s\n' "$tests_dir" >&2
  exit 1
fi

# A non-empty filter that matched nothing is a caller error, not a silent pass
# (an empty run would print Total: 0 and exit 0 — the very false-green this guard
# closes). Empty filter can never reach here (it matches every file above).
if [ -n "$filter" ] && [ "$matched" -eq 0 ]; then
  printf 'FAIL no test files matched filter: %s\n' "$filter" >&2
  exit 1
fi

# A filter whose every match was tier-skipped is the same false green through a
# different door: Total: 0 + exit 0 while the requested test never ran. Distinct
# message from the no-match case so the caller sees WHICH gate tripped.
if [ -n "$filter" ] && [ "$sourced" -eq 0 ]; then
  printf 'FAIL filter matched only tier-skipped files (TEST_TIER=%s) — run with TEST_TIER=full\n' "${TEST_TIER:-full}" >&2
  exit 1
fi

printf '\n----------------------------------------\n'
printf 'Total: %s   Failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
printf 'PASS acceptance suite\n'
