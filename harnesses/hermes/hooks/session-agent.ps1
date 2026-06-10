#Requires -Version 7
# Session-agent enforcement hook (Hermes pre_tool_call event,
# matcher write_file|patch|terminal) — Windows twin of session-agent.sh.
# Blocks the first file-modifying tool use of a session unless the
# session-agent capability ran and a `Linear gate:` declaration exists.
#
# Enforcement class: pre-edit-gate (see harnesses/hermes/adapter.md).
# Kill switch: CLAUDE_SKIP_SESSION_AGENT=1 (same env name as other harnesses).
#
# Detection mirrors the bash twin: (1) the per-session GATE FILE written via
# write_file (the declaration write itself is allowed through on a
# structured-field match); (2) a read-only state.db query as the multi-turn
# backstop when sqlite3 is available (commonly absent on Windows — the gate
# file is the primary channel there).
#
# stdout: when blocking, {"decision":"block","reason":"..."} — Hermes parses
#         the Claude-Code-style legacy shape natively.
# exit:   always 0

$ErrorActionPreference = 'SilentlyContinue'

if ($env:CLAUDE_SKIP_SESSION_AGENT -eq '1') { exit 0 }

function Block([string]$Reason) {
    @{ decision = 'block'; reason = $Reason } | ConvertTo-Json -Compress
    exit 0
}

$inputRaw = [Console]::In.ReadToEnd()
try { $evt = $inputRaw | ConvertFrom-Json } catch { exit 0 }

$sessionId = [string]$evt.session_id
$tool = [string]$evt.tool_name

# No session id → synthetic payload (`hermes hooks test`); stay silent.
if (-not $sessionId) { exit 0 }

# HERMES_HOME resolution: hooks are installed at <HERMES_HOME>/hooks/, so the
# script's own parent is the authoritative home; env is the fallback.
$hhome = Split-Path -Parent $PSScriptRoot
if (-not $hhome) {
    $hhome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $HOME '.hermes' }
}
$stateDir = Join-Path $hhome 'agentic-os'
$gateFile = Join-Path $stateDir "gate-$sessionId"

# Reap stale gate markers (old sessions); never fails the hook.
if (Test-Path -LiteralPath $stateDir) {
    Get-ChildItem -LiteralPath $stateDir -Filter 'gate-*' |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# 1. The gate-declaration write itself is allowed through.
if ($tool -eq 'write_file') {
    $wpath = [string]$evt.tool_input.path
    $wcontent = [string]$evt.tool_input.content
    if ($wpath -eq $gateFile) {
        if ($wcontent -like '*Linear gate:*') { exit 0 }
        Block 'The gate file must carry the routing declaration — include the full `Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted` line in its content.'
    }
}

# 2. Gate already declared this session (marker on disk).
if ((Test-Path -LiteralPath $gateFile) -and
    ((Get-Content -LiteralPath $gateFile -Raw) -like '*Linear gate:*')) {
    exit 0
}

# 3. state.db backstop — read-only; any failure falls through to the block.
$db = Join-Path $hhome 'state.db'
$sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
if ($sqlite -and (Test-Path -LiteralPath $db)) {
    $sid = $sessionId -replace "'", "''"
    $sql = "SELECT (SELECT COUNT(*) FROM messages WHERE session_id='$sid' AND content LIKE '%skills/session-agent/SKILL.md%') > 0 AND (SELECT COUNT(*) FROM messages WHERE session_id='$sid' AND content LIKE '%Linear gate:%') > 0;"
    $hit = & sqlite3 -readonly $db $sql 2>$null
    if ("$hit" -eq '1') { exit 0 }
}

Block "First file-modifying tool use detected but the session-agent gate is not open for this session. Invoke /session-agent to walk the kickoff orient (Mode 1) then route the request (R1-R5), and declare the gate by writing the file $gateFile via the write_file tool with the full routing declaration including the ``Linear gate:`` line as its content. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
