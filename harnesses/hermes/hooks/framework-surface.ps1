#Requires -Version 7
# Framework-changes surfacing hook (Hermes pre_llm_call event, first turn only)
# — Windows twin of framework-surface.sh. Surfaces recent agentic-os-template
# commits, a config-freshness nudge, and the session-agent auto-fire directive
# as Hermes context injection ({"context": "..."}).
#
# Wired to pre_llm_call (NOT on_session_start, whose {"context":...} return
# Hermes discards). pre_llm_call fires before every model call, so this hook
# self-gates to the first turn via .extra.is_first_turn. See adapter.md Fact 2.
#
# Kill switches (same env names as the bash twin / other harnesses):
#   CLAUDE_SKIP_FRAMEWORK_SURFACE=1, CLAUDE_SKIP_FRESHNESS_CHECK=1,
#   CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1, CLAUDE_FRAMEWORK_SINCE_DAYS=N
#
# stdin:  pre_llm_call event JSON — .session_id, .cwd, .extra.is_first_turn
# stdout: on the first turn only, {"context": "..."}; silent on later turns
# exit:   always 0 (fail-open; surfacing hook)

$ErrorActionPreference = 'SilentlyContinue'

if ($env:CLAUDE_SKIP_FRAMEWORK_SURFACE -eq '1') { exit 0 }

$AI_CONFIG_DIR = '@@AI_CONFIG_DIR@@'
$days = if ($env:CLAUDE_FRAMEWORK_SINCE_DAYS) { $env:CLAUDE_FRAMEWORK_SINCE_DAYS } else { '10' }

# Read stdin — the event JSON carries session_id, which the model cannot see
# anywhere else and needs to name its per-session gate file (the edit-gate's
# declaration channel — see hooks/session-agent.ps1).
$inputRaw = [Console]::In.ReadToEnd()
$sessionId = ''
try { $sessionId = [string](($inputRaw | ConvertFrom-Json).session_id) } catch { }

# --- First-turn gate --------------------------------------------------------
# pre_llm_call fires before EVERY model call, so surface ONLY on the first turn.
# Primary signal: .extra.is_first_turn (a JSON boolean → 'True'/'False' once
# stringified). Fallback when the signal is absent (defensive): a per-session
# sentinel so the directive is never injected twice. Mirrors framework-surface.sh.
$isFirst = 'absent'
try {
    $obj = $inputRaw | ConvertFrom-Json
    if ($null -ne $obj.extra -and ($obj.extra.PSObject.Properties.Name -contains 'is_first_turn')) {
        $isFirst = [string]$obj.extra.is_first_turn
    } elseif ($obj.PSObject.Properties.Name -contains 'is_first_turn') {
        $isFirst = [string]$obj.is_first_turn
    }
} catch { }

$sentinel = ''
if ($isFirst -ieq 'false') {
    exit 0
} elseif ($isFirst -ine 'true') {
    # No reliable first-turn signal → dedup via a per-session sentinel. Without a
    # session id we cannot dedup, so fail SAFE (stay silent) rather than re-inject
    # the directive on every model call. Mirrors framework-surface.sh.
    $gateDir = Split-Path -Parent $PSScriptRoot
    if (-not $gateDir -or -not $sessionId) { exit 0 }
    $sentinel = Join-Path $gateDir 'agentic-os' "surfaced-$sessionId"
    if (Test-Path -LiteralPath $sentinel) { exit 0 }
}

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
        # Resolve the running pwsh from $PID (the claude/codex twins already do
        # this) instead of a bare `& pwsh` that relies on PATH — on Windows
        # pwsh.exe is often absent from PATH, so the freshness probe would
        # silently never run. Fail-open: fall back to the PATH name.
        $pwshExe = try { (Get-Process -Id $PID).Path } catch { $null }
        if (-not $pwshExe) { $pwshExe = 'pwsh' }
        $staleList = & $pwshExe -NoProfile -File $freshnessScript -Manifest $installDir -List 2>$null
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
    # Surface the per-session gate path: the edit-gate hook keys on session_id,
    # which the model cannot discover on its own.
    if ($sessionId) {
        $installDirSa = Split-Path -Parent $PSScriptRoot
        if ($installDirSa) {
            $gatePath = Join-Path $installDirSa 'agentic-os' "gate-$sessionId"
            $saBlock += @"


After the R5 routing declaration, open the edit-gate by writing the file
``$gatePath`` via the write_file tool with the full declaration (including the
``Linear gate:`` line) as its content.
"@
        }
    }
}

if (-not $gitBlock -and -not $freshBlock -and -not $saBlock) { exit 0 }

# Sentinel dedup applies only when the first-turn signal was absent (above);
# mark this session surfaced so a later turn stays silent. Best-effort.
if ($sentinel) {
    try {
        $sdir = Split-Path -Parent $sentinel
        if (-not (Test-Path -LiteralPath $sdir)) { New-Item -ItemType Directory -Force -Path $sdir | Out-Null }
        Set-Content -LiteralPath $sentinel -Value '' -NoNewline
    } catch { }
}

$context = "$gitBlock$freshBlock$saBlock"
@{ context = $context } | ConvertTo-Json -Compress
exit 0
