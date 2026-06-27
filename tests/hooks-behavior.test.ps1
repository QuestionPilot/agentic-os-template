#Requires -Version 7
# tests/hooks-behavior.test.ps1 — Windows-native twin of tests/hooks-behavior.test.sh.
#
# Behavioral acceptance for the generated bash hooks (.sh built by install.sh).
# **All assertions are SKIPped on the Windows lane** because:
# 1. install.ps1 emits.ps1 hooks, not.sh hooks.
# 2. PS hook behavioral coverage is already supplied by:
# - tests/hooks-ps-parity.test.ps1 (codex Windows backslash markers)
# 3. The bash twin runs on macOS/Linux lanes exercising the.sh hooks built by install.sh.
#
# Per [[feedback_port_parity_vs_regression_split]] — the AC count is preserved
# via _Skip; the actual coverage is split: bash-side behavior on the bash twin,
# PS-side behavior in the sibling PS tests.
#
# The acceptance contract requires same AC count + same PASS/FAIL on
# identical fixtures. _Skip preserves the count + carries rationale.
#
# The closeout hook (and its PS twin) was removed — closeout is now
# manual-fire — so the closeout behavior/scope/no-jq/equivalence skips that used
# to live here are gone, matching the bash twin.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$reason = 'bash hook behavioral coverage — install.ps1 emits .ps1 hooks; PS hook coverage is in hooks-ps-parity.test.ps1'

_Skip 'hooks-behavior.test: session-agent: no transcript exits 0' $reason
_Skip 'hooks-behavior.test: session-agent: no transcript allows' $reason
_Skip 'hooks-behavior.test: session-agent: no routing exits 0' $reason
_Skip 'hooks-behavior.test: session-agent: no routing blocks' $reason
_Skip 'hooks-behavior.test: session-agent: invoked+Linear exits 0' $reason
_Skip 'hooks-behavior.test: session-agent: invoked+Linear allows' $reason
_Skip 'hooks-behavior.test: session-agent: invoked w/o Linear blocks' $reason
_Skip 'hooks-behavior.test: session-agent: kill switch allows' $reason
_Skip 'hooks-behavior.test: session-agent: block emits hookSpecificOutput' $reason
_Skip 'hooks-behavior.test: session-agent: block names PreToolUse event' $reason
_Skip 'hooks-behavior.test: session-agent: block uses permissionDecision deny' $reason
_Skip 'hooks-behavior.test: session-agent: block carries permissionDecisionReason' $reason
_Skip 'hooks-behavior.test: session-agent: block drops legacy decision form' $reason
_Skip 'hooks-behavior.test: session-agent: block JSON is structurally valid PreToolUse deny' $reason
_Skip 'hooks-behavior.test: session-agent: runtime-broken jq exits 0' $reason
_Skip 'hooks-behavior.test: session-agent: runtime-broken jq still blocks (fail-closed)' $reason
_Skip 'hooks-behavior.test: session-agent: runtime-broken jq emits static deny fallback' $reason
_Skip 'hooks-behavior.test: framework-surface: emits context exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: emits additionalContext' $reason
_Skip 'hooks-behavior.test: framework-surface: kill switch is silent' $reason
_Skip 'hooks-behavior.test: framework-surface: session-agent directive exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: emits session-agent directive header' $reason
_Skip 'hooks-behavior.test: framework-surface: directive references Mode 1' $reason
_Skip 'hooks-behavior.test: framework-surface: directive references session-agent' $reason
_Skip 'hooks-behavior.test: framework-surface: SA-directive kill switch exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: SA-directive kill switch drops block' $reason
_Skip 'hooks-behavior.test: framework-surface: SA-directive kill switch keeps git-log' $reason
# compaction/resume-aware session-agent directive (bash-side behavioral
# coverage; the.ps1 hook compaction branch is exercised in hooks-ps-parity.test.ps1).
_Skip 'hooks-behavior.test: framework-surface: compact directive exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: compact emits re-orient header' $reason
_Skip 'hooks-behavior.test: framework-surface: compact directive references Mode 1' $reason
_Skip 'hooks-behavior.test: framework-surface: compact directive references Mode 2' $reason
_Skip 'hooks-behavior.test: framework-surface: compact drops the kickoff header' $reason
_Skip 'hooks-behavior.test: framework-surface: explicit startup keeps kickoff header' $reason
_Skip 'hooks-behavior.test: framework-surface: startup drops the re-orient header' $reason
_Skip 'hooks-behavior.test: framework-surface: malformed source JSON exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: malformed source JSON keeps kickoff' $reason
_Skip 'hooks-behavior.test: framework-surface: malformed source JSON drops re-orient' $reason
_Skip 'hooks-behavior.test: framework-surface: probe exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: probe emits MCP block header' $reason
_Skip 'hooks-behavior.test: framework-surface: probe surfaces Linear' $reason
_Skip 'hooks-behavior.test: framework-surface: probe surfaces HubSpot' $reason
_Skip 'hooks-behavior.test: framework-surface: probe surfaces plugin MCPs' $reason
_Skip 'hooks-behavior.test: framework-surface: probe excludes Needs-auth' $reason
_Skip 'hooks-behavior.test: framework-surface: probe flags the silent-empty-tools case' $reason
_Skip 'hooks-behavior.test: framework-surface: probe links memory note' $reason
_Skip 'hooks-behavior.test: framework-surface: probe kill switch exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: probe kill switch drops block' $reason
_Skip 'hooks-behavior.test: framework-surface: probe kill switch keeps git-log' $reason
_Skip 'hooks-behavior.test: framework-surface: no-claude exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: no-claude omits MCP block' $reason
_Skip 'hooks-behavior.test: framework-surface: no-claude keeps git-log' $reason
_Skip 'hooks-behavior.test: framework-surface: all-disconnected exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: all-disconnected omits MCP block' $reason
_Skip 'hooks-behavior.test: framework-surface: all-disconnected keeps git-log' $reason
_Skip 'hooks-behavior.test: framework-surface: malformed output exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: malformed output omits MCP block' $reason
_Skip 'hooks-behavior.test: framework-surface: malformed output keeps git-log' $reason
# orphaned operator-local hook check (block 1c) — bash-side behavioral coverage;
# the .ps1 hook block 1c is exercised in hooks-ps-parity.test.ps1.
_Skip 'hooks-behavior.test: framework-surface: orphaned-hook check exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: warns on missing local hook script' $reason
_Skip 'hooks-behavior.test: framework-surface: names the missing hook path' $reason
_Skip 'hooks-behavior.test: framework-surface: orphaned-hook kill switch exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: orphaned-hook kill switch drops block' $reason
_Skip 'hooks-behavior.test: framework-surface: orphaned-hook kill switch keeps git-log' $reason
_Skip 'hooks-behavior.test: framework-surface: present local hook exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: present local hook stays silent' $reason
_Skip 'hooks-behavior.test: framework-surface: no settings.local.json exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: no settings.local.json stays silent' $reason
_Skip 'hooks-behavior.test: framework-surface: existing spaced-path hook stays silent' $reason
_Skip 'hooks-behavior.test: framework-surface: missing spaced-path hook warns' $reason
_Skip 'hooks-behavior.test: framework-surface: missing spaced-path hook names full path' $reason
_Skip 'hooks-behavior.test: framework-surface: multi-missing names first' $reason
_Skip 'hooks-behavior.test: framework-surface: multi-missing names second' $reason
_Skip 'hooks-behavior.test: framework-surface: relative-path command stays silent' $reason
_Skip 'hooks-behavior.test: framework-surface: empty settings.local.json exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: empty settings.local.json stays silent' $reason
_Skip 'hooks-behavior.test: framework-surface: invalid-JSON settings exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: invalid-JSON settings stays silent' $reason
_Skip 'hooks-behavior.test: framework-surface: odd-shape .hooks exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: odd-shape .hooks stays silent' $reason
# config-freshness nudge (bash-side behavioral coverage; the.ps1
# hook freshness block is unit-covered in check-freshness.test.ps1).
_Skip 'hooks-behavior.test: framework-surface: fresh install omits freshness nudge' $reason
_Skip 'hooks-behavior.test: framework-surface: stale install exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: stale install surfaces freshness nudge' $reason
_Skip 'hooks-behavior.test: framework-surface: freshness nudge names the stale source' $reason
_Skip 'hooks-behavior.test: framework-surface: freshness kill switch drops nudge' $reason
_Skip 'hooks-behavior.test: framework-surface: freshness kill switch keeps git-log' $reason
_Skip 'hooks-behavior.test: session-agent: no jq exits 0' $reason
_Skip 'hooks-behavior.test: session-agent: no jq fails closed (blocks)' $reason
_Skip 'hooks-behavior.test: session-agent: no jq emits PreToolUse deny shape' $reason
_Skip 'hooks-behavior.test: session-agent: no jq drops legacy decision form' $reason
_Skip 'hooks-behavior.test: framework-surface: no jq exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: no jq is silent (open)' $reason
