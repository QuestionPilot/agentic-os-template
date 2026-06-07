#Requires -Version 7
# tests/codex.test.ps1 — Windows-native twin of tests/codex.test.sh.
#
# Codex-target build acceptance tests. **All assertions are SKIPped on
# the Windows lane** because `install.ps1` does not yet support the codex
# harness — line 280 dies with "codex harness is not implemented in the
# prototype — see Issue 5B". Codex install is
# (Issue 5B-d) scope.
#
# Per [[feedback_port_parity_vs_regression_split]] — when wires codex
# in install.ps1, these SKIPs lift to live assertions mirroring the bash twin.
# The bash twin still runs on macOS/Linux lanes.
#
# The acceptance contract requires same AC count + same PASS/FAIL on
# identical fixtures. _Skip preserves the count + carries rationale.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$reason = 'install.ps1 codex harness not implemented'

_Skip 'codex.test: codex build emits session-agent SKILL.md' $reason
_Skip 'codex.test: codex build emits AGENTS.md' $reason
_Skip 'codex.test: codex session-agent SKILL.md has neutral protocol' $reason
_Skip 'codex.test: codex session-agent SKILL.md has Codex realization' $reason
_Skip 'codex.test: codex build emits session-agent SKILL.md' $reason
_Skip 'codex.test: codex build emits closeout SKILL.md' $reason
_Skip 'codex.test: codex build does NOT generate deleted route SKILL.md' $reason
_Skip 'codex.test: codex build does NOT generate deleted skill-orchestrator SKILL.md' $reason
_Skip 'codex.test: codex build emits hook session-agent.sh' $reason
_Skip 'codex.test: codex build emits hook framework-surface.sh' $reason
_Skip 'codex.test: codex build does NOT generate deleted hooks/route.sh' $reason
_Skip 'codex.test: codex build emits hooks.json' $reason
_Skip 'codex.test: codex hooks.json is valid JSON' $reason
_Skip 'codex.test: codex hooks.json wires PreToolUse' $reason
_Skip 'codex.test: codex hooks.json wires SessionStart' $reason
_Skip 'codex.test: codex hooks.json does NOT wire a Stop hook' $reason
_Skip 'codex.test: codex PreToolUse matcher is apply_patch' $reason
_Skip 'codex.test: codex PreToolUse command points at target hooks dir' $reason
_Skip 'codex.test: codex build emits .build-manifest.json' $reason
_Skip 'codex.test: codex manifest is valid JSON' $reason
_Skip 'codex.test: codex manifest records the harness' $reason
_Skip 'codex.test: codex manifest tracks AGENTS.md generated' $reason
_Skip 'codex.test: codex manifest tracks hooks.json generated' $reason
_Skip 'codex.test: codex manifest tracks the codex adapter as a source' $reason
_Skip 'codex.test: codex manifest tracks AGENTS.template.md as a source' $reason
_Skip 'codex.test: harnesses/claude/adapter.md has no stale vendored-skill refs' $reason
_Skip 'codex.test: harnesses/codex/adapter.md has no stale vendored-skill refs' $reason
_Skip 'codex.test: codex AGENTS.md references README.md' $reason
_Skip 'codex.test: codex AGENTS.md references core/' $reason
_Skip 'codex.test: codex AGENTS.md carries the session-agent spine rule' $reason
_Skip 'codex.test: codex AGENTS.md has no unresolved placeholders' $reason
_Skip 'codex.test: codex AGENTS.md substitutes the vault path' $reason
_Skip 'codex.test: codex AGENTS.md substitutes the ai-config path' $reason
_Skip 'codex.test: codex AGENTS.md catalog has a row for session-agent' $reason
_Skip 'codex.test: codex AGENTS.md catalog has a row for closeout' $reason
_Skip 'codex.test: codex AGENTS.md catalog omits deleted route' $reason
_Skip 'codex.test: codex AGENTS.md catalog omits deleted skill-orchestrator' $reason
_Skip 'codex.test: codex AGENTS.md catalog omits removed firecrawl' $reason
_Skip 'codex.test: codex AGENTS.md catalog omits removed impeccable' $reason
_Skip 'codex.test: codex AGENTS.md catalog omits removed printing-press' $reason
_Skip 'codex.test: codex AGENTS.md catalog omits removed silver-platter' $reason
_Skip 'codex.test: codex: two builds are byte-identical (diff -r)' $reason
_Skip 'codex.test: codex: relative --out still produces hooks.json' $reason
_Skip 'codex.test: codex: every hooks.json command path is absolute' $reason
_Skip 'codex.test: codex full install exits 0' $reason
_Skip 'codex.test: codex install surfaces the /hooks trust step' $reason
_Skip 'codex.test: codex full install swaps session-agent SKILL.md' $reason
_Skip 'codex.test: codex full install swaps hooks.json' $reason
_Skip 'codex.test: codex full install swaps AGENTS.md' $reason
_Skip 'codex.test: codex full install swaps the session-agent hook' $reason
_Skip 'codex.test: codex install leaves no backup/temp dirs' $reason
_Skip 'codex.test: codex drift check passes on a clean build' $reason
_Skip 'codex.test: codex session-agent: no transcript exits 0' $reason
_Skip 'codex.test: codex session-agent: no transcript allows' $reason
_Skip 'codex.test: codex session-agent: no routing exits 0' $reason
_Skip 'codex.test: codex session-agent: no routing blocks' $reason
_Skip 'codex.test: codex session-agent: invoked+Linear allows' $reason
_Skip 'codex.test: codex session-agent: invoked w/o Linear blocks' $reason
_Skip 'codex.test: codex session-agent: kill switch allows' $reason
_Skip 'codex.test: codex framework-surface: emits context exits 0' $reason
_Skip 'codex.test: codex framework-surface: emits additionalContext' $reason
_Skip 'codex.test: codex framework-surface: kill switch is silent' $reason
_Skip 'codex.test: codex framework-surface: session-agent directive exits 0' $reason
_Skip 'codex.test: codex framework-surface: emits session-agent directive header' $reason
_Skip 'codex.test: codex framework-surface: directive references Mode 1' $reason
_Skip 'codex.test: codex framework-surface: directive uses $session-agent' $reason
_Skip 'codex.test: codex framework-surface: directive references kill switch' $reason
_Skip 'codex.test: codex framework-surface: SA-directive kill switch exits 0' $reason
_Skip 'codex.test: codex framework-surface: SA-directive kill switch drops block' $reason
_Skip 'codex.test: codex framework-surface: SA-directive kill switch keeps git-log' $reason
_Skip 'codex.test: codex session-agent: no jq exits 0' $reason
_Skip 'codex.test: codex session-agent: no jq fails closed (blocks)' $reason
_Skip 'codex.test: codex framework-surface: no jq exits 0' $reason
_Skip 'codex.test: codex framework-surface: no jq is silent (open)' $reason
_Skip 'codex.test: codex drift check fails after AGENTS.md is hand-edited' $reason
