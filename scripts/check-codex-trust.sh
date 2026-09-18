#!/usr/bin/env bash
# Report Codex project trust rows from CODEX_HOME/config.toml. The checker is
# read-only and fails instead of treating a missing parser or bad TOML as zero.
set -uo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)" || exit 2

for python in python3 python3.14 python3.13 python3.12 python3.11 python; do
  command -v "$python" >/dev/null 2>&1 || continue
  "$python" -c 'import tomllib' >/dev/null 2>&1 || continue
  exec "$python" "$script_dir/check-codex-trust.py" "$@"
done

if command -v py >/dev/null 2>&1; then
  for version in 3.14 3.13 3.12 3.11; do
    py "-$version" -c 'import tomllib' >/dev/null 2>&1 || continue
    exec py "-$version" "$script_dir/check-codex-trust.py" "$@"
  done
fi

printf 'FAIL check-codex-trust: Python 3.11+ with tomllib is required\n' >&2
exit 2
