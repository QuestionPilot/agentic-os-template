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
_Skip 'install-hermes.test: hermes build produced hooks/autonomy-drain.sh' $reason
_Skip 'install-hermes.test: hermes build produced hooks/memory-sanitize.sh' $reason
_Skip 'install-hermes.test: hermes build produced hooks/skill-gate.sh' $reason
_Skip 'install-hermes.test: hermes build produced hooks/steward.sh' $reason
_Skip 'install-hermes.test: hermes build produced hooks/hooks.yaml' $reason
_Skip 'install-hermes.test: hermes build produced plugins/agentic-os-hook-bridge/plugin.yaml' $reason
_Skip 'install-hermes.test: hermes build produced plugins/agentic-os-hook-bridge/__init__.py' $reason
_Skip 'install-hermes.test: hermes build produced SOUL.md' $reason
_Skip 'install-hermes.test: hermes build produced .build-manifest.json' $reason
_Skip 'install-hermes.test: hooks.yaml wires the pre_tool_call edit-gate matcher' $reason
_Skip 'install-hermes.test: hooks.yaml wires on_session_start to framework-surface' $reason
_Skip 'install-hermes.test: hooks.yaml enables the agentic-os-hook-bridge plugin' $reason
_Skip 'install-hermes.test: check-drift passes the fresh hermes build' $reason
_Skip 'install-hermes.test: check-drift exempts the hermes-app-written skills/.bundled_manifest' $reason
_Skip 'install-hermes.test: SOUL.md carries the session-agent spine directive' $reason
_Skip 'install-hermes.test: SOUL.md has no unresolved placeholders' $reason
_Skip 'install-hermes.test: gate blocks a write_file before the gate is open' $reason
_Skip 'install-hermes.test: gate blocks a terminal call before the gate is open' $reason
_Skip 'install-hermes.test: the gate-declaration write is allowed (silent stdout)' $reason
_Skip 'install-hermes.test: writes pass once the session gate file is declared' $reason
_Skip 'install-hermes.test: CLAUDE_SKIP_SESSION_AGENT=1 bypasses the gate' $reason
_Skip 'install-hermes.test: a payload without session_id stays silent' $reason
_Skip 'install-hermes.test: framework-surface output is valid JSON' $reason
_Skip 'install-hermes.test: unattended drain is OFF by default (silent)' $reason
_Skip 'install-hermes.test: unattended drain default-off leaves no log' $reason
_Skip 'install-hermes.test: enabled drain skips a telegram session (propose-only)' $reason
_Skip 'install-hermes.test: telegram session is never drained' $reason
_Skip 'install-hermes.test: skill_manage create is blocked pending approval' $reason
_Skip 'install-hermes.test: skill_manage read-only verb is gated too (no fast-path)' $reason
_Skip 'install-hermes.test: an operator approval marker allows ONE mutation' $reason
_Skip 'install-hermes.test: the approval marker is consumed on use' $reason
_Skip 'install-hermes.test: memory-sanitize blocks an injection payload shape' $reason
_Skip 'install-hermes.test: memory-sanitize passes benign content' $reason
_Skip 'install-hermes.test: steward is NOT scheduled in hooks.yaml (operator act)' $reason
_Skip 'install-hermes.test: steward skips when views match regeneration (no-delta)' $reason
_Skip 'install-hermes.test: steward enforces the daily run cap' $reason
_Skip 'install-hermes.test: re-install with an operator plugin subdir present builds clean' $reason
_Skip 'install-hermes.test: F7: operator plugin subdir survives hermes re-install' $reason
_Skip 'install-hermes.test: F7: operator plugin content preserved verbatim' $reason
_Skip 'install-hermes.test: F7: framework bridge plugin still installed after re-install' $reason
_Skip 'install-hermes.test: check-drift exempts the operator-added plugin subdir' $reason
_Skip 'install-hermes.test: check-drift flags a rogue file in a framework plugin dir (exit 1)' $reason
_Skip 'install-hermes.test: check-drift names the rogue framework-plugin file' $reason
_Skip 'install-hermes.test: N1: colliding non-framework plugins/ subdir warns on fresh install' $reason
_Skip 'install-hermes.test: forced SOUL.md swap failure aborts the hermes install (nonzero)' $reason
_Skip 'install-hermes.test: rollback restores the plugins/ backup from the shared root (timing)' $reason
_Skip 'install-hermes.test: rollback restores the skills/ tree from the shared root' $reason
_Skip 'install-hermes.test: run-private backup root removed after a both-paths rollback' $reason
