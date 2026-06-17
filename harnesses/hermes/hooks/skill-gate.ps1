#Requires -Version 7
# Skill-management hard gate (Hermes pre_tool_call, matcher skill_manage) —
# Windows twin of skill-gate.sh.
#
# skill_manage is a MUTATION-ONLY tool: every valid action (create/edit/patch/
# delete/write_file/remove_file) mutates a skill. Reads go through the SEPARATE,
# ungated skill_view/skills_list tools, which this hook's matcher never fires on.
# So there is no read-only skill_manage call to fast-path — EVERY skill_manage
# invocation is gated, blocked pending an explicit, per-use, operator-created
# approval marker that this hook CONSUMES (one approval, one mutation). Mirrors
# skill-gate.sh.

$ErrorActionPreference = 'SilentlyContinue'

$hhome = Split-Path -Parent $PSScriptRoot
if (-not $hhome) {
    $hhome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $HOME '.hermes' }
}
$approval = Join-Path $hhome 'agentic-os' 'allow-skill-manage'

# Consume stdin; we gate EVERY skill_manage call, so there is nothing to inspect.
[void][Console]::In.ReadToEnd()

# -PathType Leaf matches a FILE only — parity with the bash twin's `[[ -f ]]`.
# Without it, Test-Path is also true for a DIRECTORY at the marker path, which the
# bash twin would never treat as an approval (and a non-empty dir survives the
# Remove-Item, turning allow-once into a standing allow).
if (Test-Path -LiteralPath $approval -PathType Leaf) {
    Remove-Item -LiteralPath $approval -Force
    exit 0
}

$reason = "skill_manage mutation blocked pending human approval. Self-authored skills become executable slash-commands, so autonomous creation/modification is hard-gated. Surface the FULL proposed skill change (name, frontmatter, complete body, and any commands it runs) to the operator; after review the operator approves ONE mutation by creating the file $approval — the approval is consumed on use and never persists."
@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
exit 0
