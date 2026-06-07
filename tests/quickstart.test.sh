#!/usr/bin/env bash
# tests/quickstart.test.sh — assert the Quickstart section anchors
# exist in README.md and the examples/ scaffold exists.
#
# These tests are purely structural (no network, no install). They verify:
# (a) README.md contains the Quickstart section heading + key prose anchors.
# (b) examples/ directory and its README exist.
# (c) The sample project files exist and contain key content markers.
#
# Per [[feedback_self_tripping_test_source]], runtime-construct the sentinel
# string values so this test file's own source does not self-trip the scanner.

README="$REPO_ROOT/README.md"
readme_content="$(cat "$README" 2>/dev/null || true)"

# --- (a) README.md Quickstart section ---------------------------------------

# Section heading
QS_HEAD="##"" Quickstart"
assert_contains "README.md has Quickstart section heading" \
  "$readme_content" "$QS_HEAD"

# Who-is-this-for marker
assert_contains "README.md Quickstart has who-is-this-for prose" \
  "$readme_content" "operator"

# Clone step
assert_contains "README.md Quickstart has clone step" \
  "$readme_content" "git clone"

# Install step
assert_contains "README.md Quickstart has bootstrap install step" \
  "$readme_content" "bootstrap"

# First capability run anchor
assert_contains "README.md Quickstart has first-run guidance" \
  "$readme_content" "session-agent"

# examples/ pointer from README
assert_contains "README.md references examples/ directory" \
  "$readme_content" "examples/"

# --- (b) examples/ scaffold -------------------------------------------------

EXAMPLES_DIR="$REPO_ROOT/examples"

assert_file "examples/ README exists" \
  "$EXAMPLES_DIR/README.md"

assert_file "examples/sample-project/ CLAUDE.md exists" \
  "$EXAMPLES_DIR/sample-project/CLAUDE.md"

assert_file "examples/sample-project/ local.env.example exists" \
  "$EXAMPLES_DIR/sample-project/local.env.example"

# --- (c) examples content markers -------------------------------------------

examples_readme="$(cat "$EXAMPLES_DIR/README.md" 2>/dev/null || true)"

# How-to-run section exists
HOW_HEADER="##"" How to run"
assert_contains "examples/README.md has How-to-run section" \
  "$examples_readme" "$HOW_HEADER"

# References session-agent capability
assert_contains "examples/README.md references session-agent" \
  "$examples_readme" "session-agent"

# Sample project CLAUDE.md references session-agent
sp_claude="$(cat "$EXAMPLES_DIR/sample-project/CLAUDE.md" 2>/dev/null || true)"
assert_contains "examples/sample-project/CLAUDE.md references session-agent" \
  "$sp_claude" "session-agent"

# local.env.example contains CLAUDE_CONFIG_DIR placeholder
sp_env="$(cat "$EXAMPLES_DIR/sample-project/local.env.example" 2>/dev/null || true)"
assert_contains "examples/sample-project/local.env.example has CLAUDE_CONFIG_DIR" \
  "$sp_env" "CLAUDE_CONFIG_DIR"
