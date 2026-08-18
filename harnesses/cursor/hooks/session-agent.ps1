#Requires -Version 7
# Session-agent enforcement hook (Cursor preToolUse event, matcher Write)
# — Windows twin of session-agent.sh.
# Blocks the first file-modifying tool use of a conversation unless the
# session-agent capability ran and a complete routing declaration exists —
# BOTH the `Linear gate:` line (active-work disposition) and the `Lessons:`
# line (recall outcome: matched lesson names, `none match`, or `index
# unreachable`).
#
# Enforcement class: pre-edit-gate (see harnesses/cursor/adapter.md).
# Kill switch: CLAUDE_SKIP_SESSION_AGENT=1 (same env name as other harnesses).
#
# CURSOR FAIL-OPEN CONTRACT — read before editing:
#   Cursor treats exit 0 as "use the JSON", exit 2 as a hard block, and any
#   OTHER exit code as a hook failure whose action PROCEEDS (fail-open). The
#   generated hooks.json entry sets "failClosed": true, and THIS SCRIPT denies
#   on every error path of its own. Never exit silently from an error branch.
#   `permission: "ask"` is schema-accepted but NOT enforced on preToolUse —
#   never emit it; `deny` is the only reliable block.
#
# Detection mirrors the bash twin: the per-conversation GATE FILE at
# <config>/agentic-os/gate-<conversation_id>. A transcript-parsing channel is
# possible (preToolUse carries transcript_path) but the gate file is the marker
# three harnesses already share; the `Shell` tool is outside the matcher and is
# the documented fallback for writing the marker.
#
# stdout: {"permission":"allow"} or {"permission":"deny", user_message,
#         agent_message}
# exit:   always 0 (the JSON carries the decision)

$ErrorActionPreference = 'SilentlyContinue'

function Allow {
    @{ permission = 'allow' } | ConvertTo-Json -Compress
    exit 0
}

function Deny([string]$Reason) {
    @{
        permission    = 'deny'
        user_message  = 'agentic-os session-agent gate: blocked (see the agent message for the fix).'
        agent_message = $Reason
    } | ConvertTo-Json -Compress
    exit 0
}

if ($env:CLAUDE_SKIP_SESSION_AGENT -eq '1') { Allow }

$inputRaw = [Console]::In.ReadToEnd()
$evt = $null
try { $evt = $inputRaw | ConvertFrom-Json } catch { $evt = $null }
if ($null -eq $evt) {
    Deny 'The session-agent enforcement hook could not parse its preToolUse payload as JSON. The gate fails closed. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1.'
}

# `conversation_id` is the stable per-conversation id (sessionStart calls the
# same value `session_id`); accept either spelling so the marker key is
# identical no matter which field a given Cursor build populates.
$convId = [string]$evt.conversation_id
if (-not $convId) { $convId = [string]$evt.session_id }
$tool = [string]$evt.tool_name

if (-not $convId) {
    Deny 'The session-agent enforcement hook found no conversation_id in the preToolUse payload, so it cannot key the per-conversation gate marker. The gate fails closed. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1.'
}

# The id is interpolated into a filesystem path below — refuse any separator or
# dot-segment so a hostile/degenerate id cannot escape the state dir.
if ($convId -match '[/\\]' -or $convId -eq '.' -or $convId -eq '..') {
    Deny 'The session-agent enforcement hook refuses a conversation_id containing a path separator. The gate fails closed. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1.'
}

# Config-home resolution: hooks are installed at <config>\hooks\, so the
# script's own parent is the authoritative home; env is the fallback. (Cursor's
# own CLI reads CURSOR_CONFIG_DIR for cli-config.json relocation; the framework
# build target uses the same variable by design — adapter.md.)
$chome = Split-Path -Parent $PSScriptRoot
if (-not $chome) {
    $chome = if ($env:CURSOR_CONFIG_DIR) { $env:CURSOR_CONFIG_DIR } else { Join-Path $HOME '.cursor' }
}
$stateDir = Join-Path $chome 'agentic-os'
$gateFile = Join-Path $stateDir "gate-$convId"

# Reap stale gate markers (old conversations); never fails the hook.
if (Test-Path -LiteralPath $stateDir) {
    Get-ChildItem -LiteralPath $stateDir -Filter 'gate-*' |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# 1. Gate already declared for this conversation (marker on disk, both contract
#    lines — line-anchored, case-SENSITIVE (-cmatch; -like/-match are
#    case-insensitive and would be a Windows-only false-allow vs the bash
#    twin), non-empty value after the colon).
if (Test-Path -LiteralPath $gateFile) {
    $gateContent = Get-Content -LiteralPath $gateFile -Raw
    if (($gateContent -cmatch '(?m)^\s*Linear gate:[ \t]*\S') -and
        ($gateContent -cmatch '(?m)^\s*Lessons:[ \t]*\S')) {
        Allow
    }
}

# 2. The gate-declaration write itself is allowed through.
#
#    A Write call carries tool_input.file_path + tool_input.content
#    (live-verified 2026-08-18), but Cursor's docs specify tool_input only for
#    the Shell tool, so the shape is not contractual. Rather than depend on
#    those two keys, sweep EVERY string value in tool_input: a call is a
#    gate-declaration write when some string carries the gate path, and the
#    declaration lines are sought across the joined strings.
if ($tool -eq 'Write') {
    $strings = New-Object System.Collections.Generic.List[string]
    function Add-Strings($node, [int]$depth) {
        if ($depth -gt 12 -or $null -eq $node) { return }
        if ($node -is [string]) { $strings.Add($node); return }
        if ($node -is [System.Collections.IEnumerable]) {
            foreach ($item in $node) { Add-Strings $item ($depth + 1) }
            return
        }
        if ($node -is [psobject] -and $node.PSObject.Properties) {
            foreach ($p in $node.PSObject.Properties) { Add-Strings $p.Value ($depth + 1) }
        }
    }
    Add-Strings $evt.tool_input 0
    $joined = ($strings -join "`n")
    # Separator-tolerant path match: on Windows the model may spell the gate
    # path with forward slashes. Compare on a normalized copy of both sides.
    $gateNorm = $gateFile -replace '\\', '/'
    $joinedNorm = $joined -replace '\\', '/'
    if ($joined -and $joinedNorm.Contains($gateNorm)) {
        if (($joined -cmatch '(?m)^\s*Linear gate:[ \t]*\S') -and
            ($joined -cmatch '(?m)^\s*Lessons:[ \t]*\S')) {
            Allow
        }
        Deny 'The gate file must carry the routing declaration — include the full `Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted` line AND the `Lessons: <matched lesson names> | none match | index unreachable | skipped — <reason>` line in its content. If this write already contained both lines, Cursor''s Write tool payload did not expose them to the hook: write the marker with the `Shell` tool instead (Shell is outside this gate''s matcher).'
    }
}

Deny "First file-modifying tool use detected but the session-agent gate is not open for this conversation. Invoke /session-agent to walk the kickoff orient (Mode 1) then route the request (R1-R5, including the R1a lesson recall), and declare the gate by writing the file $gateFile with the full routing declaration including the ``Linear gate:`` and ``Lessons:`` lines as its content. If the Write tool payload does not carry the content through, use the ``Shell`` tool — it is outside this gate's matcher. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
