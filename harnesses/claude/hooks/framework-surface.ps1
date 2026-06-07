#Requires -Version 7
<#
.SYNOPSIS
    Framework-changes + MCP-health + session-agent-directive surfacing
    (Claude Code SessionStart event) — PowerShell port.

.DESCRIPTION
    <TEAM>-100 Windows-native prototype port of harnesses/claude/hooks/framework-surface.sh.

    Three independent blocks emitted in one additionalContext payload:
      1. ai-config git log (last N days) — picks up improvements from prior
         sessions
      2. `claude mcp list` ✓ Connected MCPs — surfaces the <TEAM>-59 silent-
         empty-tools failure mode
      3. session-agent invocation directive

    Filtered to startup/clear/compact via the settings.json matcher.

    @@AI_CONFIG_DIR@@ is a build placeholder — install.ps1 substitutes the
    absolute path to the ai-config checkout from local.env.

    Kill switches:
      CLAUDE_SKIP_FRAMEWORK_SURFACE=1           disables the whole hook
      CLAUDE_SKIP_FRESHNESS_CHECK=1             disables the config-freshness nudge
      CLAUDE_SKIP_MCP_PROBE=1                   disables the MCP-health block
      CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1     disables the session-agent block

    Window:
      CLAUDE_FRAMEWORK_SINCE_DAYS=N             overrides git-log window
                                                (default 10)

    stdin:  SessionStart event JSON — `.source` (startup/clear/compact via the
            matcher) selects the session-agent directive variant; rest unused
    stdout: when surfacing, JSON with hookSpecificOutput.additionalContext
    exit:   always 0 (fail-open; non-zero is a hook error)
#>

$ErrorActionPreference = 'Continue'

if ($env:CLAUDE_SKIP_FRAMEWORK_SURFACE -eq '1') {
    exit 0
}

# jq contract — surfacing hook fails OPEN: missing jq → quiet exit.
if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    exit 0
}

$AI_CONFIG_DIR = '@@AI_CONFIG_DIR@@'
$DAYS = if ($env:CLAUDE_FRAMEWORK_SINCE_DAYS) { $env:CLAUDE_FRAMEWORK_SINCE_DAYS } else { '10' }

# Capture the SessionStart event JSON. Its `source` field (startup/clear/
# compact, per the matcher) selects the session-agent directive variant below —
# a compacted session needs a RE-ORIENT directive, not the "first action this
# session" kickoff. jq is guaranteed here (checked above); on malformed/empty
# input `.source` resolves to empty → kickoff directive (the safe default,
# identical to prior behavior).
$EVENT_JSON = [Console]::In.ReadToEnd()
$SESSION_SOURCE = ''
if ($EVENT_JSON) {
    # Lowercase-normalize for bash↔PS parity (the bash twin canonicalizes via tr).
    $SESSION_SOURCE = "$($EVENT_JSON | & jq -r '.source // empty' 2>$null)".Trim().ToLowerInvariant()
}

# --- 1. ai-config git-log block --------------------------------------------
$GIT_BLOCK = ''
if (Test-Path -LiteralPath (Join-Path $AI_CONFIG_DIR '.git')) {
    $changes = & git -C $AI_CONFIG_DIR log --since="${DAYS}.days.ago" --pretty=format:'- %ad %s (%h)' --date=short 2>$null
    if ($changes) {
        $changesText = if ($changes -is [array]) { $changes -join "`n" } else { $changes }
        $GIT_BLOCK = @"
# Recent ai-config (framework) changes — last $DAYS days

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

    pwsh -File `$AI_CONFIG_DIR/scripts/install.ps1 --harness claude

Stale source(s):
$staleBullets

Disable this check: env ``CLAUDE_SKIP_FRESHNESS_CHECK=1``.
"@
        }
    }
}

# --- 2. MCP-health probe block ------------------------------------
$MCP_BLOCK = ''
if ($env:CLAUDE_SKIP_MCP_PROBE -ne '1' -and (Get-Command claude -ErrorAction SilentlyContinue)) {
    # Bound the probe via Start-Job with a 5-second timeout — pwsh-portable
    # equivalent of gtimeout/timeout. Start-Job is available on Windows /
    # macOS / Linux. Capture both stdout AND the wrapped command's
    # $LASTEXITCODE so a non-zero rc (e.g. claude mcp list partial output)
    # discards data — parity with bash framework-surface.sh:79-89.
    #
    # Per Codex confirmation review C-3: $job.State='Completed' is not a
    # rc-of-0 proxy. The job state is Completed even when the wrapped
    # command exited non-zero. Capture $LASTEXITCODE inside the script
    # block via a sentinel object so the consumer can distinguish.
    $job = Start-Job -ScriptBlock {
        $out = & claude mcp list 2>$null
        # Emit a sentinel envelope (last line) so the consumer can split
        # rc from output without re-evaluating $LASTEXITCODE in the parent
        # scope (which is a different scope from the job's $LASTEXITCODE).
        $rc = $LASTEXITCODE
        [pscustomobject]@{ kind = 'mcp-probe-envelope'; out = $out; rc = $rc }
    }
    $mcpOut = $null
    if (Wait-Job -Job $job -Timeout 5) {
        $received = Receive-Job -Job $job -ErrorAction SilentlyContinue
        # Filter to the envelope (the job may emit other objects from the
        # wrapped command if claude misbehaves).
        $envelope = $received | Where-Object {
            ($_ -is [pscustomobject]) -and ($_.PSObject.Properties.Name -contains 'kind') -and ($_.kind -eq 'mcp-probe-envelope')
        } | Select-Object -First 1
        if ($envelope -and $envelope.rc -eq 0) {
            $mcpOut = $envelope.out
        }
        if ($job.State -ne 'Completed') { $mcpOut = $null }
    } else {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        $mcpOut = $null
    }
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

    if ($mcpOut) {
        # `claude mcp list` lines:  <source-prefix>: <url-or-cmd> - <status>
        $connected = @($mcpOut | ForEach-Object { $_.ToString() } |
            Where-Object { $_ -match ' - ✓ Connected$' } |
            ForEach-Object { ($_ -split ': ', 2)[0] } |
            Sort-Object -Unique
        )
        if ($connected.Count -gt 0) {
            $count = $connected.Count
            $items = ($connected | ForEach-Object { "- $_" }) -join "`n"
            $MCP_BLOCK = @"


## MCP connectors (per ``claude mcp list``) — $count ✓ Connected

$items

If any of these MCPs are missing their tools from your session (``ToolSearch``
returns no matches for known tool names), this is the <TEAM>-59 silent-empty-tools
failure mode. Restart Claude Code to populate the deferred-tool catalog.
See ``reference_mcp_silent_empty_tools`` for the full pattern. Disable this probe: env ``CLAUDE_SKIP_MCP_PROBE=1``.
"@
        }
    }
}

# --- 3. Session-agent invocation directive (<TEAM>-71 + <TEAM>-241) --------------
$SA_BLOCK = ''
if ($env:CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE -ne '1') {
    if ($SESSION_SOURCE -eq 'compact') {
        # Post-compaction re-orient. The SessionStart matcher includes
        # `compact`, so this hook re-fires after a compaction and re-injects — but
        # the stock kickoff directive's "skip if already invoked this session"
        # clause can make the model SKIP re-orienting right when its Mode 1 orient
        # outputs were just summarized out of context. Emit an IDEMPOTENT re-orient
        # instead: re-run Mode 1 ONLY if the orient outputs are gone, else a cheap
        # Mode 2 route — so it cannot blindly double-orient on every compaction.
        # (`resume` is NOT in the matcher, so it never reaches this hook — and a
        # resumed session reloads its transcript, keeping the orient in context.)
        $SA_BLOCK = @"


## Session-agent — re-orient after compacted session

This session was just compacted; your earlier ``session-agent`` Mode 1 orient
context (memory bodies, Linear project/issue state, vault ``START.md``) may have
been summarized out of context. Re-establish orientation:

- If those orient outputs are NO LONGER in your context, re-invoke
  ``session-agent`` (Mode 1) to rebuild them.
- If they are still present, do NOT re-run the orient — a Mode 2 route on the
  next non-trivial prompt is enough.

Disable this directive entirely: env ``CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1``.
"@
    } else {
        # Fresh session (startup / clear / unknown source): the kickoff directive.
        $SA_BLOCK = @"


## Session-agent — invoke now (Mode 1: kickoff orient)

The ``session-agent`` capability is the spine. **Your first action this session
must be to invoke ``session-agent`` via the Skill tool** — Mode 1 fires the
kickoff orient (memory body-reads + Linear projects-first query + vault
``START.md`` + reconcile this session-start window's commits against memory
headlines), then routes the user's first request.

On every subsequent non-trivial prompt, re-invoke ``session-agent`` (Mode 2:
route only — Mode 1's orient outputs are still live in context).

Skip this directive if you have already invoked session-agent this session.
Disable the directive entirely: env ``CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1``.
"@
    }
}

if (-not $GIT_BLOCK -and -not $FRESH_BLOCK -and -not $MCP_BLOCK -and -not $SA_BLOCK) {
    exit 0
}

$CONTEXT = "${GIT_BLOCK}${FRESH_BLOCK}${MCP_BLOCK}${SA_BLOCK}"

# Emit JSON via jq for safe escaping (parity with bash hook). Pass the
# multiline context via --arg so jq escapes newlines + quotes correctly.
$jsonOut = & jq -n --arg ctx $CONTEXT '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
Write-Output $jsonOut
exit 0
