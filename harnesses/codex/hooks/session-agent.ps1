#Requires -Version 7
<#
.SYNOPSIS
    Session-agent enforcement hook (Codex PreToolUse event, matcher
    apply_patch) — PowerShell port.

.DESCRIPTION
    <TEAM>-113 Windows-native port of harnesses/codex/hooks/session-agent.sh.

    Blocks the file edit if the session-agent capability was not invoked
    earlier in the session. SAFETY NET — primary auto-fire is via the
    SessionStart directive emitted by framework-surface.ps1.

    Enforcement class: pre-edit-gate (see harnesses/codex/adapter.md).
    Kill switch: set $env:CLAUDE_SKIP_SESSION_AGENT=1 to disable (same env
    name as the Claude harness — one kill switch works regardless of
    harness).

    Marker: Codex has no `Skill` tool — capabilities are context-injected.
    The hook detects session-agent ran by finding the injected capability
    body (its H1) or an assistant function_call reading the SKILL.md path,
    plus an assistant-authored line-anchored `Linear gate:` declaration.

    stdin:  PreToolUse hook event JSON
    stdout: when blocking, a PreToolUse deny decision (JSON)
    exit:   always 0

.NOTES
    <TEAM>-113 port mirrors the bash twin's behaviour 1:1. Per
    [[reference_ps_port_traps]] trap #3 (Set-Content CRLF + BOM): JSON
    emission goes through jq so escaping + line-endings stay LF /
    no-BOM regardless of pwsh edition. Per [[reference_powershell_var_colon]]
    trap #4: any `$name:` inside double-quoted strings uses `${name}:` form
    (none in this hook today, but the pattern is honored if extended).
#>

# Match bash hook's `set -uo pipefail` (no -e) — graceful exit on missing
# transcript / unexpected shapes rather than strict-mode-fail.
$ErrorActionPreference = 'Continue'

# deny — emit a Codex PreToolUse deny decision via jq for safe escaping.
function Deny {
    param([Parameter(Mandatory)][string]$Reason)
    $jsonOut = & jq -nc --arg r $Reason `
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    Write-Output $jsonOut
    exit 0
}

if ($env:CLAUDE_SKIP_SESSION_AGENT -eq '1') {
    exit 0
}

# jq contract — gate hook fails CLOSED. Deny needs jq, so emit a static-string
# block shape when jq is absent (parity with bash twin's heredoc). The legacy
# top-level {"decision":"block"} form GENUINELY blocks on Codex PreToolUse
# (verified v0.132.0 schema + docs — see adapter.md "Hook decision formats"). A
# real Codex/Claude divergence: do NOT align it to the Claude twin's <TEAM>-227 fix,
# where the legacy top-level form is a no-op on PreToolUse.
if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    Write-Output '{"decision":"block","reason":"Session-agent enforcement hook cannot run: `jq` was not found on the hook PATH. The gate fails closed. Install jq, or set env CLAUDE_SKIP_SESSION_AGENT=1 to bypass enforcement."}'
    exit 0
}

# Drain stdin. [Console]::In.ReadToEnd() is the cleanest path.
$INPUT_JSON = [Console]::In.ReadToEnd()
if (-not $INPUT_JSON) { exit 0 }

# Extract transcript_path via jq (matches bash hook's contract).
$TRANSCRIPT = $INPUT_JSON | & jq -r '.transcript_path // empty'
if (-not $TRANSCRIPT -or -not (Test-Path -LiteralPath $TRANSCRIPT -PathType Leaf)) {
    exit 0
}

# Check if the session-agent capability ran. A bare whole-transcript path
# match is vacuous: Codex injects a skills CATALOG as a developer message on
# EVERY session, and each catalog line carries the skill's `(file: …/SKILL.md)`
# path — so the old check self-matched before any invocation. Detect a genuine
# invocation instead, from the rollout's response_item records (same jq filter
# as the bash twin):
#   (a) a message record carrying the capability body's own H1 (the catalog
#       line quotes only name + description, never the body), or
#   (b) an assistant-initiated function_call whose arguments read the SKILL.md
#       path (the model pulling the body itself).
# The H1 literal must stay in sync with capabilities/session-agent.md.
#
# <TEAM>-113 Codex F-1 amendment (carried forward): Codex transcripts on Windows
# may write the marker path with OS-native separators — the function_call
# branch matches BOTH `/` and `\` (one or more, since JSON encodes a single
# `\` as two backslash bytes). The bash twin now carries the same alternation
# (cross-model panel 2026-07-02) so the twins agree on Windows transcripts.
# Scope note (same panel): the H1 branch cannot tell WHO put the body in the
# transcript — pasted H1 text opens only this ran-check. Accepted: the
# enforcement lives in the assistant-authored line-anchored declaration below,
# and this gate is a discipline net with a documented kill switch, not a
# security boundary.
$saRan = & jq -rR '
    fromjson? | select(.type == "response_item") | .payload
    | if .type == "message" then
        ([.content[]? | .text? // empty] | join("\n"))
        | select(contains("Session Agent — Session Kickoff Orient + Routing"))
        | "ran"
      elif .type == "function_call" then
        ((.arguments // "") | tostring) + " " + ((.name // "") | tostring)
        | select(test("skills[/\\\\]+session-agent[/\\\\]+SKILL[.]md"))
        | "ran"
      else empty end
  ' $TRANSCRIPT 2>$null
if (-not (@($saRan) -contains 'ran')) {
    Deny 'First file-modifying tool use detected but the session-agent capability has not been invoked this session. Invoke `$session-agent` to walk the kickoff orient (Mode 1) then route the request. One invocation per session for Mode 1; re-invoke for each subsequent non-trivial prompt (Mode 2). Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1.'
}

# session-agent ran — confirm the Linear gate was declared BY THE ASSISTANT.
# A whole-transcript match is vacuous here: the injected capability body
# carries its own `Linear gate:` template lines and a prior deny from this
# very hook quotes the phrase. Keep only assistant-authored message text and
# require the declaration at line start.
$assistantText = & jq -rR '
    fromjson? | select(.type == "response_item")
    | .payload | select(.type == "message" and .role == "assistant")
    | .content[]? | .text? // empty
  ' $TRANSCRIPT 2>$null
# -cmatch: case-SENSITIVE, matching the bash twin's grep (a plain -match is
# case-insensitive and would open the gate on `linear gate:` only on Windows).
if ((@($assistantText) -join "`n") -cmatch '(?m)^\s*Linear gate:') {
    exit 0
}

# session-agent ran but no Linear-gate declaration.
Deny 'The session-agent capability ran but no `Linear gate:` declaration was found this session. Re-run the routing steps (R1–R5) and emit the full declaration including the `Linear gate:` line. If the task is multi-step or multi-session, a Linear issue/project must exist first. Kill switch: set env CLAUDE_SKIP_SESSION_AGENT=1.'
