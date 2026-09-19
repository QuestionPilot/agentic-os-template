#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }

# The canonical communication rule is injected into all four entrypoints. This
# proves the rendered behavior, including the fail-closed source dependency.
CSR_DIR="$(mktemp -d)"
CSR_STYLE="$REPO_ROOT/core/communication-style.md"
CSR_STYLE_CONTENT="$(cat "$CSR_STYLE")"

csr_render() {
  local harness="$1" target env_file build status=0
  target="$CSR_DIR/$harness"
  env_file="$CSR_DIR/$harness.local.env"
  case "$harness" in
    claude) make_local_env "$env_file" "$target" "$CSR_DIR/vault" ;;
    codex) make_codex_env "$env_file" "$target" "$CSR_DIR/vault" ;;
    hermes) make_hermes_env "$env_file" "$target" "$CSR_DIR/vault" ;;
    cursor) make_cursor_env "$env_file" "$target" "$CSR_DIR/vault" ;;
  esac
  build="$(AI_CONFIG_LOCAL_ENV="$env_file" bash "$REPO_ROOT/scripts/install.sh" --harness "$harness" --build-only 2>&1)" || status=$?
  assert_eq "communication style: $harness isolated render exits 0" "0" "$status"
  if [ "$status" -ne 0 ]; then
    printf '       render output (%s):\n%s\n' "$harness" "$build" >&2
    return
  fi
  build="${build##*$'\n'}"
  case "$harness" in claude) entrypoint="$build/CLAUDE.md" ;; codex|cursor) entrypoint="$build/AGENTS.md" ;; hermes) entrypoint="$build/SOUL.md" ;; esac
  assert_file "communication style: $harness entrypoint exists" "$entrypoint"
  [ -f "$entrypoint" ] || return
  assert_contains "communication style: $harness entrypoint has canonical text" "$(cat "$entrypoint")" "$CSR_STYLE_CONTENT"
  assert_eq "communication style: $harness injects the title once" "1" \
    "$(grep -cF '## Default communication style — plain and brief' "$entrypoint" || true)"
  csr_title_line="$(grep -nF '## Default communication style — plain and brief' "$entrypoint" | cut -d: -f1)"
  if [ "${csr_title_line:-0}" -le 20 ]; then
    _pass "communication style: $harness places the rule near the top"
  else
    _fail "communication style: $harness places the rule near the top" "title line: ${csr_title_line:-missing}"
  fi
  assert_not_contains "communication style: $harness leaves no include marker" "$(cat "$entrypoint")" '@@COMMUNICATION_STYLE@@'
  rm -rf "$build"
}

for csr_harness in claude codex hermes cursor; do
  csr_render "$csr_harness"
done

# A missing core source must stop compilation with a clear error. Use a copy so
# this assertion cannot modify the real checkout.
CSR_COPY="$CSR_DIR/missing-source-repo"
copy_repo_tracked "$CSR_COPY"
rm -f "$CSR_COPY/core/communication-style.md"
CSR_MISSING_ENV="$CSR_DIR/missing-source.local.env"
make_local_env "$CSR_MISSING_ENV" "$CSR_DIR/missing-source-output" "$CSR_DIR/vault"
csr_missing_output="$(AI_CONFIG_LOCAL_ENV="$CSR_MISSING_ENV" bash "$CSR_COPY/scripts/install.sh" --harness claude --build-only 2>&1)"; csr_missing_status=$?
assert_eq "communication style: missing source fails closed" "1" "$csr_missing_status"
assert_contains "communication style: missing source names the cause" "$csr_missing_output" "communication style source not found"

rm -rf "$CSR_DIR"
