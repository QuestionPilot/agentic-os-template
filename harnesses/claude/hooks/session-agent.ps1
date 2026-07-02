#Requires -Version 7
<#
.SYNOPSIS
    Session-agent enforcement hook (Claude Code PreToolUse for
    Write|Edit|NotebookEdit) — PowerShell port.

.DESCRIPTION
    <TEAM>-100 Windows-native prototype port of harnesses/claude/hooks/session-agent.sh.

    Blocks the tool use if the session-agent capability was not invoked
    earlier in the session. This hook is the SAFETY NET — primary auto-fire
    is the SessionStart directive emitted by framework-surface.ps1.

    Enforcement class: pre-edit-gate (see harnesses/claude/adapter.md).
    Kill switch: set $env:CLAUDE_SKIP_SESSION_AGENT=1 to disable.

    stdin:  PreToolUse hook event JSON
    stdout: when blocking, a PreToolUse deny decision (hookSpecificOutput JSON)
    exit:   always 0

    Declaration channels (<TEAM>-365): the desktop/SDK harness variant does
    NOT persist turn-final assistant text blocks into the transcript file, so
    the assistant-text check alone false-denies there. Two channels open the
    gate, either is sufficient:
      1. GATE MARKER — the model persists its R5 routing declaration by
         writing `<install>/agentic-os/gate-<session_id>`. The marker write
         itself is allowed through pre-gate via a structured-field match
         (exact per-session path + line-anchored `Linear gate:` content).
      2. TRANSCRIPT — assistant-authored text block carrying the
         line-anchored declaration (CLI variant; unchanged from <TEAM>-360).
    Both channels require the session-agent Skill invocation in the
    transcript first — tool_use records persist reliably on ALL known
    variants.

.NOTES
    Decision shape: a PreToolUse block uses hookSpecificOutput.permissionDecision
    ("deny") — the documented, version-stable block channel for this event. The
    legacy top-level {"decision":"block","reason":...} form is NOT a reliable
    PreToolUse block: that top-level shape is the documented control for
    UserPromptSubmit/PostToolUse/Stop/SubagentStop/PreCompact, and on PreToolUse
    it does not deny the tool call (verified: the edit proceeds — the gate is
    silently a no-op). We emit permissionDecision:"deny" instead, byte-equivalent
    to the bash twin (both build the JSON through `jq -nc`).
#>

$ErrorActionPreference = 'Continue'

# Deny — emit a Claude Code PreToolUse deny decision via jq for safe escaping
# of the reason string, then exit 0. Byte-equivalent to the bash twin's deny().
# jq is guaranteed present (by the Get-Command contract check below) before any
# call site is reached, but a jq that passes Get-Command can still fail AT
# RUNTIME. If the construction emits nothing, fall back to a static deny string
# so the gate still fails CLOSED — never silently allow.
function Deny {
    param([Parameter(Mandatory)][string]$Reason)
    $jsonOut = & jq -nc --arg r $Reason `
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' 2>$null
    if ($jsonOut) {
        Write-Output $jsonOut
    } else {
        Write-Output '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Session-agent enforcement gate is denying this edit but could not render its reason (jq failed at runtime). The gate fails closed. Re-run after invoking session-agent, or set env CLAUDE_SKIP_SESSION_AGENT=1 to bypass."}}'
    }
    exit 0
}

if ($env:CLAUDE_SKIP_SESSION_AGENT -eq '1') {
    exit 0
}

# jq contract — gate hook fails CLOSED: without jq the transcript cannot
# be parsed and the session-agent check cannot be made. Deny needs jq, so the
# fail-closed path emits the PreToolUse deny shape as a static string (fixed
# literal — no interpolation, so no escaping concern; parity with bash twin).
if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    Write-Output '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Session-agent enforcement hook cannot run: `jq` was not found on the hook PATH. The gate fails closed. Install jq, or set env CLAUDE_SKIP_SESSION_AGENT=1 to bypass enforcement."}}'
    exit 0
}

$INPUT_JSON = [Console]::In.ReadToEnd()
if (-not $INPUT_JSON) { exit 0 }

$TRANSCRIPT = $INPUT_JSON | & jq -r '.transcript_path // empty'
$TOOL_NAME  = $INPUT_JSON | & jq -r '.tool_name // empty'
$SESSION_ID = $INPUT_JSON | & jq -r '.session_id // empty'
if (-not $TRANSCRIPT -or -not (Test-Path -LiteralPath $TRANSCRIPT -PathType Leaf)) {
    exit 0
}

# Read raw transcript content; Select-String with -Pattern matches per-line.
$transcriptContent = [System.IO.File]::ReadAllText($TRANSCRIPT)

# Session-agent invocation present? Safe as a whole-transcript match: the
# unescaped Skill tool_use JSON only appears in a real invocation record —
# anywhere the same text is quoted inside a string (the skill body citing its
# own marker, a tool result) the quotes are JSON-escaped (\"skill\") and this
# pattern cannot match. This check gates BOTH declaration channels below — the
# marker file alone never opens the gate.
if ($transcriptContent -notmatch '"skill"\s*:\s*"session-agent"') {
    Deny 'First file-modifying tool use detected but the session-agent capability has not been invoked this session. Invoke `session-agent` via the Skill tool to walk the kickoff orient (Mode 1) then route the request. One invocation per session for Mode 1; re-invoke for each subsequent non-trivial prompt (Mode 2). Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1.'
}

# Channel 1 — gate marker (<TEAM>-365). Keyed strictly to the event's
# session_id: sanitized to a path-safe alphabet (letters/digits/hyphen — a
# superset of UUIDs) so a hostile/garbled id cannot
# path-escape the state dir (an id that fails the check just disables this
# channel — the transcript channel still applies). The install dir is this
# hook's own parent (hooks live at <install>/hooks/).
$GATE_FILE = ''
# Whitespace-tolerant capture (panel finding): parity with the directive's
# trimmed id — a padded id must not publish one path and check another.
if ($SESSION_ID -cmatch '^\s*([A-Za-z0-9-]+)\s*$') {
    $SESSION_ID = $Matches[1]
    $saInstallDir = Split-Path -Parent $PSScriptRoot
    if ($saInstallDir) {
        $stateDir  = Join-Path $saInstallDir 'agentic-os'
        $GATE_FILE = Join-Path $stateDir "gate-$SESSION_ID"
        # Reap stale markers (old sessions); never fails the hook.
        try {
            Get-ChildItem -LiteralPath $stateDir -Filter 'gate-*' -File -ErrorAction Stop |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}

if ($GATE_FILE) {
    # 1a. The marker write itself is allowed through pre-gate: a Write to the
    #     exact per-session path whose content carries the line-anchored
    #     declaration. Structured-field match on the CURRENT event only — never
    #     a transcript grep, so tool_use fixture noise (the skill body's own
    #     template lines quoted inside other tool inputs) cannot satisfy it.
    if ($TOOL_NAME -eq 'Write') {
        $wPath = $INPUT_JSON | & jq -r '.tool_input.file_path // empty'
        # Separator-normalized compare (panel finding): on the Windows lane the
        # model may Write with forward slashes while Join-Path builds backslashes;
        # a raw -eq would false-deny the marker write.
        if (($wPath -replace '\\','/') -eq ($GATE_FILE -replace '\\','/')) {
            $wContent = ($INPUT_JSON | & jq -r '.tool_input.content // empty' 2>$null) -join "`n"
            if ($wContent -cmatch '(?m)^\s*Linear gate:[ \t]*\S') {
                exit 0
            }
            Deny 'The gate marker file must carry the routing declaration — include the full `Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted` line in its content, then retry.'
        }
    }
    # 1b. Marker already on disk with a line-anchored declaration → gate open.
    if (Test-Path -LiteralPath $GATE_FILE -PathType Leaf) {
        $markerContent = [System.IO.File]::ReadAllText($GATE_FILE)
        if ($markerContent -cmatch '(?m)^\s*Linear gate:[ \t]*\S') {
            exit 0
        }
    }
}

# Channel 2 — transcript. session-agent ran; confirm the Linear gate was
# declared BY THE ASSISTANT. A whole-transcript match is vacuous here: the
# skill body carries its own `Linear gate:` template lines (injected into the
# transcript the moment the skill loads) and a prior deny from this very hook
# quotes the phrase — so the gate would open as soon as it was explained,
# never enforcing the declaration. Parse the transcript records via jq (same
# filter as the bash twin): keep only assistant-authored text blocks
# (skill-body injection and deny text land in user/tool_result records) and
# require the declaration at line start.
$assistantText = & jq -rR '
    fromjson?
    | select(.type == "assistant")
    | .message.content
    | if type == "string" then .
      elif type == "array" then (.[]? | select(.type == "text") | .text // empty)
      else empty end
  ' $TRANSCRIPT 2>$null
# -cmatch: case-SENSITIVE, matching the bash twin's grep (a plain -match is
# case-insensitive and would open the gate on `linear gate:` only on Windows).
if ((@($assistantText) -join "`n") -cmatch '(?m)^\s*Linear gate:') {
    exit 0
}

# session-agent ran but no Linear-gate declaration reached either channel.
$denyMsg = 'The session-agent capability ran but no `Linear gate:` declaration was found this session. Re-run the routing steps (R1–R5) and emit the full declaration including the `Linear gate:` line. If the task is multi-step or multi-session, a Linear issue/project must exist first.'
if ($GATE_FILE) {
    $denyMsg += " If you HAVE already declared and this deny persists, this harness variant does not persist assistant text into the transcript — persist the declaration to the gate marker instead: write the routing declaration (including the ``Linear gate:`` line) to $GATE_FILE (the Write tool call to that exact path is allowed through this gate; a Bash heredoc works too)."
}
Deny "$denyMsg Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1."
