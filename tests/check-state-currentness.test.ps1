#!/usr/bin/env pwsh
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/check-state-currentness.test.ps1 — PowerShell twin of
# tests/check-state-currentness.test.sh.
#
# The checker compares tracker-state CLAIMS in memory/vault notes against live
# tracker state, and flags project-status/child contradictions. Advisory, never
# a gate, and it never edits anything.
#
# Hermetic: $env:LINEARK_BIN is pointed at a stub .ps1 serving fixture JSON from
# its own directory — no live tracker access, no token.
#
# Two halves, and the second matters as much as the first:
#   DETECTION — the three classes the checker exists to catch (a memory note
#   asserting In Progress for a Done issue; a vault note calling a Done issue
#   open; a Completed project with open children) must actually fire.
#   RESTRAINT — the false positives that sank the first implementation are
#   pinned as regression anchors: prose containing a state word near an
#   identifier ("mixes effective and cancelled actions"), a headline whose state
#   describes the PROJECT before listing issue IDs, a future CONDITION ("exits
#   only after all child issues are Done"), and history-log sections. A checker
#   that cries wolf is worse than no checker; these assertions are why the
#   extractor may never be loosened casually — on EITHER twin.
#
# (The bash twin's "no jq / no awk" skip cases have no PS analogue — the .ps1
# parses via ConvertFrom-Json and scans with .NET regex — so they are not
# mirrored here.)
#
# Dot-sourced by tests/run.ps1; uses Assert-* from tests/lib.ps1.

$CSC = Join-Path $env:REPO_ROOT 'scripts' 'check-state-currentness.ps1'
Assert-File 'check-state-currentness.ps1 present' $CSC

function New-CscTmp {
    $p = Join-Path ([IO.Path]::GetTempPath()) ('check-state-currentness-' + [Guid]::NewGuid().Guid.Substring(0, 8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

# New-CscStub <dir> — lineark stub .ps1. Serves:
#   issues list [--project P]  -> list.json / projissues-P.json
#   issues read ID             -> read-ID.json
#   projects list              -> projects.json
#   projects read ID           -> proj-ID.json
function New-CscStub([string]$d) {
    $stub = Join-Path $d 'stub.ps1'
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgList = @())
$d = Split-Path -Parent $MyInvocation.MyCommand.Path
# Call log — the read-budget assertion counts `issues read` invocations, which is
# the only way to prove the cap actually held (the exit code cannot show it).
Add-Content -LiteralPath (Join-Path $d 'calls.log') -Value ("CALL " + ($ArgList -join ' '))
$proj = ''
for ($i = 0; $i -lt $ArgList.Count - 1; $i++) {
    if ($ArgList[$i] -eq '--project') { $proj = $ArgList[$i + 1] }
}
if ($ArgList.Count -ge 2 -and $ArgList[0] -eq 'issues' -and $ArgList[1] -eq 'list') {
    if ($proj -ne '') {
        $f = Join-Path $d ("projissues-{0}.json" -f $proj)
        if (Test-Path -LiteralPath $f) { Get-Content -Raw $f; exit 0 }
        exit 1
    }
    $f = Join-Path $d 'list.json'
    if (Test-Path -LiteralPath $f) { Get-Content -Raw $f; exit 0 }
    exit 1
}
if ($ArgList.Count -ge 3 -and $ArgList[0] -eq 'issues' -and $ArgList[1] -eq 'read') {
    $f = Join-Path $d ("read-{0}.json" -f $ArgList[2])
    if (Test-Path -LiteralPath $f) { Get-Content -Raw $f; exit 0 }
    exit 1
}
if ($ArgList.Count -ge 2 -and $ArgList[0] -eq 'projects' -and $ArgList[1] -eq 'list') {
    $f = Join-Path $d 'projects.json'
    if (Test-Path -LiteralPath $f) { Get-Content -Raw $f; exit 0 }
    exit 1
}
if ($ArgList.Count -ge 3 -and $ArgList[0] -eq 'projects' -and $ArgList[1] -eq 'read') {
    $f = Join-Path $d ("proj-{0}.json" -f $ArgList[2])
    if (Test-Path -LiteralPath $f) { Get-Content -Raw $f; exit 0 }
    exit 1
}
exit 1
'@ | Set-Content -LiteralPath $stub
    return $stub
}

# Live state used by every fixture below: ABC-1 Done, ABC-2 Done, ABC-3 In
# Progress, ABC-4 Backlog.
function Set-CscStates([string]$d) {
    @'
[
  {"identifier": "ABC-1", "state": "Done"},
  {"identifier": "ABC-2", "state": "Done"},
  {"identifier": "ABC-3", "state": "In Progress"},
  {"identifier": "ABC-4", "state": "Backlog"}
]
'@ | Set-Content -LiteralPath (Join-Path $d 'list.json')
}

# Invoke-Csc <stub> <memdir> [extra flags] — stdout only, exit code captured.
function Invoke-Csc([string]$stub, [string]$memDir, [string[]]$flags = @()) {
    $env:LINEARK_BIN = $stub
    try {
        $argv = @('--isolated', '--prefix', 'ABC')
        if ($memDir -ne '') { $argv += @('--memory-dir', $memDir) }
        $argv += $flags
        $out = (& pwsh -NoProfile -File $CSC @argv 2>$null | Out-String).Trim()
        return @{ Out = $out; Rc = $LASTEXITCODE }
    } finally {
        Remove-Item Env:LINEARK_BIN -ErrorAction SilentlyContinue
    }
}

# ============================ DETECTION ======================================

# --- class 1: memory note asserts In Progress for a Done issue ---------------
$D1 = New-CscTmp; $M1 = Join-Path $D1 'mem'; New-Item -ItemType Directory -Path $M1 -Force | Out-Null
$stub1 = New-CscStub $D1; Set-CscStates $D1
@'
---
name: project-thing
---

ABC-1 is In Progress and gating the rest of the wave.
'@ | Set-Content -LiteralPath (Join-Path $M1 'project-thing.md')

$r = Invoke-Csc $stub1 $M1 @('--no-projects')
Assert-Eq       'check-state-currentness: stale claim exits 1' 1 $r.Rc
Assert-Contains 'check-state-currentness: catches In-Progress claim on a Done issue' `
    $r.Out 'WARN stale-claim ABC-1: note says "In Progress", tracker says "Done"'

# --- class 2: a note calls a Done issue open; dated vs undated classification --
$D2 = New-CscTmp; $M2 = Join-Path $D2 'mem'; New-Item -ItemType Directory -Path $M2 -Force | Out-Null
$stub2 = New-CscStub $D2; Set-CscStates $D2
@'
---
name: notes
---

## Open issues as of 2026-08-04 (verified against the tracker)

- ABC-2 — open, blocking the release.

## Current state

ABC-1 remains Backlog.
'@ | Set-Content -LiteralPath (Join-Path $M2 'notes.md')

$r = Invoke-Csc $stub2 $M2 @('--no-projects')
Assert-Eq       'check-state-currentness: mixed claims exit 1' 1 $r.Rc
Assert-Contains 'check-state-currentness: dated snapshot classified as stale-snapshot' `
    $r.Out 'WARN stale-snapshot ABC-2: note says "OPEN", tracker says "Done" (as-of 2026-08-04)'
Assert-Contains 'check-state-currentness: undated assertion classified as stale-claim' `
    $r.Out 'WARN stale-claim ABC-1: note says "Backlog", tracker says "Done" (as-of -)'
Assert-Contains 'check-state-currentness: summary separates the two classes' `
    $r.Out '1 stale claim(s), 1 stale snapshot(s)'

# --- class 3: project status vs child states ---------------------------------
$D3 = New-CscTmp; $M3 = Join-Path $D3 'mem'; New-Item -ItemType Directory -Path $M3 -Force | Out-Null
$stub3 = New-CscStub $D3; Set-CscStates $D3
@'
---
name: quiet
---

Nothing asserted here about any identifier.
'@ | Set-Content -LiteralPath (Join-Path $M3 'quiet.md')
@'
[{"id": "p-closed", "name": "Shipped Thing"},
 {"id": "p-idle", "name": "Sleepy Thing"},
 {"id": "p-active", "name": "Busy Thing"}]
'@ | Set-Content -LiteralPath (Join-Path $D3 'projects.json')
'{"id":"p-closed","name":"Shipped Thing","status":{"name":"Completed"}}'   | Set-Content -LiteralPath (Join-Path $D3 'proj-p-closed.json')
'{"id":"p-idle","name":"Sleepy Thing","status":{"name":"Backlog"}}'        | Set-Content -LiteralPath (Join-Path $D3 'proj-p-idle.json')
'{"id":"p-active","name":"Busy Thing","status":{"name":"In Progress"}}'    | Set-Content -LiteralPath (Join-Path $D3 'proj-p-active.json')
'[{"identifier":"ABC-4","state":"Backlog"}]'                               | Set-Content -LiteralPath (Join-Path $D3 'projissues-p-closed.json')
'[{"identifier":"ABC-3","state":"In Progress"}]'                           | Set-Content -LiteralPath (Join-Path $D3 'projissues-p-idle.json')
'[]'                                                                       | Set-Content -LiteralPath (Join-Path $D3 'projissues-p-active.json')

$r = Invoke-Csc $stub3 $M3
Assert-Eq       'check-state-currentness: project contradictions exit 1' 1 $r.Rc
Assert-Contains 'check-state-currentness: Completed project with open children' `
    $r.Out 'WARN project-closed-with-open-children "Shipped Thing": status "Completed" with 1 open child'
Assert-Contains 'check-state-currentness: Backlog project with active children' `
    $r.Out 'WARN project-idle-with-active-children "Sleepy Thing": status "Backlog" with 1 open child'
Assert-Contains 'check-state-currentness: In Progress project with no open children' `
    $r.Out 'WARN project-active-with-no-open-children "Busy Thing"'

# --- --list machine mode: stable TSV shape -----------------------------------
$r = Invoke-Csc $stub1 $M1 @('--no-projects', '--list')
Assert-Eq       'check-state-currentness: --list exits 1' 1 $r.Rc
Assert-Contains 'check-state-currentness: --list claim record shape' `
    $r.Out "claim`tstale-claim`tABC-1`tIn Progress`tDone`t-`t"
$r = Invoke-Csc $stub3 $M3 @('--list')
Assert-Contains 'check-state-currentness: --list project record shape' `
    $r.Out "project`tproject-closed-with-open-children`tShipped Thing`tCompleted`t1`t0"

# ============================ RESTRAINT ======================================
# Every fixture below WOULD have been flagged by the first implementation.

# --- prose containing a state word near an identifier ------------------------
$D4 = New-CscTmp; $M4 = Join-Path $D4 'mem'; New-Item -ItemType Directory -Path $M4 -Force | Out-Null
$stub4 = New-CscStub $D4; Set-CscStates $D4
@'
---
name: prose
description: "LIVE arc — the workstream is In Progress as of 2026-08-04: parent ABC-1; chain ABC-2 -> ABC-4"
---

The parallel ABC-1 source lane mixes effective and cancelled actions, so it was rejected.
The separately authorized disposable ABC-2 runtime proof then passed on Postgres 16.4.
Phase 2 exits only after all four child issues are Done, and the operator signs off.
Verification gate: ABC-4 exits when the economics memo lands and the review is complete.

ABC-3 is In Progress.
'@ | Set-Content -LiteralPath (Join-Path $M4 'prose.md')
# The accurate ABC-3 line is load-bearing for this fixture, not decoration: it
# supplies the one comparable claim that makes the run produce a verdict at all.
# Without it the checker (correctly) exits 2 "no comparable evidence" and every
# Assert-NotContains below would pass against empty output — a vacuous green.
$r = Invoke-Csc $stub4 $M4 @('--no-projects')
Assert-Eq          'check-state-currentness: prose yields no findings, only the one true claim (exit 0)' 0 $r.Rc
Assert-NotContains "check-state-currentness: 'cancelled actions' prose is not a Canceled claim" $r.Out 'ABC-1'
Assert-NotContains 'check-state-currentness: project-level state in a headline does not distribute to listed IDs' $r.Out 'ABC-2'
Assert-NotContains 'check-state-currentness: a future condition is not a present claim' $r.Out 'ABC-4'

# --- history-log sections are records, not claims ----------------------------
$D5 = New-CscTmp; $M5 = Join-Path $D5 'mem'; New-Item -ItemType Directory -Path $M5 -Force | Out-Null
$stub5 = New-CscStub $D5; Set-CscStates $D5
@'
---
name: history
---

## State Deltas

- 2026-07-01: ABC-1 was In Progress and ABC-2 remained Backlog at the time.

## Audit log

- 2026-07-02: ABC-3 Done, ABC-4 Done.
'@ | Set-Content -LiteralPath (Join-Path $M5 'history.md')
$r = Invoke-Csc $stub5 $M5 @('--no-projects')
Assert-Eq 'check-state-currentness: history-only note yields no comparable claims (skip 2)' 2 $r.Rc

# --- fenced code is syntax documentation, never a claim ----------------------
$D6 = New-CscTmp; $M6 = Join-Path $D6 'mem'; New-Item -ItemType Directory -Path $M6 -Force | Out-Null
$stub6 = New-CscStub $D6; Set-CscStates $D6
@'
---
name: fenced
---

Run this to close it:

```bash
tracker issues update ABC-1 --state Done   # ABC-2 is Backlog
```

ABC-3 is In Progress.
'@ | Set-Content -LiteralPath (Join-Path $M6 'fenced.md')
$r = Invoke-Csc $stub6 $M6 @('--no-projects')
Assert-Eq          'check-state-currentness: fenced code + one true claim → clean (exit 0)' 0 $r.Rc
Assert-NotContains 'check-state-currentness: fenced example is not a claim' $r.Out 'ABC-1'

# --- correct claims stay silent ----------------------------------------------
$D7 = New-CscTmp; $M7 = Join-Path $D7 'mem'; New-Item -ItemType Directory -Path $M7 -Force | Out-Null
$stub7 = New-CscStub $D7; Set-CscStates $D7
@'
---
name: accurate
---

- **ABC-1 — Done:** shipped.
- **ABC-3 — In Progress (High):** the active lane.
- ABC-4 remains Backlog.

**Done:** ABC-1, ABC-2.
'@ | Set-Content -LiteralPath (Join-Path $M7 'accurate.md')
$r = Invoke-Csc $stub7 $M7 @('--no-projects')
Assert-Eq       'check-state-currentness: accurate note passes (exit 0)' 0 $r.Rc
Assert-Contains 'check-state-currentness: PASS names the compared-claim count' $r.Out 'PASS'

# --- panel-derived restraint + recall anchors --------------------------------
# Every shape below came out of the pre-PR cross-model panel and was reproduced
# with a fixture before being fixed. They are pinned on BOTH twins: the extractor
# is a heuristic, so its boundary IS the spec, and a boundary that only one twin
# enforces is twin divergence by another name.
#
# The `ABC-3 is In Progress.` tail on each fixture is load-bearing, not padding:
# it supplies the one comparable claim that makes the run reach a verdict. Without
# it a suppressed line yields "no comparable evidence" (exit 2) and the
# Assert-NotContains below would pass against empty output — a vacuous green.
$DA = New-CscTmp; $MA = Join-Path $DA 'mem'; New-Item -ItemType Directory -Path $MA -Force | Out-Null
$stubA = New-CscStub $DA; Set-CscStates $DA

function Test-CscCase([string]$Line, [string]$Expect, [string]$Label) {
    Set-Content -LiteralPath (Join-Path $MA 'case.md') -Value ($Line + "`nABC-3 is In Progress.")
    $r = Invoke-Csc $stubA $MA @('--no-projects')
    if ($Expect -eq 'quiet') {
        Assert-Eq          "check-state-currentness: $Label yields no finding (exit 0)" 0 $r.Rc
        Assert-NotContains "check-state-currentness: $Label is not a state claim" $r.Out 'ABC-1'
    } else {
        Assert-Eq       "check-state-currentness: $Label IS a state claim (exit 1)" 1 $r.Rc
        Assert-Contains "check-state-currentness: $Label names ABC-1" $r.Out 'ABC-1'
    }
}

# RESTRAINT — a state word adjacent to an identifier is not automatically a claim.
Test-CscCase 'Done except: ABC-1'                 'quiet' 'a negative label ("Done except:")'
Test-CscCase 'ABC-1 done by Friday.'              'quiet' 'a deadline phrase ("done by Friday")'
Test-CscCase 'ABC-1 open questions remain.'       'quiet' 'a noun compound ("open questions")'
Test-CscCase 'ABC-1 is open for discussion.'      'quiet' 'an adjectival phrase ("open for discussion")'
Test-CscCase '- 2026-07-01: ABC-1 was Done then.' 'quiet' 'a date-led log bullet outside a history section'

# RECALL — ordinary present-tense phrasings must NOT be silently missed.
Test-CscCase 'ABC-1 is now Backlog.'              'claim' 'an adverb after the copula ("is now")'
Test-CscCase 'ABC-1 is currently Backlog.'        'claim' 'an adverb after the copula ("is currently")'
# "blocked" maps to OPEN, which contradicts the fixture's live Done — a state
# word that AGREED would exit 0 and prove nothing about extraction.
Test-CscCase 'ABC-1 has been blocked.'            'claim' 'a perfect auxiliary ("has been blocked")'
Test-CscCase 'ABC-1 was set to Backlog.'          'claim' 'an auxiliary + transition verb ("was set to")'

# TWIN PARITY — a non-breaking space must not make one twin see a claim the other
# misses; .NET \s matches U+00A0 where awk [[:space:]] is ASCII-only.
$nbsp = [char]0x00A0
Set-Content -LiteralPath (Join-Path $MA 'case.md') -Value ("ABC-1${nbsp}is${nbsp}Backlog.`nABC-3 is In Progress.")
$r = Invoke-Csc $stubA $MA @('--no-projects')
Assert-Eq       'check-state-currentness: NBSP-separated claim still extracts (exit 1)' 1 $r.Rc
Assert-Contains 'check-state-currentness: NBSP-separated claim names ABC-1' $r.Out 'ABC-1'

Remove-Item -LiteralPath $DA -Recurse -Force -ErrorAction SilentlyContinue

# --- read budget holds across the per-issue fallback ---------------------------
# The bash twin lost this counter to a command substitution; assert the cap here
# too so the twins cannot drift apart on how many tracker calls a run costs.
$DB = New-CscTmp; $MB = Join-Path $DB 'mem'; New-Item -ItemType Directory -Path $MB -Force | Out-Null
$stubB = New-CscStub $DB
# Bulk payload returns exactly --limit rows => treated as possibly truncated,
# so every unmatched identifier is a per-issue read candidate.
'[{"identifier":"ABC-90","state":"Done"},{"identifier":"ABC-91","state":"Done"}]' | Set-Content -LiteralPath (Join-Path $DB 'list.json')
foreach ($n in 1..5) {
    ('{"identifier":"ABC-' + $n + '","state":"Done"}') | Set-Content -LiteralPath (Join-Path $DB ("read-ABC-$n.json"))
}
(1..5 | ForEach-Object { "ABC-$_ is Backlog." }) -join "`n" | Set-Content -LiteralPath (Join-Path $MB 'many.md')
$null = Invoke-Csc $stubB $MB @('--no-projects', '--limit', '2', '--max-reads', '1')
$calls = @(Get-Content -LiteralPath (Join-Path $DB 'calls.log') -ErrorAction SilentlyContinue | Where-Object { $_ -match 'issues read' })
Assert-Eq 'check-state-currentness: --max-reads caps per-issue reads' 1 $calls.Count
Remove-Item -LiteralPath $DB -Recurse -Force -ErrorAction SilentlyContinue

# --- state lookup is key-exact, not a substring --------------------------------
# The bash twin used a fixed-string grep that also matched an XABC-1 row; this
# hashtable lookup must stay exact so the twins resolve identifiers identically.
$DC = New-CscTmp; $MC = Join-Path $DC 'mem'; New-Item -ItemType Directory -Path $MC -Force | Out-Null
$stubC = New-CscStub $DC
'[{"identifier":"XABC-1","state":"Done"},{"identifier":"ABC-3","state":"In Progress"}]' | Set-Content -LiteralPath (Join-Path $DC 'list.json')
"ABC-1 is Backlog.`nABC-3 is In Progress." | Set-Content -LiteralPath (Join-Path $MC 'x.md')
$r = Invoke-Csc $stubC $MC @('--no-projects')
Assert-Eq       'check-state-currentness: XABC-1 row does not resolve an ABC-1 claim (exit 0)' 0 $r.Rc
Assert-Contains 'check-state-currentness: unresolved ABC-1 is NOTEd, not compared' $r.Out 'absent from the tracker payload'
Remove-Item -LiteralPath $DC -Recurse -Force -ErrorAction SilentlyContinue

# --- a truncated project child list is a skip, never a PASS --------------------
$DD = New-CscTmp; $MD = Join-Path $DD 'mem'; New-Item -ItemType Directory -Path $MD -Force | Out-Null
$stubD = New-CscStub $DD; Set-CscStates $DD
'ABC-3 is In Progress.' | Set-Content -LiteralPath (Join-Path $MD 'q.md')
'[{"id": "p-big", "name": "Big Thing"}]' | Set-Content -LiteralPath (Join-Path $DD 'projects.json')
'{"id":"p-big","name":"Big Thing","status":{"name":"Backlog"}}' | Set-Content -LiteralPath (Join-Path $DD 'proj-p-big.json')
# Exactly --limit children, none of them active on this page.
'[{"identifier":"ABC-4","state":"Backlog"},{"identifier":"ABC-5","state":"Backlog"}]' | Set-Content -LiteralPath (Join-Path $DD 'projissues-p-big.json')
$r = Invoke-Csc $stubD $MD @('--limit', '2')
Assert-Contains    'check-state-currentness: at-limit child list is named as not evaluated' $r.Out 'child list may be truncated'
Assert-NotContains 'check-state-currentness: a truncated project is not counted as agreeing' $r.Out '1 project(s) agree'
Remove-Item -LiteralPath $DD -Recurse -Force -ErrorAction SilentlyContinue

# --- a lineark that cannot EXECUTE still fails soft ----------------------------
# $ErrorActionPreference is 'Stop', so an exec failure would otherwise throw and
# exit with PowerShell's own code — which self-audit would read as "findings".
$DE = New-CscTmp; $ME = Join-Path $DE 'mem'; New-Item -ItemType Directory -Path $ME -Force | Out-Null
'ABC-1 is Backlog.' | Set-Content -LiteralPath (Join-Path $ME 'n.md')
$broken = Join-Path $DE 'broken.ps1'
'this is not valid powershell {{{' | Set-Content -LiteralPath $broken
$r = Invoke-Csc $broken $ME @('--no-projects')
Assert-Eq 'check-state-currentness: an unrunnable lineark still exits 2 (fail-soft)' 2 $r.Rc
Remove-Item -LiteralPath $DE -Recurse -Force -ErrorAction SilentlyContinue

# --- vault scope: only `status: active` project notes are scanned -------------
# PS-only coverage the bash twin does not carry: the vault half of the source
# set. A completed project note is a historical record by definition, so its
# claims must not be read as present-tense assertions.
$D9 = New-CscTmp; $V9 = Join-Path $D9 'vault'
$P9 = Join-Path $V9 '01-Projects'
New-Item -ItemType Directory -Path $P9 -Force | Out-Null
$stub9 = New-CscStub $D9; Set-CscStates $D9
@'
---
status: active
---

ABC-3 is In Progress.
'@ | Set-Content -LiteralPath (Join-Path $P9 'live.md')
@'
---
status: completed
---

ABC-1 is In Progress.
'@ | Set-Content -LiteralPath (Join-Path $P9 'shipped.md')
$r = Invoke-Csc $stub9 '' @('--no-projects', '--vault-dir', $V9)
Assert-Eq          'check-state-currentness: active vault note scanned, completed one skipped (exit 0)' 0 $r.Rc
Assert-NotContains 'check-state-currentness: completed vault project note is not a present claim' $r.Out 'ABC-1'

# ============================ SKIP CONTRACT ==================================

# --- no lineark on PATH -------------------------------------------------------
$r = Invoke-Csc (Join-Path $D1 'definitely-absent.ps1') $M1
Assert-Eq 'check-state-currentness: absent lineark skips (2)' 2 $r.Rc

# The skip reason must reach STDERR in --list mode too — self-audit reports a
# NAMED skip, and stdout must stay pure TSV so the machine parse is unaffected.
$env:LINEARK_BIN = (Join-Path $D1 'definitely-absent.ps1')
try {
    $errFile = Join-Path $D1 'skip.err'
    $stdout = (& pwsh -NoProfile -File $CSC '--isolated' '--prefix' 'ABC' '--memory-dir' $M1 '--list' 2>$errFile | Out-String).Trim()
    $stderr = (Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue)
} finally { Remove-Item Env:LINEARK_BIN -ErrorAction SilentlyContinue }
Assert-Contains 'check-state-currentness: --list names the skip reason on stderr' "$stderr" 'SKIP lineark not found'
Assert-Eq       'check-state-currentness: --list keeps stdout empty on skip' '' $stdout

# --- bulk list call fails ------------------------------------------------------
$D8 = New-CscTmp; $M8 = Join-Path $D8 'mem'; New-Item -ItemType Directory -Path $M8 -Force | Out-Null
$stub8 = New-CscStub $D8   # no list.json written
Copy-Item -LiteralPath (Join-Path $M1 'project-thing.md') -Destination $M8
$r = Invoke-Csc $stub8 $M8
Assert-Eq 'check-state-currentness: failed bulk list skips (2)' 2 $r.Rc

# --- no prefix ----------------------------------------------------------------
$env:LINEARK_BIN = $stub1
try {
    $out = (& pwsh -NoProfile -File $CSC '--isolated' '--memory-dir' $M1 2>$null | Out-String).Trim()
    $rc = $LASTEXITCODE
} finally { Remove-Item Env:LINEARK_BIN -ErrorAction SilentlyContinue }
Assert-Eq 'check-state-currentness: missing prefix skips (2)' 2 $rc

# --- no sources ---------------------------------------------------------------
$r = Invoke-Csc $stub1 ''
Assert-Eq 'check-state-currentness: no sources skips (2)' 2 $r.Rc

# --- bad arguments -------------------------------------------------------------
$null = (& pwsh -NoProfile -File $CSC '--nope' 2>$null | Out-String)
Assert-Eq 'check-state-currentness: unknown argument skips (2)' 2 $LASTEXITCODE
$null = (& pwsh -NoProfile -File $CSC '--max-reads' 2>$null | Out-String)
Assert-Eq 'check-state-currentness: value-less --max-reads skips (2)' 2 $LASTEXITCODE
$null = (& pwsh -NoProfile -File $CSC '--max-reads' 'abc' 2>$null | Out-String)
Assert-Eq 'check-state-currentness: non-numeric --max-reads skips (2)' 2 $LASTEXITCODE
# The native -MaxReads form bypasses the $Rest regex and must still exit 2 —
# the twin-specific hole check-linear-hygiene.ps1 was hardened against.
$null = (& pwsh -NoProfile -File $CSC '-MaxReads' '-1' 2>$null | Out-String)
Assert-Eq 'check-state-currentness: native -MaxReads -1 skips (2)' 2 $LASTEXITCODE
$null = (& pwsh -NoProfile -File $CSC '-IssueLimit' '-1' 2>$null | Out-String)
Assert-Eq 'check-state-currentness: native -IssueLimit -1 skips (2)' 2 $LASTEXITCODE

# --- a prefix that could poison the scan pattern is refused -------------------
$r = Invoke-Csc $stub1 $M1 @('--prefix', 'A.*')
Assert-Eq 'check-state-currentness: non-alphanumeric prefix skips (2)' 2 $r.Rc

foreach ($d in @($D1, $D2, $D3, $D4, $D5, $D6, $D7, $D8, $D9)) {
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}
