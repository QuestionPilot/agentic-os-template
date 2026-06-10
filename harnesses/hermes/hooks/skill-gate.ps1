#Requires -Version 7
# Skill-management hard gate (Hermes pre_tool_call, matcher skill_manage) —
# Windows twin of skill-gate.sh. Mutations are blocked pending an explicit,
# per-use, operator-created approval marker that the hook CONSUMES.

$ErrorActionPreference = 'SilentlyContinue'

$hhome = Split-Path -Parent $PSScriptRoot
if (-not $hhome) {
    $hhome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $HOME '.hermes' }
}
$approval = Join-Path $hhome 'agentic-os' 'allow-skill-manage'

$inputRaw = [Console]::In.ReadToEnd()
$action = ''
try { $action = ([string](($inputRaw | ConvertFrom-Json).tool_input.action)).ToLower() } catch { }

# Read-only operations pass; unknown/absent action falls through (fail closed).
if ($action -in @('list', 'view', 'read', 'show', 'search', 'info')) { exit 0 }

if (Test-Path -LiteralPath $approval) {
    Remove-Item -LiteralPath $approval -Force
    exit 0
}

$reason = "skill_manage mutation blocked pending human approval. Self-authored skills become executable slash-commands, so autonomous creation/modification is hard-gated. Surface the FULL proposed skill change (name, frontmatter, complete body, and any commands it runs) to the operator; after review the operator approves ONE mutation by creating the file $approval — the approval is consumed on use and never persists."
@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
exit 0
