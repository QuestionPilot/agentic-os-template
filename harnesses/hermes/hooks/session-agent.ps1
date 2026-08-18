#Requires -Version 7
# Session-agent enforcement hook (Hermes pre_tool_call event,
# matcher write_file|patch|terminal) — Windows twin of session-agent.sh.
# Blocks the first file-modifying tool use of a session unless the
# session-agent capability ran and a complete routing declaration exists —
# BOTH the `Linear gate:` line (active-work disposition) and the `Lessons:`
# line (recall outcome: matched lesson names, `none match`, or `index
# unreachable`).
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

# 1. The gate-declaration write itself is allowed through — line-anchored,
#    case-SENSITIVE (-cmatch; -like is case-insensitive and was a Windows-only
#    false-allow vs the bash twin — panel finding), non-empty value required.
if ($tool -eq 'write_file') {
    $wpath = [string]$evt.tool_input.path
    $wcontent = [string]$evt.tool_input.content
    # Spelling-robust equality: on Windows the model may legitimately spell the
    # gate path with forward slashes (the deny message prints the backslash
    # form, but write_file accepts either), and a bare -eq would bounce that
    # write. GetFullPath normalizes separators/relative segments; -eq stays
    # case-insensitive per PS string semantics — matching NTFS. Fall back to
    # the plain compare on malformed paths. (The bash twin needs no
    # equivalent: POSIX paths have a single separator spelling.)
    $wpathEq = $false
    if ($wpath) {
        if ([IO.Path]::IsPathFullyQualified($wpath)) {
            # Trailing separators trimmed: GetFullPath preserves them, and
            # "<dir>\" names the same file target as "<dir>".
            try { $wpathEq = (([IO.Path]::GetFullPath($wpath).TrimEnd('\', '/')) -eq ([IO.Path]::GetFullPath($gateFile).TrimEnd('\', '/'))) }
            catch { $wpathEq = ($wpath -eq $gateFile) }
        } else {
            # A RELATIVE write path resolves against the TOOL's cwd, not this
            # hook process's — normalizing it here could equate it with the
            # gate file while the tool writes somewhere else entirely (panel
            # finding). Keep the plain compare; the deny message names the
            # absolute gate path, so the model writes that exact spelling.
            $wpathEq = ($wpath -eq $gateFile)
        }
    }
    if ($wpathEq) {
        if (($wcontent -cmatch '(?m)^\s*Linear gate:[ \t]*\S') -and
            ($wcontent -cmatch '(?m)^\s*Lessons:[ \t]*\S')) { exit 0 }
        Block 'The gate file must carry the routing declaration — include the full `Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted` line AND the `Lessons: <matched lesson names> | none match | index unreachable | skipped — <reason>` line in its content.'
    }
}

# 2. Gate already declared this session (marker on disk, both contract lines,
#    same line-anchored case-sensitive non-empty match as the write path).
if (Test-Path -LiteralPath $gateFile) {
    $gateContent = Get-Content -LiteralPath $gateFile -Raw
    if (($gateContent -cmatch '(?m)^\s*Linear gate:[ \t]*\S') -and
        ($gateContent -cmatch '(?m)^\s*Lessons:[ \t]*\S')) {
        exit 0
    }
}

# 3. state.db backstop — read-only; any failure falls through to the block.
# Role-filtered + line-anchored (parity with the bash twin): an any-row LIKE
# was vacuous — the skill body alone (one tool/user row carrying both
# the SKILL.md path and the `Linear gate:` template lines) satisfied both
# patterns, and a prior deny from this very hook quotes the phrase too. The
# ran-marker accepts user- or assistant-authored rows; the declaration must be
# ASSISTANT rows with `Linear gate:` AND `Lessons:` at line start
# (start-of-content or after a newline; the two lines may land in different
# rows).
$db = Join-Path $hhome 'state.db'
$sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
if ($sqlite -and (Test-Path -LiteralPath $db)) {
    $sid = $sessionId -replace "'", "''"
    # case_sensitive_like: SQLite LIKE is case-insensitive for ASCII by
    # default — pin it case-sensitive for cross-harness parity (bash twin does
    # the same). The PRAGMA emits no row, so the SELECT's value is the last line.
    $sql = "PRAGMA case_sensitive_like=ON; SELECT (SELECT COUNT(*) FROM messages WHERE session_id='$sid' AND role IN ('user','assistant') AND (COALESCE(content,'') LIKE '%skills/session-agent/SKILL.md%' OR COALESCE(tool_calls,'') LIKE '%skills/session-agent/SKILL.md%')) > 0 AND (SELECT COUNT(*) FROM messages WHERE session_id='$sid' AND role='assistant' AND (COALESCE(content,'') LIKE 'Linear gate:%' OR COALESCE(content,'') LIKE '%'||char(10)||'Linear gate:%')) > 0 AND (SELECT COUNT(*) FROM messages WHERE session_id='$sid' AND role='assistant' AND (COALESCE(content,'') LIKE 'Lessons:%' OR COALESCE(content,'') LIKE '%'||char(10)||'Lessons:%')) > 0;"
    $hit = @(& sqlite3 -readonly $db $sql 2>$null) | Select-Object -Last 1
    if ("$hit" -eq '1') { exit 0 }
}

Block "First file-modifying tool use detected but the session-agent gate is not open for this session. Invoke /session-agent to walk the kickoff orient (Mode 1) then route the request (R1-R5, including the R1a lesson recall), and declare the gate by writing the file $gateFile via the write_file tool with the full routing declaration including the ``Linear gate:`` and ``Lessons:`` lines as its content. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
