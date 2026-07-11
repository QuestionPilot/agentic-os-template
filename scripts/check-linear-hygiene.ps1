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
    no-acceptance-criteria (no '## Acceptance criteria' H2 heading —
    line-anchored, case-insensitive, so a '###' heading or a prose mention
    does not count).

    The standard's documented escapes are honored: a body containing
    "Deliberately projectless" / "Deliberately unassigned" (case-insensitive)
    suppresses the corresponding gap — those are CONFORMING per
    linear/issue-template.md. The escapes live in the description, so they
    apply only to issues whose read succeeded.

    SCOPE: the machine-visible subset of the standard. Team is enforced by
    the create command itself; parent/relations and body completeness beyond
    the AC heading are judgment calls the sweep does not police. The PASS
    line claims exactly the checked fields. Open-only scope relies on
    lineark's documented default of hiding Done/Canceled in `issues list`
    (linear/linear-setup.md §4.1/§4.3).

    ADVISORY, WARN-only — never a gate. Deliberately NOT wired into
    `make verify`. Reads run sequentially, capped by --max-reads; issues
    beyond the cap (or with a failed read) stay list-level-checked and are
    NAMED as unchecked in BOTH output modes — no silent truncation.

.PARAMETER MaxReads
    Cap on per-issue read calls for the project/body checks (default 50;
    0 = list-level checks only). Must be non-negative in this native form
    too — a negative value exits 2 like any other bad argument.

.PARAMETER List
    Machine mode: one line per flagged OR unchecked issue,
    `IDENTIFIER<TAB>token[,token...]` — the five gap slugs plus `unchecked`.
    Nothing when every issue is fully checked and clean.

.NOTES
    Exit codes (BOTH modes), parity with the bash twin:
      0  clean — no evaluated issue has a hygiene gap (unchecked-only is clean)
      1  gaps  — at least one open issue has a hygiene gap (advisory WARN)
      2  skip  — could not determine (no lineark / list call failed /
                 unparseable payload / bad argument). Callers treat exit 2
                 as "say nothing".

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

# The native -MaxReads form bypasses the $Rest regex — validate it too, or a
# negative cap silently marks every issue unchecked and returns a false PASS.
if ($MaxReads -lt 0) {
    [Console]::Error.WriteLine('check-linear-hygiene: --max-reads must be a non-negative integer')
    exit 2
}

# skip <reason> — emit the reason (human mode only) and exit 2 (indeterminate).
function Skip-Hygiene([string]$reason) {
    if (-not $List) { [Console]::Error.WriteLine("SKIP $reason") }
    exit 2
}

# Get-Field <obj> <name> — flatten a payload field to a display string: ''
# for missing/null, joined names for Linear-MCP-shaped arrays/objects where
# lineark returns flat strings (parity with the bash twin's jq s() helper).
# Null-safe on array elements: a [null] entry contributes '', never a
# StrictMode property-access crash.
function Get-Field($obj, [string]$name) {
    if ($null -eq $obj) { return '' }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    $v = $p.Value
    if ($v -is [array]) {
        return (($v | ForEach-Object {
            if ($null -eq $_) { '' }
            elseif ($_ -is [string]) { $_ }
            elseif ($null -ne $_.PSObject.Properties['name'] -and $null -ne $_.PSObject.Properties['name'].Value) { "$($_.PSObject.Properties['name'].Value)" }
            else { "$_" }
        }) -join ', ')
    }
    if ($v -is [PSCustomObject]) {
        if ($null -ne $v.PSObject.Properties['name'] -and $null -ne $v.PSObject.Properties['name'].Value) { return "$($v.PSObject.Properties['name'].Value)" }
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
$evaluated = 0
$malformed = 0
$unchecked = @()

foreach ($it in $issues) {
    $ident = Get-Field $it 'identifier'
    if (-not $ident) { $malformed++; continue }
    $evaluated++
    $priority = Get-Field $it 'priority'
    $labels = Get-Field $it 'labels'
    $assignee = Get-Field $it 'assignee'

    $gProject = $false; $gAc = $false; $isUnchecked = $false
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
            if (-not [regex]::IsMatch($desc, '(?im)^##[ \t]+acceptance criteria')) { $gAc = $true }
            # Standard-blessed escapes (issue-template.md): a stated reason in
            # the body makes projectless / unassigned CONFORMING — suppress.
            $descLc = $desc.ToLowerInvariant()
            if ($gProject -and $descLc.Contains('deliberately projectless')) { $gProject = $false }
            if ($gAssignee -and $descLc.Contains('deliberately unassigned')) { $gAssignee = $false }
        } else {
            # Read failed — project/body state is UNKNOWN, not a gap. Name it.
            $isUnchecked = $true
            $unchecked += $ident
        }
    } else {
        $isUnchecked = $true
        $unchecked += $ident
    }

    $gaps = @()
    if ($gProject) { $gaps += 'no-project' }
    if ($gPriority) { $gaps += 'no-priority' }
    if ($gLabels) { $gaps += 'no-labels' }
    if ($gAssignee) { $gaps += 'no-assignee' }
    if ($gAc) { $gaps += 'no-acceptance-criteria' }
    if ($gaps.Count -gt 0) { $flagged++ }
    if ($List) {
        $tokens = @($gaps)
        if ($isUnchecked) { $tokens += 'unchecked' }
        if ($tokens.Count -gt 0) {
            Write-Output ("{0}`t{1}" -f $ident, ($tokens -join ','))
        }
    } elseif ($gaps.Count -gt 0) {
        Write-Output "WARN ${ident}: $($gaps -join ',')"
    }
}

# Shape audit — never let an identifier-less payload read as a clean verdict.
if ($evaluated -eq 0) {
    Skip-Hygiene "no parseable issues in list payload ($malformed of $total entries lack an identifier)"
}

if (-not $List) {
    if ($malformed -gt 0) {
        Write-Output ("NOTE {0} list entr(y/ies) without an identifier skipped" -f $malformed)
    }
    if ($unchecked.Count -gt 0) {
        Write-Output ("NOTE {0} open issue(s) not checked for project/body (read cap --max-reads={1}, or a failed read): {2}" -f `
            $unchecked.Count, $MaxReads, ($unchecked -join ' '))
    }
}

if ($flagged -eq 0) {
    if (-not $List) {
        if ($unchecked.Count -gt 0 -or $malformed -gt 0) {
            Write-Output ("PASS {0} evaluated open issue(s) clean on the checked fields ({1} unchecked for project/body)" -f $evaluated, $unchecked.Count)
        } else {
            Write-Output ("PASS all {0} open issue(s) clean on the checked fields (project, priority, labels, assignee, acceptance-criteria heading)" -f $evaluated)
        }
    }
    exit 0
}

if (-not $List) {
    Write-Output ("SUMMARY {0} of {1} evaluated open issue(s) have hygiene gaps — advisory; the standard is linear/issue-template.md" -f $flagged, $evaluated)
}
exit 1
