#Requires -Version 7
# tests/entrypoint-deps.test.ps1 — Windows-native twin of tests/entrypoint-deps.test.sh.
#
# Asserts ai-config's root CLAUDE.md + AGENTS.md correctly point at the
# bootstrap chain. **All assertions are SKIPped on the Windows lane** because
# the bash twin runs `bootstrap.sh` (and install.sh --harness codex) — both
# unsupported on Windows-native:
# - bootstrap.sh has no PS twin
# - install.ps1 doesn't support codex
#
# Per [[feedback_port_parity_vs_regression_split]] — lifts post-fix.
#
# The acceptance contract requires same AC count + same PASS/FAIL on
# identical fixtures. _Skip preserves the count + carries rationale.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$reason = 'bootstrap.sh + install.sh --harness codex are out of scope for the Windows port'

_Skip 'entrypoint-deps.test: ai-config/CLAUDE.md has ''## Active-Work and Durable-Knowledge Layers'' section' $reason
_Skip 'entrypoint-deps.test: ai-config/CLAUDE.md layers section references linear/linear-setup.md' $reason
_Skip 'entrypoint-deps.test: ai-config/CLAUDE.md layers section names Obsidian as canonical example' $reason
_Skip 'entrypoint-deps.test: ai-config/CLAUDE.md has ''## First-Time Setup Check'' section' $reason
_Skip 'entrypoint-deps.test: ai-config/CLAUDE.md Setup Check probes $CLAUDE_CONFIG_DIR' $reason
_Skip 'entrypoint-deps.test: ai-config/CLAUDE.md Setup Check names install command' $reason
_Skip 'entrypoint-deps.test: ai-config/CLAUDE.md Setup Check names bootstrap.sh as fresh-clone entry' $reason
_Skip 'entrypoint-deps.test: ai-config/AGENTS.md has ''## Active-Work and Durable-Knowledge Layers'' section' $reason
_Skip 'entrypoint-deps.test: ai-config/AGENTS.md layers section references linear/linear-setup.md' $reason
_Skip 'entrypoint-deps.test: ai-config/AGENTS.md layers section names Obsidian as canonical example' $reason
_Skip 'entrypoint-deps.test: ai-config/AGENTS.md has ''## First-Time Setup Check'' section' $reason
_Skip 'entrypoint-deps.test: ai-config/AGENTS.md Setup Check probes $CODEX_HOME' $reason
_Skip 'entrypoint-deps.test: ai-config/AGENTS.md Setup Check names install command' $reason
_Skip 'entrypoint-deps.test: ai-config/AGENTS.md Setup Check names bootstrap.sh as fresh-clone entry' $reason
