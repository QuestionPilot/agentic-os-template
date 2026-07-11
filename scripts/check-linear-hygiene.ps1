#Requires -Version 7
<#
.SYNOPSIS
    PowerShell twin of check-linear-hygiene.sh — advisory Linear issue-hygiene
    signal.

.DESCRIPTION
    Windows-native port of scripts/check-linear-hygiene.sh.

    Answers: "do the workspace's OPEN issues meet the issue-creation standard
    in linear/issue-template.md?" Per open issue it flags: no-project,
    no-priority (the "No priority" default), no-labels, no-assignee, and
    no-acceptance-criteria (description without an '## Acceptance criteria'
    heading, case-insensitive).

    ADVISORY, WARN-only — never a gate. Deliberately NOT wired into
    `make verify`: CI has no Linear token, and issue hygiene is workspace
    state, not repo state. Run it manually or as part of a periodic hygiene
    sweep; the fix is upgrading the flagged issues.

    The list payload carries priority/labels/assignee but NOT project or
    description, so those two checks need a per-issue read. Reads run
    sequentially (Linear rate limits; linear/linear-setup.md §7), capped by
    --max-reads; issues beyond the cap stay list-level-checked and are NAMED
    as unchecked — no silent truncation.

.PARAMETER MaxReads
    Cap on per-issue read calls for the project/body checks (default 50;
    0 = list-level checks only).

.PARAMETER List
    Machine mode: one line per flagged issue, `IDENTIFIER<TAB>gap[,gap...]`.
    Nothing when clean.

.NOTES
    Exit codes (BOTH modes), parity with the bash twin:
      0  clean — no checked issue has a hygiene gap
      1  gaps  — at least one open issue has a hygiene gap (advisory WARN)
      2  skip  — could not determine (no lineark / list call failed / bad
                 argument). Callers treat exit 2 as "say nothing".

    Requires the lineark CLI (linear/linear-setup.md §3.2). Override the
    binary with $env:LINEARK_BIN — the hermetic tests inject a stub .ps1 that
    serves fixture JSON.

    POSIX-style --max-reads / --list flags pass through $Rest so bash-trained
    operators get muscle-memory parity (mirrors check-freshness.ps1's parser).
#>

[CmdletBinding()]
param(
    [int]$MaxReads = 50,
    [switch]$List,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$global:LASTEXITCODE = 0

# POSIX-style flag pass-through (mirror the bash twin's `while [ $# -gt 0 ]`).
$i = 0
while ($i -lt $Rest.Count) {
    switch -CaseSensitive ($Rest[$i]) {
        '--max-reads' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('check-linear-hygiene: --max-reads needs a value')
                exit 2
            }
            $val = $Rest[$i + 1]
            if ($val -notmatch '^\d+$') {
                [Console]::Error.WriteLine('check-linear-hygiene: --max-reads must be a non-negative integer')
                exit 2
            }
            $MaxReads = [int]$val; $i += 2
        }
        '--list' { $List = [switch]$true; $i += 1 }
        default {
            [Console]::Error.WriteLine("check-linear-hygiene: unknown argument: $($Rest[$i])")
            exit 2
        }
    }
}

# skip <reason> — emit the reason (human mode only) and exit 2 (indeterminate).
function Skip-Hygiene([string]$reason) {
    if (-not $List) { [Console]::Error.WriteLine("SKIP $reason") }
    exit 2
}

# Get-Field <obj> <name> — flatten a payload field to a display string: ''
# for missing/null, joined names for Linear-MCP-shaped arrays/objects where
# lineark returns flat strings (parity with the bash twin's jq s() helper).
function Get-Field($obj, [string]$name) {
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    $v = $p.Value
    if ($v -is [array]) {
        return (($v | ForEach-Object {
            if ($_ -is [string]) { $_ }
            elseif ($null -ne $_.PSObject.Properties['name'] -and $null -ne $_.name) { $_.name }
            else { "$_" }
        }) -join ', ')
    }
    if ($v -is [PSCustomObject]) {
        if ($null -ne $v.PSObject.Properties['name'] -and $null -ne $v.name) { return "$($v.name)" }
        return "$v"
    }
    return "$v"
}

$lineark = if ($env:LINEARK_BIN) { $env:LINEARK_BIN } else { 'lineark' }
if (-not (Get-Command $lineark -ErrorAction SilentlyContinue)) {
    Skip-Hygiene 'lineark not found ($env:LINEARK_BIN or PATH) — see linear/linear-setup.md §3.2'
}

$raw = (& $lineark issues list --format json 2>$null | Out-String)
if ($LASTEXITCODE -ne 0) { Skip-Hygiene 'lineark issues list failed' }
if (-not $raw.TrimStart().StartsWith('[')) {
    Skip-Hygiene 'unexpected issues-list payload (not a JSON array)'
}
try { $issues = @($raw | ConvertFrom-Json) } catch {
    Skip-Hygiene 'unexpected issues-list payload (not valid JSON)'
}

$total = $issues.Count
if ($total -eq 0) {
    if (-not $List) { Write-Output 'PASS no open issues to check' }
    exit 0
}

$flagged = 0
$reads = 0
$unchecked = @()

foreach ($it in $issues) {
    $ident = Get-Field $it 'identifier'
    if (-not $ident) { continue }
    $priority = Get-Field $it 'priority'
    $labels = Get-Field $it 'labels'
    $assignee = Get-Field $it 'assignee'

    $gProject = $false; $gAc = $false
    $gPriority = ($priority -eq '' -or $priority -eq 'No priority')
    $gLabels = ($labels -eq '')
    $gAssignee = ($assignee -eq '')

    if ($reads -lt $MaxReads) {
        $reads++
        $robj = $null
        $rraw = (& $lineark issues read $ident --format json 2>$null | Out-String)
        if ($LASTEXITCODE -eq 0) {
            try { $robj = $rraw | ConvertFrom-Json } catch { $robj = $null }
        }
        if ($null -ne $robj -and $robj -is [PSCustomObject]) {
            $proj = $robj.PSObject.Properties['project']
            if ($null -eq $proj -or $null -eq $proj.Value) { $gProject = $true }
            $desc = Get-Field $robj 'description'
            if (-not $desc.ToLowerInvariant().Contains('## acceptance criteria')) { $gAc = $true }
        } else {
            # Read failed — project/body state is UNKNOWN, not a gap. Name it.
            $unchecked += $ident
        }
    } else {
        $unchecked += $ident
    }

    $gaps = @()
    if ($gProject) { $gaps += 'no-project' }
    if ($gPriority) { $gaps += 'no-priority' }
    if ($gLabels) { $gaps += 'no-labels' }
    if ($gAssignee) { $gaps += 'no-assignee' }
    if ($gAc) { $gaps += 'no-acceptance-criteria' }
    if ($gaps.Count -gt 0) {
        $flagged++
        $joined = $gaps -join ','
        if ($List) { Write-Output ("{0}`t{1}" -f $ident, $joined) }
        else { Write-Output "WARN ${ident}: $joined" }
    }
}

if ($unchecked.Count -gt 0 -and -not $List) {
    Write-Output ("NOTE {0} open issue(s) not checked for project/body (read cap --max-reads={1}, or a failed read): {2}" -f `
        $unchecked.Count, $MaxReads, ($unchecked -join ' '))
}

if ($flagged -eq 0) {
    if (-not $List) {
        if ($unchecked.Count -gt 0) {
            Write-Output ("PASS {0} open issue(s) meet the standard on all checked fields ({1} unchecked for project/body)" -f $total, $unchecked.Count)
        } else {
            Write-Output ("PASS all {0} open issue(s) meet the issue-creation standard" -f $total)
        }
    }
    exit 0
}

if (-not $List) {
    Write-Output ("SUMMARY {0} of {1} open issue(s) have hygiene gaps — advisory; the standard is linear/issue-template.md" -f $flagged, $total)
}
exit 1
