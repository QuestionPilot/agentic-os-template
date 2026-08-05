#!/usr/bin/env pwsh
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/orient.test.ps1 — PowerShell twin of tests/orient.test.sh.
#
# The helper collects session-agent Mode 1's kickoff state (project-first Linear
# cut, global-open reconciliation, project anomalies, memory pointers, named
# degraded surfaces) into ONE `orient/v1` JSON document.
#
# Hermetic: --lineark is pointed at a stub .ps1 serving the JSON fixtures under
# tests/fixtures/orient/ — no live tracker, no token. Both twins read the SAME
# fixture files, so a shape disagreement between them cannot hide behind
# differently-worded inline heredocs.
#
# Three things are pinned, and the second and third matter as much as the first:
#   SHAPE — the emitted document always carries every top-level key with the
#   right TYPE (a structural assertion over the parsed object, not a prose
#   match). A caller parses one shape or none; a key that vanishes under a
#   degraded surface is the bug this suite exists to prevent.
#   PAYLOAD SHAPE TOLERANCE — lineark's `issues list` returns `.state` as a BARE
#   STRING while `issues read` returns it as an OBJECT {id,name}. One normalizer
#   must accept both.
#   DEGRADATION — lineark absent, lineark erroring, memory dir absent: each must
#   still emit a valid document on exit 0 with a NAMED `degraded` entry.
#
# (The bash twin's "jq not installed" whole-suite skip has no PS analogue — the
# .ps1 emits with ConvertTo-Json and this file parses with ConvertFrom-Json — so
# it is not mirrored here.)
#
# Dot-sourced by tests/run.ps1; uses Assert-* from tests/lib.ps1.

$ORIENT = Join-Path $env:REPO_ROOT 'scripts' 'orient.ps1'
$ORIENT_FIX = Join-Path $env:REPO_ROOT 'tests' 'fixtures' 'orient'
Assert-File 'orient.ps1 present' $ORIENT

function New-OrientTmp {
    $p = Join-Path ([IO.Path]::GetTempPath()) ('orient-' + [Guid]::NewGuid().Guid.Substring(0, 8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

# New-OrientStub <dir> — lineark stub .ps1. Serves, from its own directory:
#   projects list              -> projects.json
#   issues list                -> issues-global.json
#   issues list --mine         -> issues-mine.json
#   issues list --project P    -> projissues-P.json
#   issues read ID             -> read-ID.json
# A missing file exits 1, so a fixture set can make any single cut fail.
function New-OrientStub([string]$d) {
    $stub = Join-Path $d 'stub.ps1'
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgList = @())
$d = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Content -LiteralPath (Join-Path $d 'calls.log') -Value ("CALL " + ($ArgList -join ' '))
$proj = ''
$mine = $false
for ($i = 0; $i -lt $ArgList.Count; $i++) {
    if ($ArgList[$i] -eq '--project' -and $i + 1 -lt $ArgList.Count) { $proj = $ArgList[$i + 1] }
    if ($ArgList[$i] -eq '--mine') { $mine = $true }
}
if ($ArgList.Count -ge 2 -and $ArgList[0] -eq 'projects' -and $ArgList[1] -eq 'list') {
    $f = Join-Path $d 'projects.json'
    if (Test-Path -LiteralPath $f) { Get-Content -Raw $f; exit 0 }
    exit 1
}
if ($ArgList.Count -ge 2 -and $ArgList[0] -eq 'issues' -and $ArgList[1] -eq 'list') {
    if ($proj -ne '') { $f = Join-Path $d ("projissues-{0}.json" -f $proj) }
    elseif ($mine) { $f = Join-Path $d 'issues-mine.json' }
    else { $f = Join-Path $d 'issues-global.json' }
    if (Test-Path -LiteralPath $f) { Get-Content -Raw $f; exit 0 }
    exit 1
}
if ($ArgList.Count -ge 3 -and $ArgList[0] -eq 'issues' -and $ArgList[1] -eq 'read') {
    $f = Join-Path $d ("read-{0}.json" -f $ArgList[2])
    if (Test-Path -LiteralPath $f) { Get-Content -Raw $f; exit 0 }
    exit 1
}
exit 1
'@ | Set-Content -LiteralPath $stub
    return $stub
}

# Copy-OrientFixtures <dir> [names] — copy the named fixture files into the stub
# dir (default: the full nominal set).
function Copy-OrientFixtures([string]$d, [string[]]$Names = @()) {
    if ($Names.Count -eq 0) {
        $Names = @('projects.json', 'projissues-p-alpha.json', 'projissues-p-beta.json',
                   'issues-global.json', 'issues-mine.json', 'read-ABC-5.json')
    }
    foreach ($n in $Names) {
        Copy-Item -LiteralPath (Join-Path $ORIENT_FIX $n) -Destination (Join-Path $d $n) -Force
    }
}

# Invoke-Orient <stub> [flags] — stdout only, exit code captured, parsed doc.
function Invoke-Orient([string]$stub, [string[]]$flags = @()) {
    $argv = @('--lineark', $stub) + $flags
    $out = (& pwsh -NoProfile -File $ORIENT @argv 2>$null | Out-String)
    $rc = $LASTEXITCODE
    $doc = $null
    try { $doc = $out | ConvertFrom-Json } catch { $doc = $null }
    return @{ Out = $out.Trim(); Rc = $rc; Doc = $doc }
}

# Test-OrientSchema — STRUCTURAL validation, not a prose match: every top-level
# key present with the right type. Echoes 'ok' or 'BAD'. Run on the NOMINAL
# document and re-run on every degraded document below — the contract is that
# the shape never varies.
function Test-OrientSchema($doc) {
    if ($null -eq $doc) { return 'BAD' }
    function _Has($o, [string]$k) {
        if ($null -eq $o) { return $false }
        return ($null -ne $o.PSObject.Properties[$k])
    }
    function _Str($o, [string]$k) {
        if (-not (_Has $o $k)) { return $false }
        return ($o.$k -is [string])
    }
    function _Arr($o, [string]$k) {
        if (-not (_Has $o $k)) { return $false }
        $v = $o.$k
        return ($null -ne $v -and ($v -is [System.Array] -or $v -is [System.Collections.IList]))
    }
    if (-not (_Str $doc 'schema')) { return 'BAD' }
    if ($doc.schema -cne 'orient/v1') { return 'BAD' }
    if (-not (_Has $doc 'surfaces')) { return 'BAD' }
    foreach ($s in @('linear', 'memory')) {
        if (-not (_Has $doc.surfaces $s)) { return 'BAD' }
        $sf = $doc.surfaces.$s
        if (-not (_Str $sf 'status')) { return 'BAD' }
        if (-not (_Str $sf 'detail')) { return 'BAD' }
        if (@('ok', 'absent', 'error') -notcontains $sf.status) { return 'BAD' }
    }
    foreach ($k in @('projects', 'projectless_open_issues', 'mine_in_progress',
                     'anomalies', 'memory_pointers', 'degraded')) {
        if (-not (_Arr $doc $k)) { return 'BAD' }
    }
    function _IssueOk($it) {
        foreach ($f in @('identifier', 'title', 'state', 'priority', 'assignee', 'url')) {
            if (-not (_Str $it $f)) { return $false }
        }
        return $true
    }
    foreach ($p in @($doc.projects)) {
        foreach ($f in @('id', 'name', 'slug_id')) { if (-not (_Str $p $f)) { return 'BAD' } }
        if (-not (_Arr $p 'open_issues')) { return 'BAD' }
        foreach ($it in @($p.open_issues)) { if (-not (_IssueOk $it)) { return 'BAD' } }
    }
    foreach ($k in @('projectless_open_issues', 'mine_in_progress')) {
        foreach ($it in @($doc.$k)) { if (-not (_IssueOk $it)) { return 'BAD' } }
    }
    foreach ($a in @($doc.anomalies)) {
        foreach ($f in @('type', 'subject', 'detail')) { if (-not (_Str $a $f)) { return 'BAD' } }
    }
    foreach ($m in @($doc.memory_pointers)) {
        foreach ($f in @('file', 'name', 'description')) { if (-not (_Str $m $f)) { return 'BAD' } }
    }
    foreach ($d in @($doc.degraded)) { if (-not ($d -is [string])) { return 'BAD' } }
    return 'ok'
}

$MEMFIX = Join-Path $ORIENT_FIX 'memory'

# ============================ NOMINAL ========================================
$O1 = New-OrientTmp; $stub1 = New-OrientStub $O1; Copy-OrientFixtures $O1
$r = Invoke-Orient $stub1 @('--memory-dir', $MEMFIX)

Assert-Eq 'orient: nominal run exits 0' 0 $r.Rc
Assert-Eq 'orient: nominal document satisfies the orient/v1 schema' 'ok' (Test-OrientSchema $r.Doc)

# --- project-first Linear cut -------------------------------------------------
Assert-Eq 'orient: projects are emitted in tracker order with slug ids' `
    'p-alpha:Alpha Arc:alpha-1 p-beta:Beta Arc:beta-2' `
    ((@($r.Doc.projects | ForEach-Object { "$($_.id):$($_.name):$($_.slug_id)" })) -join ' ')
Assert-Eq 'orient: per-project open issues carry the bare-string state verbatim' `
    'ABC-1=In Progress ABC-2=Backlog' `
    ((@($r.Doc.projects[0].open_issues | ForEach-Object { "$($_.identifier)=$($_.state)" })) -join ' ')
Assert-Eq 'orient: a null priority normalizes to an empty string, not null' `
    '' $r.Doc.projects[1].open_issues[1].priority

# --- global-open reconciliation ----------------------------------------------
# ABC-9 is in the global sweep and in NO project's list. A projects-only orient
# drops it silently; this is the cut that catches it.
Assert-Eq 'orient: an issue in the global sweep but in no project is projectless' `
    'ABC-9' ((@($r.Doc.projectless_open_issues | ForEach-Object { $_.identifier })) -join ' ')
Assert-Eq 'orient: issues that DO belong to a project are not projectless' `
    '0' (@($r.Doc.projectless_open_issues | Where-Object { @('ABC-1','ABC-2','ABC-3','ABC-4') -contains $_.identifier }).Count).ToString()

# --- mine + In Progress -------------------------------------------------------
# The --mine fixture also contains ABC-9 (Todo); only the In Progress row counts.
Assert-Eq 'orient: mine_in_progress is assigned AND In Progress, nothing else' `
    'ABC-1' ((@($r.Doc.mine_in_progress | ForEach-Object { $_.identifier })) -join ' ')

# --- anomalies ----------------------------------------------------------------
Assert-Eq 'orient: a project whose whole open set is unassigned Backlog is an anomaly' `
    'all-issues-backlog-no-assignee:Beta Arc' `
    ((@($r.Doc.anomalies | ForEach-Object { "$($_.type):$($_.subject)" })) -join ' ')
Assert-NotContains 'orient: a consistent sweep raises no count mismatch' `
    $r.Out 'open-issue-count-mismatch'

# --- memory pointers ----------------------------------------------------------
# metadata.type AND top-level type both count; reference/feedback notes and the
# untyped MEMORY.md index do not.
Assert-Eq 'orient: project-type memory notes are the only pointers emitted' `
    'project-alpha.md project-beta.md' `
    ((@($r.Doc.memory_pointers | ForEach-Object { $_.file })) -join ' ')
Assert-Eq 'orient: a memory pointer carries name + description from frontmatter' `
    'project-alpha|Alpha Arc — LIVE, two open issues' `
    ("$($r.Doc.memory_pointers[0].name)|$($r.Doc.memory_pointers[0].description)")
Assert-Eq 'orient: a healthy run names no degraded surface' `
    '0' (@($r.Doc.degraded).Count).ToString()

# --- output modes -------------------------------------------------------------
Assert-Eq 'orient: default output is ONE compact JSON line' `
    '1' (@($r.Out -split "`n" | Where-Object { $_.Trim() -ne '' }).Count).ToString()
$rp = Invoke-Orient $stub1 @('--memory-dir', $MEMFIX, '--pretty')
Assert-Eq 'orient: --pretty still parses as the same document' 'ok' (Test-OrientSchema $rp.Doc)
$prettyLines = @($rp.Out -split "`n" | Where-Object { $_.Trim() -ne '' }).Count
if ($prettyLines -gt 1) {
    _Pass 'orient: --pretty indents across multiple lines'
} else {
    _Fail 'orient: --pretty indents across multiple lines' "got $prettyLines line(s)"
}

# ============================ PAYLOAD SHAPE TOLERANCE ========================
# `issues list` returns `.state` as a BARE STRING; `issues read` returns it as an
# OBJECT {id,name}. One normalizer must accept both — reading `.state.name` on
# list output would emit null, and stringifying read output would emit the whole
# object. Serve the OBJECT-shaped payload through the issue path and require the
# state name back as a plain string.
$O2 = New-OrientTmp; $stub2 = New-OrientStub $O2
Copy-OrientFixtures $O2 @('projects.json', 'issues-global.json', 'issues-mine.json', 'read-ABC-5.json')
Copy-Item -LiteralPath (Join-Path $ORIENT_FIX 'issues-objstate.json') -Destination (Join-Path $O2 'projissues-p-alpha.json') -Force
Copy-Item -LiteralPath (Join-Path $ORIENT_FIX 'issues-objstate.json') -Destination (Join-Path $O2 'projissues-p-beta.json') -Force
$r = Invoke-Orient $stub2
Assert-Eq 'orient: an OBJECT-shaped state (the issues-read shape) flattens to its name' `
    'In Progress' $r.Doc.projects[0].open_issues[0].state
Assert-Eq 'orient: object-state payloads still satisfy the schema' 'ok' (Test-OrientSchema $r.Doc)

# An object-shaped field with NO `name` (e.g. `assignee: {"id": "usr_123"}`)
# flattens to the EMPTY STRING, never to a stringified object. Get-Flat fell
# through to "$v" here and emitted PowerShell's own object rendering
# (`@{id=usr_123}`) where the bash twin's `.name // ""` yields "". See the bash
# control in tests/orient.test.sh.
$O2N = New-OrientTmp; $stub2n = New-OrientStub $O2N
Copy-OrientFixtures $O2N @('projects.json', 'issues-global.json', 'issues-mine.json')
Copy-Item -LiteralPath (Join-Path $ORIENT_FIX 'issues-nameless-object.json') -Destination (Join-Path $O2N 'projissues-p-alpha.json') -Force
Copy-Item -LiteralPath (Join-Path $ORIENT_FIX 'issues-nameless-object.json') -Destination (Join-Path $O2N 'projissues-p-beta.json') -Force
$r = Invoke-Orient $stub2n
Assert-Eq 'orient: an object field with no name flattens to the empty string' `
    '' $r.Doc.projects[0].open_issues[0].assignee
Assert-NotContains 'orient: a nameless object is never stringified into the document' `
    $r.Out 'id=usr_123'
Assert-Eq 'orient: nameless-object payloads still satisfy the schema' 'ok' (Test-OrientSchema $r.Doc)

# ============================ COUNT MISMATCH =================================
# The global sweep sees only ABC-1 while the projects list ABC-1..4 — the two
# cuts disagree about what is open (a truncated sweep, or a scope filter that
# dropped rows). Reported as an anomaly rather than silently reconciled away.
$O3 = New-OrientTmp; $stub3 = New-OrientStub $O3
Copy-OrientFixtures $O3 @('projects.json', 'projissues-p-alpha.json', 'projissues-p-beta.json', 'issues-mine.json')
Copy-Item -LiteralPath (Join-Path $ORIENT_FIX 'issues-global-short.json') -Destination (Join-Path $O3 'issues-global.json') -Force
$r = Invoke-Orient $stub3
Assert-Eq 'orient: a disagreeing sweep still exits 0' 0 $r.Rc
Assert-Contains 'orient: project issues absent from the global sweep raise open-issue-count-mismatch' `
    ((@($r.Doc.anomalies | ForEach-Object { "$($_.type)|$($_.detail)" })) -join "`n") `
    'open-issue-count-mismatch|3 identifier(s) listed under a project but absent from the global open sweep (global=1, project-union=4): ABC-2, ABC-3, ABC-4'
Assert-Eq 'orient: the short sweep leaves nothing projectless' `
    '0' (@($r.Doc.projectless_open_issues).Count).ToString()

# ============================ DEGRADATION ====================================

# --- lineark not on PATH ------------------------------------------------------
$r = Invoke-Orient (Join-Path $O1 'definitely-absent.ps1') @('--memory-dir', $MEMFIX)
Assert-Eq 'orient: absent lineark still exits 0' 0 $r.Rc
Assert-Eq 'orient: absent lineark still emits a schema-valid document' 'ok' (Test-OrientSchema $r.Doc)
Assert-Eq 'orient: absent lineark marks the surface absent' 'absent' $r.Doc.surfaces.linear.status
Assert-Contains 'orient: absent lineark is NAMED in degraded' `
    ((@($r.Doc.degraded)) -join "`n") 'linear: lineark not on PATH'
Assert-Eq 'orient: absent lineark yields empty Linear arrays, not missing keys' `
    '0 0 0' (@(@($r.Doc.projects).Count, @($r.Doc.projectless_open_issues).Count, @($r.Doc.mine_in_progress).Count) -join ' ')
Assert-Eq 'orient: the memory surface still reports when Linear is absent' `
    '2' (@($r.Doc.memory_pointers).Count).ToString()

# --- lineark on PATH but every call fails -------------------------------------
# The stub exits 1 when its fixture file is missing, so an empty stub dir is a
# tracker that answers with failures rather than one that is not installed —
# a DIFFERENT surface status, and the distinction is the operator's next action.
$O4 = New-OrientTmp; $stub4 = New-OrientStub $O4   # no fixtures copied
$r = Invoke-Orient $stub4
Assert-Eq 'orient: an erroring lineark still exits 0' 0 $r.Rc
Assert-Eq 'orient: an erroring lineark still emits a schema-valid document' 'ok' (Test-OrientSchema $r.Doc)
Assert-Eq "orient: an erroring lineark is 'error', distinct from 'absent'" 'error' $r.Doc.surfaces.linear.status
Assert-Eq 'orient: every failed lineark cut is named separately in degraded' `
    'linear: projects list failed|linear: global issues list failed|linear: issues list --mine failed|linear: reconciliation unavailable — incomplete project cut' `
    ((@($r.Doc.degraded | Where-Object { $_.StartsWith('linear:', [StringComparison]::Ordinal) })) -join '|')

# --- one project's issue list fails -------------------------------------------
# The project must still appear (with an empty open set) and the failure must be
# named against that project, not collapsed into a generic tracker outage.
$O5 = New-OrientTmp; $stub5 = New-OrientStub $O5
Copy-OrientFixtures $O5 @('projects.json', 'projissues-p-alpha.json', 'issues-global.json', 'issues-mine.json')
$r = Invoke-Orient $stub5
Assert-Eq 'orient: a project whose issue list fails still appears with an empty open set' `
    'Alpha Arc=2 Beta Arc=0' `
    ((@($r.Doc.projects | ForEach-Object { "$($_.name)=$(@($_.open_issues).Count)" })) -join ' ')
Assert-Contains 'orient: the failing project is named in degraded' `
    ((@($r.Doc.degraded)) -join "`n") 'linear: issues list failed for project Beta Arc'
# RECONCILIATION INTEGRITY. The projectless cut is a set difference against the
# project union, and Beta's rows (ABC-3, ABC-4) are missing from that union only
# because Beta's CALL failed. Computing the difference anyway would report two
# correctly-filed issues as projectless AND raise a count-mismatch — both phantoms
# manufactured from the same hole. The reconciliation is reported unavailable.
Assert-Eq 'orient: an incomplete project cut emits NO projectless set, not a partial one' `
    '0' (@($r.Doc.projectless_open_issues).Count).ToString()
Assert-Contains 'orient: the unavailable reconciliation is NAMED in degraded' `
    ((@($r.Doc.degraded)) -join "`n") 'linear: reconciliation unavailable — incomplete project cut'
Assert-NotContains 'orient: no phantom count-mismatch from an incomplete project cut' `
    $r.Out 'open-issue-count-mismatch'
Assert-Eq 'orient: rows hidden by the failed project call are not named projectless' `
    '0' (@($r.Doc.projectless_open_issues | Where-Object { @('ABC-3','ABC-4') -contains $_.identifier }).Count).ToString()
Assert-Eq 'orient: an incomplete project cut still exits 0' 0 $r.Rc
Assert-Eq 'orient: an incomplete project cut still emits a schema-valid document' 'ok' (Test-OrientSchema $r.Doc)
# The cuts that DID succeed are untouched — this suppresses a derived claim, not
# the collected data.
Assert-Eq 'orient: the successful project cut survives the suppressed reconciliation' `
    '2' (@($r.Doc.projects[0].open_issues).Count).ToString()
Assert-Eq 'orient: mine_in_progress survives the suppressed reconciliation' `
    'ABC-1' ((@($r.Doc.mine_in_progress | ForEach-Object { $_.identifier })) -join ' ')

# --- memory dir absent / not given --------------------------------------------
$r = Invoke-Orient $stub1 @('--memory-dir', (Join-Path $O1 'no-such-memory-dir'))
Assert-Eq 'orient: an absent memory dir still emits a schema-valid document' 'ok' (Test-OrientSchema $r.Doc)
Assert-Eq 'orient: an absent memory dir marks the surface absent with no pointers' `
    'absent 0' "$($r.Doc.surfaces.memory.status) $(@($r.Doc.memory_pointers).Count)"
Assert-Contains 'orient: an absent memory dir is NAMED in degraded' `
    ((@($r.Doc.degraded)) -join "`n") 'memory: dir absent'

$r = Invoke-Orient $stub1
Assert-Contains 'orient: omitting --memory-dir is a named degraded surface, not a silent skip' `
    ((@($r.Doc.degraded)) -join "`n") 'memory: no --memory-dir given'

# ============================ VALID EMPTY TRACKER ============================
# An empty tracker is a legitimate ANSWER, not a failure: a fresh workspace, a
# project with nothing open, a --mine cut with nothing assigned. `[]` back from
# every cut must read as `ok` with ZERO degraded entries and empty arrays.
#
# This is the PS-side regression the bash twin never had: PowerShell UNWRAPS a
# returned collection into the pipeline, so the tracker wrapper's plain
# `return @(… | ConvertFrom-Json)` turned a valid `[]` into $null — the same
# value the wrapper uses for "the call failed". Every empty cut was counted as
# an outage: surfaces.linear.status = 'error' plus three degraded entries, while
# bash reported 'ok' on the identical fixtures.
$O6 = New-OrientTmp; $stub6 = New-OrientStub $O6
Copy-OrientFixtures $O6 @('projects.json')
foreach ($n in @('issues-global.json', 'issues-mine.json', 'projissues-p-alpha.json', 'projissues-p-beta.json')) {
    Copy-Item -LiteralPath (Join-Path $ORIENT_FIX 'issues-empty.json') -Destination (Join-Path $O6 $n) -Force
}
$r = Invoke-Orient $stub6
Assert-Eq 'orient: an all-empty tracker exits 0' 0 $r.Rc
Assert-Eq 'orient: an all-empty tracker still emits a schema-valid document' 'ok' (Test-OrientSchema $r.Doc)
Assert-Eq "orient: a valid empty answer is 'ok', never 'error'" 'ok' $r.Doc.surfaces.linear.status
Assert-Eq 'orient: an empty cut is NOT a degraded surface' `
    '0' (@($r.Doc.degraded | Where-Object { $_.StartsWith('linear:', [StringComparison]::Ordinal) }).Count).ToString()
Assert-Eq 'orient: every issue array is empty, and every project still reports' `
    '2 0 0 0' `
    (@(@($r.Doc.projects).Count,
       (@($r.Doc.projects | ForEach-Object { @($_.open_issues).Count } | Measure-Object -Sum).Sum + 0),
       @($r.Doc.projectless_open_issues).Count,
       @($r.Doc.mine_in_progress).Count) -join ' ')
# Nothing open anywhere is not an anomaly — the empty-project carve-out in the
# backlog anomaly must hold when EVERY project is empty.
Assert-Eq 'orient: an all-empty tracker raises no anomalies' '0' (@($r.Doc.anomalies).Count).ToString()

# The same with an empty PROJECTS list too — all six array keys empty at once.
$O7 = New-OrientTmp; $stub7 = New-OrientStub $O7
foreach ($n in @('projects.json', 'issues-global.json', 'issues-mine.json')) {
    Copy-Item -LiteralPath (Join-Path $ORIENT_FIX 'issues-empty.json') -Destination (Join-Path $O7 $n) -Force
}
$r = Invoke-Orient $stub7
Assert-Eq 'orient: an empty projects list exits 0' 0 $r.Rc
Assert-Eq 'orient: an empty projects list keeps the surface ok with no degraded entries' `
    'ok 0' `
    ("$($r.Doc.surfaces.linear.status) " + (@($r.Doc.degraded | Where-Object { $_.StartsWith('linear:', [StringComparison]::Ordinal) }).Count))
# `-is [Array]` on the PARSED document: an emitted `null` would fail this, and so
# would a scalar produced by a collection that collapsed on the way out.
$O7_ARRAYS = @('projects', 'projectless_open_issues', 'mine_in_progress', 'anomalies', 'memory_pointers', 'degraded')
$o7bad = @($O7_ARRAYS | Where-Object { -not ($r.Doc.$_ -is [System.Array] -or $r.Doc.$_ -is [System.Collections.IList]) })
Assert-Eq 'orient: every array-typed key is an empty ARRAY, never null' '' ($o7bad -join ',')

# ============================ MALFORMED PAYLOAD ==============================
# The tracker wrapper validates only that the payload is a top-level ARRAY. A
# well-formed-but-wrong body (`["unexpected"]` — a CLI version change, an error
# envelope, a truncated write) therefore reaches the normalizers. Non-object
# elements are DROPPED; every array key must survive as an ARRAY and the
# document must stay a valid orient/v1 on exit 0.
$O8 = New-OrientTmp; $stub8 = New-OrientStub $O8
Copy-OrientFixtures $O8 @('projects.json', 'projissues-p-alpha.json', 'projissues-p-beta.json', 'issues-mine.json')
Copy-Item -LiteralPath (Join-Path $ORIENT_FIX 'issues-nonobject.json') -Destination (Join-Path $O8 'issues-global.json') -Force
$r = Invoke-Orient $stub8 @('--memory-dir', $MEMFIX)
Assert-Eq 'orient: a non-object payload element still exits 0' 0 $r.Rc
Assert-Eq 'orient: a non-object payload element still emits a schema-valid document' 'ok' (Test-OrientSchema $r.Doc)
Assert-Eq 'orient: the document is parseable JSON, not a truncated write' 'orient/v1' $r.Doc.schema
$o8bad = @($O7_ARRAYS | Where-Object { -not ($r.Doc.$_ -is [System.Array] -or $r.Doc.$_ -is [System.Collections.IList]) })
Assert-Eq 'orient: every array-typed key survives a malformed payload as an ARRAY' '' ($o8bad -join ',')
# The non-object element is DROPPED, not normalized into an empty-string row —
# an all-empty issue row would be indistinguishable from a real issue with
# missing fields.
Assert-Eq 'orient: the non-object element is dropped, not normalized into a blank row' `
    '0' (@($r.Doc.projectless_open_issues).Count).ToString()
# The surfaces that were fine must still report their real content.
Assert-Eq 'orient: a malformed global sweep does not erase the per-project cut' `
    '2' (@($r.Doc.projects).Count).ToString()
Assert-Eq 'orient: a malformed global sweep does not erase the memory surface' `
    '2' (@($r.Doc.memory_pointers).Count).ToString()

# A non-object element in the PROJECTS payload is the same class of defect.
$O9 = New-OrientTmp; $stub9 = New-OrientStub $O9
Copy-OrientFixtures $O9 @('issues-global.json', 'issues-mine.json')
Copy-Item -LiteralPath (Join-Path $ORIENT_FIX 'issues-nonobject.json') -Destination (Join-Path $O9 'projects.json') -Force
$r = Invoke-Orient $stub9
Assert-Eq 'orient: a non-object projects element still exits 0' 0 $r.Rc
Assert-Eq 'orient: a non-object projects element still emits a schema-valid document' 'ok' (Test-OrientSchema $r.Doc)
Assert-Eq 'orient: the non-object project is dropped rather than emitted as a blank project' `
    '0' (@($r.Doc.projects).Count).ToString()

# ============================ UNPROBEABLE MEMORY DIR =========================
# $ErrorActionPreference is 'Stop' for the whole script, so the memory-dir
# Test-Path probe promotes a provider/access error into a TERMINATING error. Run
# outside a try that meant the process died with NO JSON on stdout — a helper
# whose entire contract is "degrades, never fails" failing hardest on the one
# input it cannot control. Contained, it is the memory surface's error path.
#
# Skipped where the failure cannot be provoked: on Windows (no mode 000), as
# root (permissions bypassed), or on a filesystem that ignores the mode — the
# in-process probe below is the positive control for exactly that.
$ORIENT_LOCKED_LABEL = 'orient: an unprobeable memory dir degrades instead of killing the run'
$ORIENT_ROOTISH = $false
if (-not $IsWindows) {
    try { $ORIENT_ROOTISH = ((& id -u) -eq '0') } catch { $ORIENT_ROOTISH = $false }
}
if ($IsWindows) {
    _Skip $ORIENT_LOCKED_LABEL 'Windows — mode 000 has no analogue here'
} elseif ($ORIENT_ROOTISH) {
    _Skip $ORIENT_LOCKED_LABEL 'running as root — mode 000 does not deny access'
} else {
    $O10 = New-OrientTmp
    $O10_LOCK = Join-Path $O10 'locked'
    $O10_MEM = Join-Path $O10_LOCK 'memory'
    New-Item -ItemType Directory -Path $O10_MEM -Force | Out-Null
    & chmod 000 $O10_LOCK
    # Positive control, in THIS process: does the probe really throw here? If the
    # filesystem ignores the mode, the gap cannot be exercised and a green
    # assertion would prove nothing. -ErrorAction Stop reproduces the script's
    # own $ErrorActionPreference = 'Stop'; without it the runner's 'Continue'
    # makes the access error NON-terminating, the catch never fires, and this
    # control would report "cannot provoke" on a filesystem that provokes fine.
    $O10_THREW = $false
    try { [void](Test-Path -LiteralPath $O10_MEM -PathType Container -ErrorAction Stop) } catch { $O10_THREW = $true }
    if (-not $O10_THREW) {
        _Skip $ORIENT_LOCKED_LABEL 'the probe does not error on the mode-000 ancestor on this filesystem'
    } else {
        $r = Invoke-Orient $stub1 @('--memory-dir', $O10_MEM)
        Assert-Eq 'orient: an unprobeable memory dir still exits 0' 0 $r.Rc
        Assert-Eq 'orient: an unprobeable memory dir still emits a schema-valid document' 'ok' (Test-OrientSchema $r.Doc)
        Assert-Eq 'orient: an unprobeable memory dir marks the memory surface error, not ok' `
            'error' $r.Doc.surfaces.memory.status
        Assert-Contains 'orient: an unprobeable memory dir is NAMED in degraded' `
            ((@($r.Doc.degraded)) -join "`n") 'memory: dir not readable'
        Assert-Eq 'orient: an unprobeable memory dir yields no pointers, not a missing key' `
            '0' (@($r.Doc.memory_pointers).Count).ToString()
        # The tracker surface is independent — a dead memory probe must not take it down.
        Assert-Eq 'orient: an unprobeable memory dir leaves the tracker surface intact' `
            'ok' $r.Doc.surfaces.linear.status
    }
    & chmod 755 $O10_LOCK
    Remove-Item -LiteralPath $O10 -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================ ARGUMENT CONTRACT ==============================
# A non-zero exit means the SCRIPT could not run — never that a surface was down.
$bad = (& pwsh -NoProfile -File $ORIENT '--nope' 2>&1 | Out-String)
Assert-Eq 'orient: unknown argument exits 2' 2 $LASTEXITCODE
Assert-Contains 'orient: unknown argument names itself' $bad 'unknown argument: --nope'
& pwsh -NoProfile -File $ORIENT '--memory-dir' 2>&1 | Out-Null
Assert-Eq 'orient: value-less --memory-dir exits 2 (no self-loop)' 2 $LASTEXITCODE
& pwsh -NoProfile -File $ORIENT '--lineark' 2>&1 | Out-Null
Assert-Eq 'orient: value-less --lineark exits 2 (no self-loop)' 2 $LASTEXITCODE

foreach ($d in @($O1, $O2, $O2N, $O3, $O4, $O5, $O6, $O7, $O8, $O9)) {
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}
