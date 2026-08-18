#Requires -Version 7
<#
.SYNOPSIS
    Framework-changes + session-agent-directive surfacing
    (Cursor sessionStart event) — PowerShell twin of framework-surface.sh.

.DESCRIPTION
    Three independent blocks emitted in one `additional_context` payload:
      1. agentic-os-template git log (last N days) — picks up improvements from
         prior sessions
      2. config-freshness nudge (the installed render vs the current repo)
      3. session-agent invocation directive (the auto-fire mechanism)

    @@AI_CONFIG_DIR@@ is a build placeholder — install.ps1 substitutes the
    absolute path to the agentic-os-template checkout from local.env at install
    time, identical to install.sh's bash-twin substitution.

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

    stdin:  sessionStart event JSON ({session_id, is_background_agent,
            composer_mode} + base fields); `composer_mode` selects whether the
            directive is emitted
    stdout: when surfacing, {"additional_context": "<markdown>"}
    exit:   always 0 (fail-OPEN — a surfacing hook must never break a session;
            deliberately NOT wired failClosed)

.NOTES
    Cursor's sessionStart is fire-and-forget: the agent loop does not wait for
    or enforce a blocking response (docs 2026-08-18). It also never fires in a
    Cloud Agent. See harnesses/cursor/adapter.md Fact 2.

    Per [[reference_ps_port_traps]] trap #3 (Set-Content CRLF + BOM): JSON
    emission goes through jq for safe escaping + LF / no-BOM line endings
    regardless of pwsh edition.
#>

$ErrorActionPreference = 'Continue'

if ($env:CLAUDE_SKIP_FRAMEWORK_SURFACE -eq '1') {
    exit 0
}

# jq contract — surfacing hook, fails OPEN: without jq it cannot emit
# safely-escaped JSON, so it stays silent rather than erroring.
$jq = Get-Command jq -ErrorAction SilentlyContinue
if (-not $jq) { exit 0 }

$aiConfigDir = '@@AI_CONFIG_DIR@@'
$days = if ($env:CLAUDE_FRAMEWORK_SINCE_DAYS) { $env:CLAUDE_FRAMEWORK_SINCE_DAYS } else { '10' }

# The Cursor config home is this hook's own parent (hooks are installed at
# <config>\hooks\). Resolved at run time rather than templated so the directive
# below can print the REAL absolute gate path the model must write.
$chome = Split-Path -Parent $PSScriptRoot

# Drain stdin and read composer_mode. An `ask`-mode composer cannot invoke a
# skill or edit files, so the kickoff directive would be noise there. Absent /
# unknown mode → treat as agent (the safe default). PowerShell's -eq is
# case-insensitive, matching the bash twin's explicit lowercase normalization.
$inputRaw = [Console]::In.ReadToEnd()
$composerMode = ''
try {
    $evt = $inputRaw | ConvertFrom-Json
    if ($evt) { $composerMode = [string]$evt.composer_mode }
} catch { $composerMode = '' }

# --- 1. agentic-os-template git-log block ----------------------------------
# Test-Path (not a directory test) on .git: inside a linked git worktree it is
# a regular file (gitlink), not a directory.
$gitBlock = ''
if (Test-Path -LiteralPath (Join-Path $aiConfigDir '.git')) {
    $changes = (& git -C $aiConfigDir log --since="$days.days.ago" --pretty=format:'- %ad %s (%h)' --date=short 2>$null) -join "`n"
    if ($changes) {
        $gitBlock = @"
# Recent agentic-os-template (framework) changes — last $days days

The agentic OS framework has had the following commits recently. Use this to pick
up improvements from prior sessions and know what changed in the operating-system
layer itself:

$changes

Full details: ``git -C "`$AI_CONFIG_DIR" log --since=$days.days.ago``
Override window: env ``CLAUDE_FRAMEWORK_SINCE_DAYS=N``. Disable: env ``CLAUDE_SKIP_FRAMEWORK_SURFACE=1``.
"@
    }
}

# --- 1b. Config-freshness nudge --------------------------------------------
# Surfaces a confirmed-stale install (sources changed since the last render).
# Soft signal only — never blocks. Fail-open: any error or indeterminate
# result stays silent. exit 1 = stale, 0 = fresh, 2 = indeterminate.
$freshBlock = ''
if ($env:CLAUDE_SKIP_FRESHNESS_CHECK -ne '1') {
    $installDir = $chome
    $freshnessScript = Join-Path (Join-Path $aiConfigDir 'scripts') 'check-freshness.ps1'
    if ($installDir -and
        (Test-Path -LiteralPath (Join-Path $installDir '.build-manifest.json')) -and
        (Test-Path -LiteralPath $freshnessScript)) {
        $staleList = @(& pwsh -NoProfile -File $freshnessScript -Manifest $installDir -List 2>$null)
        $freshRc = $LASTEXITCODE
        if ($freshRc -eq 1 -and $staleList.Count -gt 0) {
            $staleLines = ($staleList | ForEach-Object { "- $_" }) -join "`n"
            $freshBlock = @"


## Installed config is stale — re-run install.ps1

$($staleList.Count) framework source file(s) changed since your last install
render, so your live config may be running outdated hooks/capabilities.
check-drift won't catch this (it detects hand-edits, not staleness). Re-sync:

    pwsh `$AI_CONFIG_DIR/scripts/install.ps1 --harness cursor

Stale source(s):
$staleLines

Disable this check: env ``CLAUDE_SKIP_FRESHNESS_CHECK=1``.
"@
        }
    }
}

# --- 2. Session-agent invocation directive ---------------------------------
# Auto-fire mechanism for the session-agent spine capability. There is no
# compact variant (the Claude/Codex twins have one): Cursor splits compaction
# onto its own `preCompact` event, which is explicitly observational and cannot
# inject context, so a post-compaction re-orient has no delivery channel here.
$saBlock = ''
if ($env:CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE -ne '1' -and $composerMode -ne 'ask') {
    $saBlock = @"


## Session-agent — invoke now (Mode 1: kickoff orient)

The ``/session-agent`` capability is the spine. **Your first action this session
must be to invoke ``/session-agent``** — Mode 1 fires the kickoff orient (memory
body-reads + tracker projects-first query + vault ``START.md`` + reconcile this
session-start window's commits against memory headlines), then routes the
user's first request.

On every subsequent non-trivial prompt, re-invoke ``/session-agent`` (Mode 2:
route only — Mode 1's orient outputs are still live in context).

Before your first file-modifying tool use, open the edit gate: write your R5
routing declaration (including the ``Linear gate:`` and ``Lessons:`` lines) to
``$chome/agentic-os/gate-<conversation_id>`` — substituting this conversation's
id. The realization body in the capability spells out the contract.

Skip this directive if you have already invoked session-agent this session.
Disable the directive entirely: env ``CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1``.
"@
}

if (-not $gitBlock -and -not $freshBlock -and -not $saBlock) { exit 0 }

$context = "$gitBlock$freshBlock$saBlock"

# Emit JSON via jq for safe escaping (trap #3: avoids CRLF/BOM from
# Set-Content / ConvertTo-Json file writes). Pass the multiline context via
# --arg so jq escapes newlines + quotes correctly. Cursor's sessionStart output
# schema is {env?, additional_context?} — this hook sets no session env vars.
$jsonOut = & jq -nR --arg ctx $context '{additional_context: $ctx}'
Write-Output $jsonOut
exit 0
