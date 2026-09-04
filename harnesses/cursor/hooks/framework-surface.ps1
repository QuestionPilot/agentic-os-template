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

    SIDE EFFECT — the conversation-id side file. When the payload carries a
    usable id, the hook also writes it (one line, trailing LF) to
    <config>/agentic-os/current-session, so a model that lost the injected
    directive can re-read the id instead of spending a sacrificial deny to
    discover it. Two properties a reader must know:
      - it is PER CONFIG HOME, not per conversation;
      - it is LAST-WRITER-WINS — two conversations started under one Cursor
        config home overwrite each other, so the file means "the most recently
        started conversation", nothing stronger. When a gate deny names a
        different marker path than this file implies, the DENY wins: it was
        keyed on the payload of the call that was actually blocked.
    Every failure on this path is swallowed — a fail-OPEN surfacing hook must
    never change its exit or stdout because a state write failed. What the
    failure DOES change is the directive: the sentence naming the side file is
    emitted only after the write really landed, so the hook never points the
    model at a path holding a stale id or nothing at all.

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
$sessionId = ''
try {
    $evt = $inputRaw | ConvertFrom-Json
    if ($evt) {
        $composerMode = [string]$evt.composer_mode
        # The sessionStart payload carries `session_id` — the SAME value
        # preToolUse calls `conversation_id`, which the gate marker is keyed on.
        # Read it so the directive can name the EXACT marker path instead of a
        # `<conversation_id>` placeholder the model has to guess at (parity with
        # the bash twin; cross-model panel finding).
        $sessionId = [string]$evt.session_id
        if (-not $sessionId) { $sessionId = [string]$evt.conversation_id }
    }
} catch { $composerMode = ''; $sessionId = '' }

# Reject on the same grounds the gate hook rejects an id — a separator,
# whitespace, or a non-printable byte never forms a usable marker path, so fall
# back to the placeholder rather than printing a broken one.
if ($sessionId -match '[/\\]' -or $sessionId -match '\s' -or
    $sessionId -match '[^\p{L}\p{N}\p{P}\p{S}]' -or
    $sessionId -eq '.' -or $sessionId -eq '..') {
    $sessionId = ''
}
$sideFile = "$chome/agentic-os/current-session"
$sideWritten = $false
if ($sessionId) {
    $gateHint = "$chome/agentic-os/gate-$sessionId"
    $gateHintNote = ''
    # Publish the id to the side file (see the SIDE EFFECT note in the header).
    # Temp-file-then-move within the same directory so a reader never observes a
    # half-written id. WriteAllText with a BOM-less UTF8Encoding + an explicit
    # "`n" keeps the bytes LF/no-BOM identical to the bash twin's `printf`
    # (per [[reference_ps_port_traps]] trap #3 — Set-Content would emit CRLF).
    # Wrapped whole: no failure here may change the hook's exit or stdout.
    #
    # $sideWritten flips ONLY after Move-Item and a Test-Path on the DESTINATION
    # confirm the file is really there — Move-Item runs under
    # -ErrorAction SilentlyContinue, so its failure is otherwise invisible. The
    # directive below is gated on it: telling the model "re-read the id from
    # <path>" when the write was swallowed would send it to a stale id (another
    # conversation's) or to a file that does not exist.
    try {
        $stateDir = Join-Path $chome 'agentic-os'
        if (-not (Test-Path -LiteralPath $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $sidTmp = Join-Path $stateDir ('.current-session.' + $PID)
        $sidDest = Join-Path $stateDir 'current-session'
        [System.IO.File]::WriteAllText($sidTmp, "$sessionId`n", [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $sidTmp -Destination $sidDest -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $sidTmp) {
            Remove-Item -LiteralPath $sidTmp -Force -ErrorAction SilentlyContinue
        } elseif (Test-Path -LiteralPath $sidDest) {
            $sideWritten = $true
        }
    } catch { }
} else {
    $gateHint = "$chome/agentic-os/gate-<conversation_id>"
    $gateHintNote = " — substituting this conversation's id"
}

# The side-file sentence is emitted only when there really is a side file
# carrying THIS conversation's id — never on the placeholder branch, never after
# a swallowed write failure. (A here-string drops the newline before its closing
# terminator, so this matches the bash twin's SIDE_NOTE byte for byte.)
$sideNote = ''
if ($sideWritten) {
    $sideNote = @"
 If you lose this conversation's id, re-read it from
``$sideFile`` — this hook wrote it there at session start (last-writer-wins
across concurrent conversations in this config home, so trust the gate deny's
path over it).
"@
}

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
        # Bound the child at 5s — parity with the bash twin's `timeout 5`. A
        # stalled manifest scan (locked file, antivirus, slow filesystem) must
        # not wedge sessionStart. System.Diagnostics.Process + Kill($true)
        # tree-kills on timeout (Stop-Job orphans grandchild pwsh processes).
        # Any failure or timeout leaves rc=2 (indeterminate) — fail-open.
        $staleList = @(); $freshRc = 2
        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = 'pwsh'
            foreach ($a in @('-NoProfile', '-File', $freshnessScript, '-Manifest', $installDir, '-List')) {
                $psi.ArgumentList.Add($a)
            }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $proc = [System.Diagnostics.Process]::Start($psi)
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
            if ($proc.WaitForExit(5000)) {
                $freshRc = $proc.ExitCode
                $staleList = @($outTask.Result -split "`r?`n" | Where-Object { $_ })
            } else {
                try { $proc.Kill($true) } catch {}
            }
        } catch {}
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
``$gateHint``$gateHintNote. The realization body in the capability spells out
the contract.$sideNote

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
