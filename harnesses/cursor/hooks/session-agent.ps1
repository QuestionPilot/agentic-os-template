#Requires -Version 7
# Session-agent enforcement hook (Cursor preToolUse event, matcher Write|Delete)
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

# SilentlyContinue keeps a non-terminating error from killing the hook mid-way
# (which would exit 0 with empty stdout = fail-OPEN on Cursor). Every branch
# below still ends in an explicit Allow or Deny, and both emit through guarded
# helpers, so no path can reach the end of the script silently.
$ErrorActionPreference = 'SilentlyContinue'

# Config-home resolution: hooks are installed at <config>\hooks\, so the
# script's own parent is the authoritative home; env is the fallback. (Cursor's
# own CLI reads CURSOR_CONFIG_DIR for cli-config.json relocation; the framework
# build target uses the same variable by design — adapter.md.)
#
# Resolved HERE, above every Deny branch, rather than after the id checks: it has
# no dependency on the payload, so it sits with the other payload-free setup.
# $script:GateFile stays empty until an id has been validated, and that emptiness
# — not the resolution order — is what Deny keys its two user_message shapes on.
# Parity with the bash twin.
$chome = Split-Path -Parent $PSScriptRoot
if (-not $chome) {
    $chome = if ($env:CURSOR_CONFIG_DIR) { $env:CURSOR_CONFIG_DIR } else { Join-Path $HOME '.cursor' }
}
$stateDir = Join-Path $chome 'agentic-os'
$script:GateFile = ''

# The last-resort deny, hand-written so it needs no serializer. Kept JSON-safe by
# construction: no double quotes, backslashes, or newlines inside the values.
$script:StaticDeny = '{"permission":"deny","user_message":"agentic-os session-agent gate: blocked and the hook could not encode its own reason.","agent_message":"The session-agent enforcement hook blocked this action but the JSON serializer failed while encoding the explanation. The gate fails closed. Open the gate by writing the per-conversation marker under the agentic-os state dir in your Cursor config home, or set env CLAUDE_SKIP_SESSION_AGENT=1 to bypass enforcement."}'

function Allow {
    # Static string, not ConvertTo-Json: an allow must never depend on the
    # serializer, and an empty stdout here would read as "no decision".
    Write-Output '{"permission":"allow"}'
    exit 0
}

function Deny([string]$Reason) {
    # The user_message is the half the OPERATOR sees, so it carries the one
    # thing that unblocks the session: the marker path in full once the
    # conversation id is known, and otherwise the CAUSE plus the kill switch —
    # a call with no usable id cannot be keyed by any marker, so naming a path
    # there would be a dead end (cross-model panel finding).
    #
    # FAIL-OPEN GUARD: on Cursor an exit 0 with EMPTY stdout is not a decision,
    # so the action proceeds. ConvertTo-Json can fail (depth, encoding, a
    # pathological reason string) and under SilentlyContinue that failure is
    # silent — emit the static deny instead of nothing.
    $um = if ($script:GateFile) {
        "agentic-os session-agent gate: blocked - open it by writing the routing declaration to $($script:GateFile) (see the agent message)."
    } else {
        'agentic-os session-agent gate: blocked - this call carried no usable conversation id, so no marker can key it; see the agent message (kill switch: env CLAUDE_SKIP_SESSION_AGENT=1).'
    }
    $json = $null
    try {
        $json = @{
            permission    = 'deny'
            user_message  = $um
            agent_message = $Reason
        } | ConvertTo-Json -Compress
    } catch { $json = $null }
    if ([string]::IsNullOrWhiteSpace($json)) { $json = $script:StaticDeny }
    Write-Output $json
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

# The id is interpolated into a filesystem path below. Refuse anything that
# could escape the state dir or break the matching this hook depends on:
# separators/dot-segments escape the directory; whitespace (a newline
# especially) breaks the composed gate path so the marker could never match;
# a non-printable byte is never a legitimate Cursor id. Parity with the bash
# twin's case guard (cross-model panel finding).
if ($convId -match '[/\\]' -or $convId -eq '.' -or $convId -eq '..') {
    Deny 'The session-agent enforcement hook refuses a conversation_id containing a path separator. The gate fails closed. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1.'
}
if ($convId -match '\s') {
    Deny 'The session-agent enforcement hook refuses a conversation_id containing whitespace - it cannot form a matchable gate-marker path. The gate fails closed. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1.'
}
if ($convId -match '[^\p{L}\p{N}\p{P}\p{S}]') {
    Deny 'The session-agent enforcement hook refuses a conversation_id containing non-printable characters. The gate fails closed. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1.'
}

# The id survived validation, so the marker path is composable — set it, which
# also switches Deny's user_message onto the path-naming shape above. ($chome /
# $stateDir were resolved at the top of the script, above the early denies.)
$gateFile = Join-Path $stateDir "gate-$convId"
$script:GateFile = $gateFile

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
#    the Shell tool, so the shape is not contractual. Hence two branches:
#
#    (a) file_path PRESENT — the destination is authoritative. Allow only when
#        it IS the gate file, then require both declaration lines in content. A
#        write to any other path is NOT a gate declaration no matter what its
#        body says, so it falls through to the deny below. This closes the
#        content-smuggling bypass a sweep-only check has.
#    (b) file_path ABSENT — unknown payload shape; fall back to the string
#        sweep, which degrades to a deny-with-explanation, never a silent allow.
$gateDeclMessage = 'The gate file must carry the routing declaration — include the full `Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted` line AND the `Lessons: <matched lesson names> | none match | index unreachable | skipped — <reason>` line in its content. If this write already contained both lines, Cursor''s Write tool payload did not expose them to the hook: write the marker with the `Shell` tool instead (Shell is outside this gate''s matcher).'

if ($tool -eq 'Write') {
    $hasFilePath = $false
    if ($null -ne $evt.tool_input -and $evt.tool_input.PSObject -and $evt.tool_input.PSObject.Properties) {
        $hasFilePath = ($evt.tool_input.PSObject.Properties.Name -contains 'file_path')
    }

    if ($hasFilePath) {
        # Separator-tolerant compare: on Windows the model may spell the gate
        # path with forward slashes; PS string compare is case-insensitive,
        # matching NTFS.
        $dest = [string]$evt.tool_input.file_path
        $destNorm = ($dest -replace '\\', '/').TrimEnd('/')
        $gateNorm = ($gateFile -replace '\\', '/').TrimEnd('/')
        if ($destNorm -eq $gateNorm) {
            $content = [string]$evt.tool_input.content
            if (($content -cmatch '(?m)^\s*Linear gate:[ \t]*\S') -and
                ($content -cmatch '(?m)^\s*Lessons:[ \t]*\S')) {
                Allow
            }
            Deny $gateDeclMessage
        }
        # A different destination is not a gate declaration — fall through to
        # the closing Deny, whatever its content claims.
    } else {
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
        $gateNorm = $gateFile -replace '\\', '/'
        $joinedNorm = $joined -replace '\\', '/'
        if ($joined -and $joinedNorm.Contains($gateNorm)) {
            if (($joined -cmatch '(?m)^\s*Linear gate:[ \t]*\S') -and
                ($joined -cmatch '(?m)^\s*Lessons:[ \t]*\S')) {
                Allow
            }
            Deny $gateDeclMessage
        }
    }
}

Deny "First file-modifying tool use detected but the session-agent gate is not open for this conversation. Invoke /session-agent to walk the kickoff orient (Mode 1) then route the request (R1-R5, including the R1a lesson recall), and declare the gate by writing the file $gateFile with the full routing declaration including the ``Linear gate:`` and ``Lessons:`` lines as its content. If the Write tool payload does not carry the content through, use the ``Shell`` tool — it is outside this gate's matcher. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
