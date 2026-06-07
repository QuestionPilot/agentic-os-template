#!/usr/bin/env bash
# tests/run.sh — discovers and runs every tests/*.test.sh, prints a summary.
#
# Test files are SOURCED, not executed: a bare `exit` in a *.test.sh file would
# kill this runner and suppress the summary. Test files must only call assert_*
# helpers and must never call `exit` directly.
#
# TEST_TIER (env, default 'full'): 'fast' skips slow-marked files (clone/build-
# heavy) for a quick inner loop; 'full' runs everything. CI and `make verify`
# run full. See tests/TIERS.md and the tier helpers in tests/lib.sh.
set -uo pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$tests_dir/.." && pwd)"
export REPO_ROOT="$repo_root"

# shellcheck source=tests/lib.sh
. "$tests_dir/lib.sh"

shopt -s nullglob
found=0
for tf in "$tests_dir"/*.test.sh; do
  found=1
  if ! _tier_should_run "$tf"; then
    printf '\n== %s == — skipped (TEST_TIER=%s)\n' "$(basename "$tf")" "${TEST_TIER:-full}"
    continue
  fi
  printf '\n== %s ==\n' "$(basename "$tf")"
  # shellcheck disable=SC1090
  . "$tf"
done

if [ "$found" -eq 0 ]; then
  printf 'FAIL no test files found in %s\n' "$tests_dir" >&2
  exit 1
fi

printf '\n----------------------------------------\n'
printf 'Total: %s   Failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
printf 'PASS acceptance suite\n'
