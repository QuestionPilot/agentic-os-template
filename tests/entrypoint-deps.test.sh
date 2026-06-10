#!/usr/bin/env bash
# tests/entrypoint-deps.test.sh — agentic-os-template's root CLAUDE.md + AGENTS.md
# carry an Active-Work + Durable-Knowledge layers section plus the First-Time
# Setup Check, so fresh-clone sessions see Linear/Obsidian + install one-liner
# without needing to dig elsewhere first. These are hand-edited source files
# (not compiled outputs); the assertions guard against accidental deletion in
# future entrypoint edits.
#
# Section heading was softened by the editorial pass from "Required
# Dependencies" to "Active-Work and Durable-Knowledge Layers" — the framework
# accepts tracker + vault equivalents; Linear + Obsidian remain the canonical
# default examples but are not hard-required. The intent the original test
# guarded (the entrypoint surfaces tracker + vault + install command) is
# preserved by the assertions below.

CLAUDE_ENTRY="$(cat "$REPO_ROOT/CLAUDE.md")"
AGENTS_ENTRY="$(cat "$REPO_ROOT/AGENTS.md")"

# --- 1. CLAUDE.md entrypoint stub --------------------------------------------

assert_contains "agentic-os-template/CLAUDE.md has '## Active-Work and Durable-Knowledge Layers' section" \
  "$CLAUDE_ENTRY" "## Active-Work and Durable-Knowledge Layers"
assert_contains "agentic-os-template/CLAUDE.md layers section references linear/linear-setup.md" \
  "$CLAUDE_ENTRY" "linear/linear-setup.md"
assert_contains "agentic-os-template/CLAUDE.md layers section names Obsidian as canonical example" \
  "$CLAUDE_ENTRY" "Obsidian"
assert_contains "agentic-os-template/CLAUDE.md has '## First-Time Setup Check' section" \
  "$CLAUDE_ENTRY" "## First-Time Setup Check"
assert_contains "agentic-os-template/CLAUDE.md Setup Check probes \$CLAUDE_CONFIG_DIR" \
  "$CLAUDE_ENTRY" "\$CLAUDE_CONFIG_DIR/skills/closeout/SKILL.md"
assert_contains "agentic-os-template/CLAUDE.md Setup Check names install command" \
  "$CLAUDE_ENTRY" "bash scripts/install.sh --harness claude --harness codex"
# Fresh-clone prerequisite: install.sh exits if local.env is missing; the
# canonical fresh-clone entry is bootstrap.sh.
assert_contains "agentic-os-template/CLAUDE.md Setup Check names bootstrap.sh as fresh-clone entry" \
  "$CLAUDE_ENTRY" "bash scripts/bootstrap.sh"

# --- 2. AGENTS.md entrypoint stub (Codex parity) ----------------------------

assert_contains "agentic-os-template/AGENTS.md has '## Active-Work and Durable-Knowledge Layers' section" \
  "$AGENTS_ENTRY" "## Active-Work and Durable-Knowledge Layers"
assert_contains "agentic-os-template/AGENTS.md layers section references linear/linear-setup.md" \
  "$AGENTS_ENTRY" "linear/linear-setup.md"
assert_contains "agentic-os-template/AGENTS.md layers section names Obsidian as canonical example" \
  "$AGENTS_ENTRY" "Obsidian"
assert_contains "agentic-os-template/AGENTS.md has '## First-Time Setup Check' section" \
  "$AGENTS_ENTRY" "## First-Time Setup Check"
# Codex variant probes $CODEX_HOME (not $CLAUDE_CONFIG_DIR).
assert_contains "agentic-os-template/AGENTS.md Setup Check probes \$CODEX_HOME" \
  "$AGENTS_ENTRY" "\$CODEX_HOME/skills/closeout/SKILL.md"
assert_contains "agentic-os-template/AGENTS.md Setup Check names install command" \
  "$AGENTS_ENTRY" "bash scripts/install.sh --harness claude --harness codex"
# Fresh-clone prerequisite parity with CLAUDE.md.
assert_contains "agentic-os-template/AGENTS.md Setup Check names bootstrap.sh as fresh-clone entry" \
  "$AGENTS_ENTRY" "bash scripts/bootstrap.sh"
