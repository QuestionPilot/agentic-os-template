#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/hooks-behavior.test.ps1 — Windows-native twin of tests/hooks-behavior.test.sh.
#
# Behavioral acceptance for the generated bash hooks (.sh built by install.sh).
# **Almost every assertion is SKIPped on the Windows lane** — the four exceptions
# are the byte-only fixture assertions in the middle of this file (two
# Assert-Contains over fixture text, the JSONL parse sweep, and that sweep's own
# positive control), which read tests/fixtures/*.jsonl and invoke no hook at all,
# so they run natively here and guard the same fixture bytes the bash twin
# guards. The rest are SKIPped because:
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
# <TEAM>-365 desktop/SDK gate-marker channel (bash-side behavioral coverage;
# the .ps1 hook marker channel is exercised in hooks-ps-parity.test.sh 3h).
_Skip 'hooks-behavior.test: session-agent/desktop: no marker exits 0' $reason
_Skip 'hooks-behavior.test: session-agent/desktop: no marker blocks' $reason
_Skip 'hooks-behavior.test: session-agent/desktop: deny names the marker path' $reason
_Skip 'hooks-behavior.test: session-agent/desktop: marker write allowed through' $reason
_Skip 'hooks-behavior.test: session-agent/desktop: marker write with the Execution line allowed through' $reason
# --- byte-only fixture assertions: NOT skipped ------------------------------
# These read fixture bytes and never invoke a hook, so the "install.ps1 emits
# .ps1 hooks" rationale above does not apply — they are host-portable and run for
# real on the Windows lane, byte-identical in intent to the bash twin
# (tests/hooks-behavior.test.sh lines ~98-125). The fourth is the sweep's own
# positive control, which has no bash counterpart: the bash twin gets its
# empty-file verdict from jq directly, while the PS loop has to reproduce it.
$hbFix = Join-Path $env:REPO_ROOT 'tests' 'fixtures'

Assert-Contains 'hooks-behavior.test: session-agent: no-linear fixture models the Execution template line' `
    (Get-Content -Raw -LiteralPath (Join-Path $hbFix 'transcript-session-agent-no-linear.jsonl')) `
    'Execution: inline | delegated wave | delegated wave + panel'

# SINGLE-quoted on purpose: the `\n` is the two characters backslash-n as they
# appear inside the fixture's JSON string, not a newline. A double-quoted PS
# string would leave `\n` literal too (backslash is not a PS escape), but the
# single-quoted form makes the intent explicit and matches the bash twin's
# single-quoted needle at tests/hooks-behavior.test.sh:107.
Assert-Contains 'hooks-behavior.test: session-agent: ok fixture declares Execution in the assistant declaration' `
    (Get-Content -Raw -LiteralPath (Join-Path $hbFix 'transcript-session-agent-ok.jsonl')) `
    'Linear gate: PROJ-1\nExecution: delegated wave'

# Same three globs the bash twin sweeps through jq, reproducing `jq -e .`'s
# per-FILE verdict rather than a per-line one. Verified against jq 1.x:
#   - a file with zero JSON values (0 bytes, or nothing but whitespace) exits 4
#     — jq calls that a failure, so ZERO PARSED VALUES counts as bad here too.
#     A per-line loop alone would parse nothing, flag nothing, and pass: the
#     positive control below is what pins that shut.
#   - interior blank lines between valid records exit 0 — whitespace-only lines
#     are therefore SKIPPED, not counted, so a CRLF or trailing-newline
#     difference cannot manufacture a false `bad=`.
#   - a malformed record exits 5 — a parse throw flags the file and stops it.
# The enumerated COUNT is part of the compared value, so a glob that matches
# nothing (a rename, a moved fixtures dir) fails loudly instead of passing on an
# empty set.
function Get-HbJsonlSummary {
    param([Parameter(Mandatory)][string]$Dir)
    $n = 0
    $bad = ''
    foreach ($glob in @('transcript-session-agent-*.jsonl', 'transcript-desktop-session-agent.jsonl', 'codex-transcript-session-agent-*.jsonl')) {
        foreach ($f in (Get-ChildItem -LiteralPath $Dir -Filter $glob -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $n++
            $parsed = 0
            $failed = $false
            foreach ($line in [System.IO.File]::ReadAllLines($f.FullName)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $null = ConvertFrom-Json -InputObject $line -ErrorAction Stop
                    $parsed++
                } catch {
                    $failed = $true
                    break
                }
            }
            # jq -e . parity: a throw OR an empty value stream is a failure. The
            # -or short-circuits so a failed file is never listed twice.
            if ($failed -or $parsed -eq 0) { $bad = "$bad $($f.Name)" }
        }
    }
    $count = if ($n -ge 8) { 'enumerated>=8' } else { "enumerated=$n" }
    $badTxt = if ($bad -ne '') { $bad } else { 'none' }
    return "$count bad=$badTxt"
}

Assert-Eq 'hooks-behavior.test: session-agent: every session-agent fixture parses as JSONL' `
    'enumerated>=8 bad=none' (Get-HbJsonlSummary -Dir $hbFix)

# POSITIVE CONTROL for the sweep itself: a checker that cannot fail is not a
# check. Three synthetic fixtures — 0 bytes, whitespace-only, and one valid
# record — must produce exactly the two empty ones in `bad`, in Sort-Object Name
# order (empty-ctl, good-ctl, ws-ctl).
$hbCtlDir = Join-Path ([IO.Path]::GetTempPath()) ('hb-jsonl-ctl-' + [Guid]::NewGuid().Guid.Substring(0,8))
try {
    New-Item -ItemType Directory -Path $hbCtlDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $hbCtlDir 'transcript-session-agent-empty-ctl.jsonl'), '')
    [System.IO.File]::WriteAllText((Join-Path $hbCtlDir 'transcript-session-agent-ws-ctl.jsonl'), "  `n`n")
    # SINGLE-quoted JSON: backslash is not a PowerShell escape, so a "\"" inside a
    # double-quoted string would terminate it. Single quotes carry the double
    # quotes literally; the newline is concatenated as its own escaped string.
    [System.IO.File]::WriteAllText((Join-Path $hbCtlDir 'transcript-session-agent-good-ctl.jsonl'), ('{"type":"user"}' + "`n"))
    Assert-Eq 'hooks-behavior.test: session-agent: JSONL sweep flags empty and whitespace-only fixtures (positive control)' `
        'enumerated=3 bad= transcript-session-agent-empty-ctl.jsonl transcript-session-agent-ws-ctl.jsonl' `
        (Get-HbJsonlSummary -Dir $hbCtlDir)
} finally {
    Remove-Item -LiteralPath $hbCtlDir -Recurse -Force -ErrorAction SilentlyContinue
}

_Skip 'hooks-behavior.test: session-agent/desktop: undeclared marker write blocks' $reason
_Skip 'hooks-behavior.test: session-agent/desktop: marker on disk allows' $reason
_Skip 'hooks-behavior.test: session-agent/desktop: declaration-less marker blocks' $reason
_Skip 'hooks-behavior.test: session-agent/desktop: bare value-less marker blocks' $reason
_Skip 'hooks-behavior.test: session-agent/desktop: value-less marker write blocks' $reason
_Skip 'hooks-behavior.test: session-agent/desktop: padded session id still keys the marker' $reason
_Skip 'hooks-behavior.test: session-agent/desktop: marker w/o skill run blocks' $reason
_Skip 'hooks-behavior.test: session-agent/desktop: stale marker reaped' $reason
_Skip 'hooks-behavior.test: session-agent/desktop: hostile session_id still blocks' $reason
_Skip 'hooks-behavior.test: session-agent/desktop: hostile id never echoed as path' $reason
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
# <TEAM>-364 distillation-lag nudge (bash-side behavioral coverage; the .ps1
# hook nudge block is exercised in hooks-ps-parity.test.ps1 section 5).
_Skip 'hooks-behavior.test: framework-surface: distillation lapse exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: distillation lapse emits header' $reason
_Skip 'hooks-behavior.test: framework-surface: distillation lapse names the note' $reason
_Skip 'hooks-behavior.test: framework-surface: distillation nudge says read-only' $reason
_Skip 'hooks-behavior.test: framework-surface: distillation nudge names its switch' $reason
_Skip 'hooks-behavior.test: framework-surface: distilled note exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: distilled note drops the nudge' $reason
_Skip 'hooks-behavior.test: framework-surface: distilled case keeps git-log' $reason
_Skip 'hooks-behavior.test: framework-surface: distillation kill switch exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: distillation kill switch drops nudge' $reason
_Skip 'hooks-behavior.test: framework-surface: distillation kill switch keeps git-log' $reason
_Skip 'hooks-behavior.test: framework-surface: unresolvable vault exits 0' $reason
_Skip 'hooks-behavior.test: framework-surface: unresolvable vault stays silent' $reason
_Skip 'hooks-behavior.test: framework-surface: unresolvable vault keeps git-log' $reason
