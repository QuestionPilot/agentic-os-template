#!/usr/bin/env bash
# tests/fresh-clone-validate.test.sh — validate.sh must exit 0
# on a fresh clone with NO operator tools installed (no lineark, codegraph,
# superpowers, agy on PATH). Hermetic PATH manipulation — only POSIX baseline
# tools available.
#
# Sourced by tests/run.sh; uses assert_* helpers from tests/lib.sh. Never call
# `exit` — failures bubble through assertion counters.

# Minimal PATH = POSIX baseline only. No ~/.local/bin (lineark, codegraph,
# agy live there per operator install patterns). No homebrew Cellar.
MINIMAL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# Confirm we're stripping the operator tools (they should be on the real PATH
# in this test environment if the operator has them installed).
for tool in lineark codegraph agy; do
  if PATH="$MINIMAL_PATH" command -v "$tool" >/dev/null 2>&1; then
    _fail "fresh-clone PATH still has $tool" \
      "MINIMAL_PATH=$MINIMAL_PATH includes $tool — fix the test setup"
  fi
done

# Run validate.sh under the minimal PATH and check exit code + output.
fresh_out="$(PATH="$MINIMAL_PATH" bash "$REPO_ROOT/scripts/validate.sh" 2>&1)"
fresh_rc=$?

if [ "$fresh_rc" -eq 0 ]; then
  _pass "validate.sh exits 0 with no operator tools on PATH"
else
  _fail "validate.sh fails on fresh clone (no operator tools)" \
    "exit=$fresh_rc; first 400 chars of output: ${fresh_out:0:400}"
fi

# Defensive: any FAIL line in the output is a leak. The framework's allowed
# failures (.DS_Store, embedded.git, secret patterns, capability YAML) won't
# trigger on a clean checkout; tool-presence failures will.
# Runtime-construct the tool sentinels per [[feedback_self_tripping_test_source]]
# so this test source doesn't self-trip a future tool-name scanner.
TOOL_LINEARK="line""ark"
TOOL_CODEGRAPH="code""graph"
TOOL_SUPERPOWERS="super""powers"
TOOL_AGY="a""gy"
fail_re="^FAIL .*(${TOOL_LINEARK}|${TOOL_CODEGRAPH}|${TOOL_SUPERPOWERS}|${TOOL_AGY})"
if printf '%s' "$fresh_out" | grep -qE "$fail_re"; then
  _fail "validate.sh has tool-presence FAIL on fresh clone" \
    "output mentions FAIL near a tool name"
else
  _pass "validate.sh output contains no tool-presence FAIL lines"
fi
