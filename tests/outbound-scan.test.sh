#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/outbound-scan.test.sh — core/tool-use.md names the
# outbound-content-scan principle as a generic framework rule. The actual
# regex sweep is implemented in operator-local Shape C cross-model-review;
# this test only guards the framework-level principle's presence and shape.
#
# Codex F-1 amendment: the broad
# whole-file `assert_contains` for "## Guardrails" + "external" can be
# satisfied by pre-existing prose (the `## Guardrails` header itself + the
# pre-existing first bullet "external tool output"). Strengthen by binding
# directly to the new outbound-content-scan bullet's wording.

TOOL_USE="$(cat "$REPO_ROOT/core/tool-use.md")"

# Extract just the new outbound-content-scan bullet so subsequent
# assertions bind to its body, not the rest of the file. The bullet is
# a single markdown list line starting with `- **Outbound-content scan.**`.
# awk emits everything from the bullet through the next blank line.
OUTBOUND_BULLET="$(printf '%s\n' "$TOOL_USE" | awk '
  /^- \*\*Outbound-content scan\.\*\*/ { found=1 }
  found { print; if ($0 == "") exit }
')"

# --- Bullet present at all (structural) ------------------------------------

assert_contains "core/tool-use.md has '## Guardrails' section" \
  "$TOOL_USE" "## Guardrails"

assert_contains "core/tool-use.md Guardrails name outbound-content scan" \
  "$TOOL_USE" "**Outbound-content scan.**"

# --- Bullet body binds the right semantic surface --------------------------
# These assert against $OUTBOUND_BULLET (not the whole file), so they only
# pass when the actual outbound-content-scan bullet contains these tokens.

assert_contains "outbound-scan bullet names the pre-pipe trigger" \
  "$OUTBOUND_BULLET" "Before piping local content"
assert_contains "outbound-scan bullet names the scan action" \
  "$OUTBOUND_BULLET" "scan"
assert_contains "outbound-scan bullet names external model / service / API surface" \
  "$OUTBOUND_BULLET" "external model"
assert_contains "outbound-scan bullet names credential-shaped strings" \
  "$OUTBOUND_BULLET" "credential-shaped"
assert_contains "outbound-scan bullet names enforcement delegation" \
  "$OUTBOUND_BULLET" "implementations enforce"

# --- Generic-on-purpose guards --------------------------------------------
# Must NOT bake harness-specific or skill-specific paths into core/.
# Operators without cross-model-review still inherit the principle.
# Build the forbidden tokens at runtime from non-matching halves so this very
# file does not self-trip credential-scanners that ignore *.test.sh comments
# but read the script body (per [[feedback_self_tripping_test_source]]).
_q="sk-"; _r="ant-"
assert_not_contains "core/tool-use.md outbound-scan does not embed grep patterns" \
  "$TOOL_USE" "${_q}${_r}"
assert_not_contains "core/tool-use.md outbound-scan does not embed harness paths" \
  "$TOOL_USE" "cross-model-out/"
