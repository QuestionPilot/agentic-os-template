#Requires -Version 7
# Framework-changes surfacing hook (Hermes on_session_start event) — Windows
# twin of framework-surface.sh. Surfaces recent agentic-os-template commits,
# a config-freshness nudge, and the session-agent auto-fire directive as
# Hermes context injection ({"context": "..."}).
#
# Kill switches (same env names as the bash twin / other harnesses):
#   CLAUDE_SKIP_FRAMEWORK_SURFACE=1, CLAUDE_SKIP_FRESHNESS_CHECK=1,
#   CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1, CLAUDE_FRAMEWORK_SINCE_DAYS=N
#
# stdin:  on_session_start event JSON (drained but unused)
# stdout: when surfacing, {"context": "..."}
# exit:   always 0 (fail-open; surfacing hook)

$ErrorActionPreference = 'SilentlyContinue'

if ($env:CLAUDE_SKIP_FRAMEWORK_SURFACE -eq '1') { exit 0 }

$AI_CONFIG_DIR = '@@AI_CONFIG_DIR@@'
$days = if ($env:CLAUDE_FRAMEWORK_SINCE_DAYS) { $env:CLAUDE_FRAMEWORK_SINCE_DAYS } else { '10' }

# Drain stdin (event JSON unused).
[void][Console]::In.ReadToEnd()

# --- 1. agentic-os-template git-log block ---------------------------------
$gitBlock = ''
if (Test-Path -LiteralPath (Join-Path $AI_CONFIG_DIR '.git')) {
    $changes = git -C $AI_CONFIG_DIR log --since="$days.days.ago" --pretty=format:'- %ad %s (%h)' --date=short 2>$null
    if ($changes) {
        $changesText = ($changes -join "`n")
        $gitBlock = @"
# Recent agentic-os-template (framework) changes — last $days days

The agentic OS framework has had the following commits recently. Use this to pick
up improvements from prior sessions and know what changed in the operating-system
layer itself:

$changesText

Full details: ``git -C "`$AI_CONFIG_DIR" log --since=$days.days.ago``
Override window: env ``CLAUDE_FRAMEWORK_SINCE_DAYS=N``. Disable: env ``CLAUDE_SKIP_FRAMEWORK_SURFACE=1``.
"@
    }
}

# --- 1b. Config-freshness nudge --------------------------------------------
$freshBlock = ''
if ($env:CLAUDE_SKIP_FRESHNESS_CHECK -ne '1') {
    $installDir = Split-Path -Parent $PSScriptRoot
    $freshnessScript = Join-Path $AI_CONFIG_DIR 'scripts' 'check-freshness.ps1'
    $manifest = Join-Path $installDir '.build-manifest.json'
    if ($installDir -and (Test-Path -LiteralPath $manifest) -and (Test-Path -LiteralPath $freshnessScript)) {
        $staleList = & pwsh -NoProfile -File $freshnessScript -Manifest $installDir -List 2>$null
        $freshRc = $LASTEXITCODE
        if ($freshRc -eq 1 -and $staleList) {
            $staleLines = ($staleList | ForEach-Object { "- $_" }) -join "`n"
            $staleCount = @($staleList).Count
            $freshBlock = @"


## ⚠ Installed config is stale — re-run install.ps1

$staleCount framework source file(s) changed since your last install render, so
your live config may be running outdated hooks/capabilities. Re-sync:

    pwsh `$AI_CONFIG_DIR/scripts/install.ps1 -Harness hermes

Stale source(s):
$staleLines

Disable this check: env ``CLAUDE_SKIP_FRESHNESS_CHECK=1``.
"@
        }
    }
}

# --- 2. Session-agent invocation directive ----------------------------------
$saBlock = ''
if ($env:CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE -ne '1') {
    $saBlock = @"


## Session-agent — invoke now (Mode 1: kickoff orient)

The ``/session-agent`` skill is the spine. **Your first action this session
must be to invoke ``/session-agent``** — Mode 1 fires the kickoff orient
(memory body-reads + Linear projects-first query + vault ``START.md`` +
reconcile this session-start window's commits against memory headlines), then
routes the user's first request.

On every subsequent non-trivial prompt, re-invoke ``/session-agent`` (Mode 2:
route only — Mode 1's orient outputs are still live in context).

Skip this directive if you have already invoked session-agent this session.
Disable the directive entirely: env ``CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1``.
"@
}

if (-not $gitBlock -and -not $freshBlock -and -not $saBlock) { exit 0 }

$context = "$gitBlock$freshBlock$saBlock"
@{ context = $context } | ConvertTo-Json -Compress
exit 0
