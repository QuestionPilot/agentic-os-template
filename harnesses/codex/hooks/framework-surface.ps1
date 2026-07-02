#Requires -Version 7
<#
.SYNOPSIS
    Framework-changes + session-agent-directive surfacing
    (Codex SessionStart event) — PowerShell port.

.DESCRIPTION
    <TEAM>-113 Windows-native port of harnesses/codex/hooks/framework-surface.sh.

    Two independent blocks emitted in one additionalContext payload:
      1. agentic-os-template git log (last N days) — picks up improvements from prior
         sessions
      2. session-agent invocation directive

    (No `claude mcp list` MCP-health probe — that block is claude-specific
    in the claude harness twin; codex has no equivalent surface.)

    Filtered to startup/clear/compact via the hooks.json matcher (wired by
    install when the codex Windows lane lands).

    @@AI_CONFIG_DIR@@ is a build placeholder — install.ps1 (Issue 5B-d)
    will substitute the absolute path to the agentic-os-template checkout from
    local.env at install time, identical to install.sh's bash-twin
    substitution.

    Kill switches:
      CLAUDE_SKIP_FRAMEWORK_SURFACE=1           disables the whole hook
                                                (same env name as the Claude
                                                harness — one switch works
                                                regardless of harness)
      CLAUDE_SKIP_FRESHNESS_CHECK=1             disables the config-freshness
                                                nudge
      CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1     disables just the
                                                session-agent block

    Window:
      CLAUDE_FRAMEWORK_SINCE_DAYS=N             overrides git-log window
                                                (default 10)

    stdin:  SessionStart event JSON (drained but unused)
    stdout: when surfacing, JSON with hookSpecificOutput.additionalContext
    exit:   always 0 (fail-open; non-zero is treated as a hook error)

.NOTES
    Mirrors the bash twin 1:1, plus the claude-harness PS twin's pattern
    where applicable. Per [[reference_ps_port_traps]]:
      - trap #3 (Set-Content CRLF + BOM): JSON emission via jq for safe
        escaping + LF / no-BOM line-endings regardless of pwsh edition.
      - trap #5 (Start-Job $LASTEXITCODE leak): N/A — no jobs in codex
        framework-surface (the bash twin has no MCP probe either).
#>

$ErrorActionPreference = 'Continue'

if ($env:CLAUDE_SKIP_FRAMEWORK_SURFACE -eq '1') {
    exit 0
}

# jq contract — surfacing hook fails OPEN: without jq it cannot emit
# safely-escaped JSON, so stay silent rather than erroring. Missing
# framework context is not a safety risk (parity with bash twin).
if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    exit 0
}

$AI_CONFIG_DIR = '@@AI_CONFIG_DIR@@'
$DAYS = if ($env:CLAUDE_FRAMEWORK_SINCE_DAYS) { $env:CLAUDE_FRAMEWORK_SINCE_DAYS } else { '10' }

# Capture the SessionStart event JSON. Its `source` field (startup/clear/
# compact, per the matcher) selects the session-agent directive variant below
# — a compacted session needs a RE-ORIENT directive, not the kickoff (<TEAM>-360;
# mirrors the Claude twin). On malformed/empty input `.source` resolves to
# empty → kickoff directive (the safe default, identical to prior behavior).
$EVENT_JSON = [Console]::In.ReadToEnd()
$SESSION_SOURCE = ''
if ($EVENT_JSON) {
    # Lowercase-normalize for bash↔PS parity (the bash twin canonicalizes via tr).
    $SESSION_SOURCE = "$($EVENT_JSON | & jq -r '.source // empty' 2>$null)".Trim().ToLowerInvariant()
}

# --- 1. agentic-os-template git-log block --------------------------------------------
# Use Test-Path on .git (file OR directory): inside a linked git worktree
# .git is a regular file (gitlink) pointing at the main repo's
# .git/worktrees/<name>, not a directory. Test-Path with no -PathType
# accepts either, matching the bash twin's `[[ -e ... ]]`.
$GIT_BLOCK = ''
if (Test-Path -LiteralPath (Join-Path $AI_CONFIG_DIR '.git')) {
    $changes = & git -C $AI_CONFIG_DIR log --since="${DAYS}.days.ago" --pretty=format:'- %ad %s (%h)' --date=short 2>$null
    if ($changes) {
        # Per [[reference_ps_port_traps]] trap #2: external-command output
        # via | is array-of-lines. Collapse explicitly before interpolation.
        $changesText = if ($changes -is [array]) { $changes -join "`n" } else { $changes }
        $GIT_BLOCK = @"
# Recent agentic-os-template (framework) changes — last $DAYS days

The agentic OS framework has had the following commits recently. Use this to pick
up improvements from prior sessions and know what changed in the operating-system
layer itself:

$changesText

Full details: ``git -C "`$AI_CONFIG_DIR" log --since=$DAYS.days.ago``
Override window: env ``CLAUDE_FRAMEWORK_SINCE_DAYS=N``. Disable: env ``CLAUDE_SKIP_FRAMEWORK_SURFACE=1``.
"@
    }
}

# --- 1b. Config-freshness nudge --------------------------------------------
# Warn when the installed config was rendered from now-stale sources — a fixed
# hook/capability merged to main but install was never re-run, so it sits
# un-activated on this machine. check-drift CANNOT see this (it compares the
# install against its own build-time manifest, never the repo). This block diffs
# the manifest's recorded SOURCE hashes vs the current repo via
# scripts/check-freshness.ps1 and surfaces a soft "re-run install.sh" nudge.
# Soft signal only — never blocks. Fail-open: any error/indeterminate → silent.
$FRESH_BLOCK = ''
if ($env:CLAUDE_SKIP_FRESHNESS_CHECK -ne '1') {
    # Install dir is this hook's own parent (hooks live at <install>/hooks/).
    $INSTALL_DIR = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..') -ErrorAction SilentlyContinue).Path
    $FRESHNESS_SCRIPT = Join-Path $AI_CONFIG_DIR 'scripts/check-freshness.ps1'
    if ($INSTALL_DIR -and (Test-Path -LiteralPath (Join-Path $INSTALL_DIR '.build-manifest.json')) -and (Test-Path -LiteralPath $FRESHNESS_SCRIPT)) {
        # Use the CURRENTLY-RUNNING pwsh executable (resolved from $PID) rather
        # than a bare 'pwsh', so the nested call does not depend on PATH — a
        # PATH miss would leak a command-resolution error to stderr and leave
        # $LASTEXITCODE unset. Fall back to 'pwsh' if the path can't resolve.
        $pwshExe = try { (Get-Process -Id $PID).Path } catch { $null }
        if (-not $pwshExe) { $pwshExe = 'pwsh' }
        $staleList = & $pwshExe -NoProfile -File $FRESHNESS_SCRIPT --manifest $INSTALL_DIR --list 2>$null
        $freshRc = $LASTEXITCODE
        $staleArr = @($staleList | Where-Object { $null -ne $_ -and "$_".Trim() -ne '' })
        # exit 1 = stale (clean non-empty list). 0 = fresh, 2 = indeterminate:
        # both stay silent (fail-open) — only surface a confirmed-stale install.
        if ($freshRc -eq 1 -and $staleArr.Count -gt 0) {
            $staleCount = $staleArr.Count
            $staleBullets = ($staleArr | ForEach-Object { "- $_" }) -join "`n"
            $FRESH_BLOCK = @"


## ⚠ Installed config is stale — re-run install.sh

$staleCount framework source file(s) changed since your last ``install.sh``
render, so your live config may be running outdated hooks/capabilities.
check-drift won't catch this (it detects hand-edits, not staleness). Re-sync:

    pwsh -File `$AI_CONFIG_DIR/scripts/install.ps1 --harness codex

Stale source(s):
$staleBullets

Disable this check: env ``CLAUDE_SKIP_FRESHNESS_CHECK=1``.
"@
        }
    }
}

# --- 2. Session-agent invocation directive ------------------------
# Auto-fire mechanism for the session-agent spine capability. Emits one
# directive instructing the model to invoke session-agent as its first
# action (Mode 1: kickoff orient). Single trigger per session — the only
# mechanism that fires session-agent at session start (AGENTS.md prose and
# the PreToolUse hook are not duplicate triggers; PreToolUse is a safety
# net for file-modifying tool use, not a session-start trigger).
$SA_BLOCK = ''
if ($env:CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE -ne '1') {
    if ($SESSION_SOURCE -eq 'compact') {
        # Post-compaction re-orient (<TEAM>-360; mirrors the Claude twin). The
        # matcher includes `compact`, so this hook re-fires after a compaction
        # — but the stock kickoff directive's "skip if already invoked this
        # session" clause can make the model SKIP re-orienting right when its
        # Mode 1 orient outputs were just summarized out of context. Emit an
        # IDEMPOTENT re-orient instead: re-run Mode 1 ONLY if the orient
        # outputs are gone, else a cheap Mode 2 route.
        $SA_BLOCK = @"


## Session-agent — re-orient after compacted session

This session was just compacted; your earlier ```$session-agent`` Mode 1 orient
context (memory bodies, Linear project/issue state, vault ``START.md``) may have
been summarized out of context. Re-establish orientation:

- If those orient outputs are NO LONGER in your context, re-invoke
  ```$session-agent`` (Mode 1) to rebuild them.
- If they are still present, do NOT re-run the orient — a Mode 2 route on the
  next non-trivial prompt is enough.

Disable this directive entirely: env ``CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1``.
"@
    } else {
        # Fresh session (startup / clear / unknown source): the kickoff directive.
        # Leading blank lines separate this block from the git-log block above.
        $SA_BLOCK = @"


## Session-agent — invoke now (Mode 1: kickoff orient)

The ```$session-agent`` capability is the spine. **Your first action this session
must be to invoke ```$session-agent``** — Mode 1 fires the kickoff orient
(memory body-reads + Linear projects-first query + vault ``START.md`` +
reconcile this session-start window's commits against memory headlines), then
routes the user's first request.

On every subsequent non-trivial prompt, re-invoke ```$session-agent`` (Mode 2:
route only — Mode 1's orient outputs are still live in context).

Skip this directive if you have already invoked session-agent this session.
Disable the directive entirely: env ``CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1``.
"@
    }
}

# Nothing to surface from any block → quiet exit (parity with bash twin).
if (-not $GIT_BLOCK -and -not $FRESH_BLOCK -and -not $SA_BLOCK) {
    exit 0
}

$CONTEXT = "${GIT_BLOCK}${FRESH_BLOCK}${SA_BLOCK}"

# Emit JSON via jq for safe escaping (parity with bash hook). Pass the
# multiline context via --arg so jq escapes newlines + quotes correctly.
$jsonOut = & jq -nR --arg ctx $CONTEXT `
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
Write-Output $jsonOut
exit 0
