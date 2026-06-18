#Requires -Version 7
# tiering: install-heavy — twin of the slow-marked.sh. Skipped by the
# fast tier ($env:TEST_TIER='fast').
# test-tier: slow
# tests/bootstrap.test.ps1 — Windows-native twin of tests/bootstrap.test.sh.
#
# bootstrap.sh acceptance tests. **All assertions are SKIPped on the
# Windows lane** because `scripts/bootstrap.sh` is bash-only and has no PS
# twin yet — bootstrap.ps1 is (Issue 5B-d) scope per the project plan
# at `docs/superpowers/plans/2026-05-25-public-template-rewrite.md`. The bash
# twin still runs on macOS/Linux lanes.
#
# Per [[feedback_port_parity_vs_regression_split]] — when ships
# bootstrap.ps1, the SKIPs lift to live assertions mirroring the bash twin
# behavior.
#
# The acceptance contract requires same AC count + same PASS/FAIL on
# identical fixtures. _Skip preserves the count + carries rationale.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$reason = 'bootstrap.sh is bash-only (no bootstrap.ps1) — out of scope for the Windows port'

_Skip 'bootstrap.test: bootstrap.sh --help exits 0' $reason
_Skip 'bootstrap.test: bootstrap.sh unknown arg exits 2' $reason
# <TEAM>-260 twin: validate_harnesses rejects unknown harness names (bootstrap.sh
# runs these end-to-end on macOS/Linux).
_Skip 'bootstrap.test: bootstrap.sh --harness typo --check rejects unknown harness' $reason
_Skip 'bootstrap.test: bootstrap.sh --harness typo (real run) rejects unknown harness' $reason
_Skip 'bootstrap.test: bootstrap.sh unknown-harness error lists the known set' $reason
_Skip 'bootstrap.test: bootstrap.sh --harness codex2 (substring of a known name) rejected as unknown' $reason
_Skip 'bootstrap.test: bootstrap --check exits 0 when all CLIs present' $reason
_Skip 'bootstrap.test: bootstrap --check reports missing rg' $reason
_Skip 'bootstrap.test: bootstrap --check says not found' $reason
_Skip 'bootstrap.test: bootstrap --check exits non-zero on missing CLI' $reason
_Skip 'bootstrap.test: bootstrap --check reports outdated jq' $reason
_Skip 'bootstrap.test: bootstrap --check reports version too old' $reason
_Skip 'bootstrap.test: bootstrap --check survives an unparseable CLI version' $reason
_Skip 'bootstrap.test: bootstrap --check still flags the unparseable CLI' $reason
_Skip 'bootstrap.test: install_clis skips brew when all CLIs present' $reason
_Skip 'bootstrap.test: dry-run shows rg install action' $reason
_Skip 'bootstrap.test: dry-run reports zshenv write' $reason
_Skip 'bootstrap.test: dry-run mentions the config dir' $reason
_Skip 'bootstrap.test: bootstrap created ~/.zshenv' $reason
_Skip 'bootstrap.test: zshenv exports CLAUDE_CONFIG_DIR' $reason
_Skip 'bootstrap.test: zshenv value is quoted (has backslash or quotes)' $reason
_Skip 'bootstrap.test: zshenv has exactly one CLAUDE_CONFIG_DIR line (idempotent)' $reason
_Skip 'bootstrap.test: check_auth warns on unauthenticated gh' $reason
_Skip 'bootstrap.test: full bootstrap exits 0' $reason
_Skip 'bootstrap.test: full bootstrap created ~/.zshenv' $reason
_Skip 'bootstrap.test: full bootstrap sets CLAUDE_CONFIG_DIR in zshenv' $reason
_Skip 'bootstrap.test: full bootstrap prints auth checklist' $reason
_Skip 'bootstrap.test: bootstrap.ps1 -Check exits 0 with all CLIs present' $reason
_Skip 'bootstrap.test: bootstrap.ps1 -Check exits 1 on missing CLI' $reason
_Skip 'bootstrap.test: bootstrap.ps1 -DryRun mentions rg install' $reason
_Skip 'bootstrap.test: fresh seed persists CLAUDE_CONFIG_DIR to ~/.zshenv' $reason
_Skip 'bootstrap.test: seeded ~/.zshenv carries the config dir' $reason
_Skip 'bootstrap.test: bootstrap.sh --check does not hard-fail on absent lineark' $reason
_Skip 'bootstrap.test: bootstrap.sh --check does not hard-fail on absent codegraph' $reason
_Skip 'bootstrap.test: bootstrap.sh --check does not hard-fail on absent superpowers' $reason
_Skip 'bootstrap.test: bootstrap.sh --check does not hard-fail on absent agy' $reason
# T-90D twin: codex is harness-conditional (bootstrap.sh runs these on macOS/Linux).
_Skip 'bootstrap.test: bootstrap.sh --check (claude) does not require codex' $reason
_Skip 'bootstrap.test: bootstrap.sh --check --harness codex flags absent codex as required' $reason
_Skip 'bootstrap.test: bootstrap.sh --check --harness CODEX (case-folded) flags absent codex' $reason

# no-bash assertions — mirror tests/bootstrap.test.sh's added block.
$qreason = 'bootstrap.test.sh runs these end-to-end on macOS/Linux; Windows lane covers PS-only behavior via tests/install.test.ps1 + tests/validate-ps.test.ps1 indirectly'
_Skip 'bootstrap.test: bootstrap.ps1 -Check exits 0 without bash on PATH' $qreason
_Skip "bootstrap.test: bootstrap.ps1 has no 'bash =' entry in cliMin" $qreason
_Skip "bootstrap.test: bootstrap.ps1 has no '& bash ' shell-out" $qreason
_Skip 'bootstrap.test: bootstrap.ps1 -DryRun routes install through pwsh' $qreason
_Skip 'bootstrap.test: bootstrap.ps1 -DryRun does NOT shell out to bash install.sh' $qreason
_Skip 'bootstrap.test: bootstrap.ps1 captures pwsh path via ProcessPath' $qreason
_Skip 'bootstrap.test: bootstrap.ps1 Invoke-SmokeTest calls check-drift.ps1' $qreason

# — bootstrap.test.sh runs these end-to-end via pwsh on
# macOS/Linux lanes; the Windows lane covers the PS-native install/validate
# behavior indirectly through tests/install.test.ps1 + tests/validate-ps.test.ps1.
$q133reason = 'bootstrap.test.sh runs these end-to-end via pwsh on macOS/Linux'
_Skip 'bootstrap.test: first-run (flag) bootstrap exits 0' $q133reason
_Skip 'bootstrap.test: first-run (flag) produced the entrypoint' $q133reason
_Skip 'bootstrap.test: first-run (flag) seeded local.env carries the config dir' $q133reason
_Skip 'bootstrap.test: first-run (env) bootstrap exits 0' $q133reason
_Skip 'bootstrap.test: first-run (env) produced the entrypoint' $q133reason
_Skip 'bootstrap.test: bootstrap.ps1 first-run (flag) exits 0' $q133reason
_Skip 'bootstrap.test: bootstrap.ps1 first-run produced the entrypoint' $q133reason
_Skip 'bootstrap.test: bootstrap.ps1 seeded local.env carries the config dir' $q133reason
_Skip 'bootstrap.test: --check exits 0 with firecrawl absent (firecrawl is optional)' $q133reason
_Skip 'bootstrap.test: --check does not flag firecrawl as required (not found)' $q133reason
_Skip 'bootstrap.test: bootstrap.ps1 $cliMin does not list firecrawl' $q133reason
_Skip 'bootstrap.test: bootstrap.ps1 -Check exits 0 with firecrawl absent' $q133reason
# <TEAM>-260 twin: Confirm-HarnessNames + honest -Harness doc (bootstrap.test.sh
# runs these end-to-end via pwsh on macOS/Linux).
_Skip 'bootstrap.test: bootstrap.ps1 -Harness typo -Check rejects unknown harness' $q133reason
_Skip 'bootstrap.test: bootstrap.ps1 unknown-harness error lists the known set' $q133reason
_Skip 'bootstrap.test: bootstrap.ps1 -Harness doc drops the wrong ''repeatable'' claim' $q133reason
_Skip 'bootstrap.test: bootstrap.ps1 -Harness doc warns the comma form is pwsh -File-hostile' $q133reason
_Skip 'bootstrap.test: bootstrap.ps1 -Harness codex -Check passes when codex present (codex now required for -Harness codex)' $q133reason
_Skip 'bootstrap.test: bootstrap.ps1 -Harness codex -Check flags absent codex as required' $q133reason
_Skip 'bootstrap.test: bootstrap.ps1 -Check (claude) does not require codex' $q133reason

# F6 (<TEAM>-295): version-compare parity. bootstrap.test.sh runs both the bash
# --check and the pwsh -Check boundary assertions end-to-end on macOS/Linux.
_Skip 'bootstrap.test: bootstrap --check accepts a 2-segment version equal to a 3-segment floor (version_ge parity)' $q133reason
_Skip 'bootstrap.test: bootstrap.ps1 -Check accepts segment-short versions equal to their floors (F6: version_ge parity, not [System.Version])' $q133reason
_Skip 'bootstrap.test: bootstrap.ps1 -Check survives an oversized (>Int64) version segment (F6: [double] port, no overflow crash)' $q133reason

# <TEAM>-297 twins: co-located-by-default resolution. bootstrap.test.sh runs the bash
# assertions live on macOS/Linux and the bootstrap.ps1 assertions via pwsh on those
# lanes; the Windows lane preserves the count + rationale here.
$colocreason = 'bootstrap.test.sh runs the bash + pwsh co-located assertions end-to-end on macOS/Linux'
_Skip 'bootstrap.test: co-located default: claude target is <repo>/.claude' $colocreason
_Skip 'bootstrap.test: co-located default: codex target is <repo>/.codex' $colocreason
_Skip 'bootstrap.test: --scattered: claude target is ~/.claude' $colocreason
_Skip 'bootstrap.test: --scattered: codex target is ~/.codex' $colocreason
_Skip 'bootstrap.test: explicit --claude-config-dir wins over co-located default' $colocreason
_Skip 'bootstrap.test: explicit run does not co-locate claude under the repo' $colocreason
_Skip 'bootstrap.test: bootstrap.ps1 co-located: CLAUDE_CONFIG_DIR defaults to <repo>/.claude' $colocreason
_Skip 'bootstrap.test: bootstrap.ps1 co-located: CODEX_HOME defaults to <repo>/.codex' $colocreason
_Skip 'bootstrap.test: bootstrap.ps1 -Scattered: targets resolve under the home dir' $colocreason
_Skip 'bootstrap.test: fresh seed exports co-located CODEX_HOME to ~/.zshenv' $colocreason
# <TEAM>-297 value-flow edge cases (cross-model panel) — bash + pwsh assertions run
# live on macOS/Linux; the Windows lane preserves the count + rationale.
_Skip 'bootstrap.test: co-located: --dry-run with an existing empty local.env still previews co-located' $colocreason
_Skip 'bootstrap.test: --scattered un-does a prior co-located default in local.env' $colocreason
_Skip 'bootstrap.test: --scattered preserves an operator-authored custom config path' $colocreason
_Skip 'bootstrap.test: co-located default resolves under a repo path containing a space' $colocreason
_Skip 'bootstrap.test: bootstrap.ps1 co-located: -DryRun with an existing empty local.env still resolves co-located' $colocreason
_Skip 'bootstrap.test: bootstrap.ps1 -Scattered un-does a prior co-located default in local.env' $colocreason
_Skip 'bootstrap.test: bootstrap.ps1 co-located resolves under a repo path containing a space' $colocreason
