#Requires -Version 7
# tests/install-hermes.test.ps1 — Windows-native twin of
# tests/install-hermes.test.sh.
#
# Hermes-target build acceptance tests. **All assertions are SKIPped on the
# Windows lane** because `install.ps1` does not yet support the hermes harness
# (it is WARN-skipped in multi-harness runs and hard-rejected single, the same
# contract as codex). When Windows hermes parity lands, these SKIPs lift to
# live assertions mirroring the bash twin. The bash twin still runs on
# macOS/Linux lanes.
#
# The acceptance contract requires same AC count + same PASS/FAIL on identical
# fixtures. _Skip preserves the count + carries rationale.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$reason = 'install.ps1 hermes harness not implemented'

_Skip 'install-hermes.test: install.sh --harness hermes builds clean' $reason
_Skip 'install-hermes.test: hermes build produced skills/session-agent/SKILL.md' $reason
_Skip 'install-hermes.test: hermes build produced skills/closeout/SKILL.md' $reason
_Skip 'install-hermes.test: hermes build produced skills/self-audit/SKILL.md' $reason
_Skip 'install-hermes.test: hermes build produced hooks/framework-surface.sh' $reason
_Skip 'install-hermes.test: hermes build produced hooks/session-agent.sh' $reason
_Skip 'install-hermes.test: hermes build produced hooks/hooks.yaml' $reason
_Skip 'install-hermes.test: hermes build produced plugins/agentic-os-hook-bridge/plugin.yaml' $reason
_Skip 'install-hermes.test: hermes build produced plugins/agentic-os-hook-bridge/__init__.py' $reason
_Skip 'install-hermes.test: hermes build produced SOUL.md' $reason
_Skip 'install-hermes.test: hermes build produced .build-manifest.json' $reason
_Skip 'install-hermes.test: hooks.yaml wires the pre_tool_call edit-gate matcher' $reason
_Skip 'install-hermes.test: hooks.yaml wires on_session_start to framework-surface' $reason
_Skip 'install-hermes.test: hooks.yaml enables the agentic-os-hook-bridge plugin' $reason
_Skip 'install-hermes.test: check-drift passes the fresh hermes build' $reason
_Skip 'install-hermes.test: SOUL.md carries the session-agent spine directive' $reason
_Skip 'install-hermes.test: SOUL.md has no unresolved placeholders' $reason
_Skip 'install-hermes.test: gate blocks a write_file before the gate is open' $reason
_Skip 'install-hermes.test: gate blocks a terminal call before the gate is open' $reason
_Skip 'install-hermes.test: the gate-declaration write is allowed (silent stdout)' $reason
_Skip 'install-hermes.test: writes pass once the session gate file is declared' $reason
_Skip 'install-hermes.test: CLAUDE_SKIP_SESSION_AGENT=1 bypasses the gate' $reason
_Skip 'install-hermes.test: a payload without session_id stays silent' $reason
_Skip 'install-hermes.test: framework-surface output is valid JSON' $reason
