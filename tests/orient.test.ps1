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
# Hermetic: --linear-cli is pointed at a stub .ps1 serving the JSON fixtures
# under tests/fixtures/orient/ — no live tracker, no token. Both twins read the
# SAME fixture files, so a shape disagreement between them cannot hide behind
# differently-worded inline heredocs.
#
# Three things are pinned, and the second and third matter as much as the first:
#   SHAPE — the emitted document always carries every top-level key with the
#   right TYPE (a structural assertion over the parsed object, not a prose
#   match). A caller parses one shape or none; a key that vanishes under a
#   degraded surface is the bug this suite exists to prevent.
#   PAYLOAD SHAPE TOLERANCE — schpet/linear-cli wraps every list in an OBJECT
#   {"nodes":[...]}; the helper unwraps `.nodes` AND still accepts a bare array.
#   Issue rows carry `state` as an OBJECT {name,type}, `assignee` as an object
#   or null, and a numeric `priority` beside a human `priorityLabel` — one
#   normalizer flattens all of it, so nothing ever reads `.state.name` unguarded
#   and the normalized row reads "Medium", not "3".
#   DEGRADATION — CLI absent, CLI erroring, whoami unparseable, memory dir
#   absent: each must still emit a valid document on exit 0 with a NAMED
#   `degraded` entry.
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

# New-OrientStub <dir> — linear-cli stub .ps1. It emulates the schpet/linear-cli
# argv surface orient.ps1 issues (each list call arrives with `--json` appended;
# `auth whoami` arrives plain), matching on the STABLE discriminators — the
# first two tokens plus the presence of --project / --assignee — rather than the
# full argv string. It serves, from its own directory:
#   project list ...                  -> projects.json
#   issue query ... (no filter)       -> issues-global.json    (global sweep)
#   issue query ... --assignee <name> -> issues-mine.json      (mine cut)
#   issue query ... --project <id>    -> projissues-<id>.json  (per project)
#   auth whoami                       -> whoami.txt            (plain text)
# A missing file exits 1, so a fixture set can make any single cut fail.
function New-OrientStub([string]$d) {
    $stub = Join-Path $d 'stub.ps1'
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgList = @())
$d = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Content -LiteralPath (Join-Path $d 'calls.log') -Value ("CALL " + ($ArgList -join ' '))
$proj = ''
$assignee = $false
for ($i = 0; $i -lt $ArgList.Count; $i++) {
    if ($ArgList[$i] -eq '--project' -and $i + 1 -lt $ArgList.Count) { $proj = $ArgList[$i + 1] }
    if ($ArgList[$i] -eq '--assignee') { $assignee = $true }
}
if ($ArgList.Count -ge 2 -and $ArgList[0] -eq 'project' -and $ArgList[1] -eq 'list') {
    $f = Join-Path $d 'projects.json'
    if (Test-Path -LiteralPath $f) { Get-Content -Raw $f; exit 0 }
    exit 1
}
if ($ArgList.Count -ge 2 -and $ArgList[0] -eq 'auth' -and $ArgList[1] -eq 'whoami') {
    $f = Join-Path $d 'whoami.txt'
    if (Test-Path -LiteralPath $f) { Get-Content -Raw $f; exit 0 }
    exit 1
}
if ($ArgList.Count -ge 2 -and $ArgList[0] -eq 'issue' -and $ArgList[1] -eq 'query') {
    if ($proj -ne '') { $f = Join-Path $d ("projissues-{0}.json" -f $proj) }
    elseif ($assignee) { $f = Join-Path $d 'issues-mine.json' }
    else { $f = Join-Path $d 'issues-global.json' }
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
                   'issues-global.json', 'issues-mine.json', 'whoami.txt')
    }
    foreach ($n in $Names) {
        Copy-Item -LiteralPath (Join-Path $ORIENT_FIX $n) -Destination (Join-Path $d $n) -Force
    }
}

# Invoke-Orient <stub> [flags] — stdout only, exit code captured, parsed doc.
function Invoke-Orient([string]$stub, [string[]]$flags = @()) {
    $argv = @('--linear-cli', $stub) + $flags
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
    if (-not (_Has $doc 'safety')) { return 'BAD' }
    if (-not (_Str $doc.safety 'posture')) { return 'BAD' }
    if (@('safe', 'tightened') -notcontains $doc.safety.posture) { return 'BAD' }
    if (-not (_Str $doc.safety 'detection')) { return 'BAD' }
    if (@('state-files', 'none-configured') -notcontains $doc.safety.detection) { return 'BAD' }
    if (-not (_Has $doc.safety 'unresolved')) { return 'BAD' }
    if (-not (_Arr $doc.safety 'tightenings')) { return 'BAD' }
    foreach ($t in @($doc.safety.tightenings)) {
        foreach ($f in @('name', 'path', 'detail')) { if (-not (_Str $t $f)) { return 'BAD' } }
    }
    if (-not (_Has $doc 'telemetry')) { return 'BAD' }
    if ($null -ne $doc.telemetry) {
        if (-not (_Has $doc.telemetry 'memory_index_bytes')) { return 'BAD' }
        $mib = $doc.telemetry.memory_index_bytes
        if ($null -ne $mib -and -not ($mib -is [int] -or $mib -is [long])) { return 'BAD' }
        if (-not (_Arr $doc.telemetry 'project_note_bodies')) { return 'BAD' }
        foreach ($b in @($doc.telemetry.project_note_bodies)) {
            if (-not (_Str $b 'file')) { return 'BAD' }
            if (-not (_Has $b 'bytes')) { return 'BAD' }
        }
        if (-not (_Has $doc.telemetry 'project_note_total_bytes')) { return 'BAD' }
    }
    return 'ok'
}

$MEMFIX = Join-Path $ORIENT_FIX 'memory'

# ============================ NOMINAL ========================================
$O1 = New-OrientTmp; $stub1 = New-OrientStub $O1; Copy-OrientFixtures $O1
$r = Invoke-Orient $stub1 @('--memory-dir', $MEMFIX)

Assert-Eq 'orient: nominal run exits 0' 0 $r.Rc
Assert-Eq 'orient: nominal document satisfies the orient/v1 schema' 'ok' (Test-OrientSchema $r.Doc)
Assert-Eq 'orient: a healthy tracker surface reports the ok detail with its counts' `
    'linear CLI ok: 2 project(s), 5 open issue(s) in the global sweep' `
    $r.Doc.surfaces.linear.detail

# --- project-first Linear cut -------------------------------------------------
# p-alpha's fixture row carries schpet's camelCase `slugId`; p-beta's carries the
# legacy `slug_id` — the fallback the normalizer keeps for fixture/twin parity.
Assert-Eq 'orient: projects are emitted in tracker order with slug ids (slugId + slug_id fallback)' `
    'p-alpha:Alpha Arc:alpha-1 p-beta:Beta Arc:beta-2' `
    ((@($r.Doc.projects | ForEach-Object { "$($_.id):$($_.name):$($_.slug_id)" })) -join ' ')
Assert-Eq 'orient: an OBJECT-shaped state flattens to its name' `
    'ABC-1=In Progress ABC-2=Backlog' `
    ((@($r.Doc.projects[0].open_issues | ForEach-Object { "$($_.identifier)=$($_.state)" })) -join ' ')
# schpet rows carry priority as a NUMBER (3) beside priorityLabel ("Medium");
# the normalized row must read the label, never the number.
Assert-Eq 'orient: a numeric priority defers to priorityLabel in the normalized row' `
    'Medium' $r.Doc.projects[0].open_issues[1].priority
Assert-Eq 'orient: a null priority with no label normalizes to an empty string, not null' `
    '' $r.Doc.projects[1].open_issues[1].priority
Assert-Eq 'orient: a null assignee normalizes to an empty string' `
    '' $r.Doc.projects[1].open_issues[0].assignee

# --- mine cut plumbing --------------------------------------------------------
# The mine cut's --assignee value must be the display name whoami served — the
# whoami parse feeding the query is the seam this pins.
Assert-Contains 'orient: the mine cut queries by the whoami-served display name' `
    ((Get-Content -LiteralPath (Join-Path $O1 'calls.log')) -join "`n") `
    'issue query --all-teams --assignee Sample Assignee'

# --- global-open reconciliation ----------------------------------------------
# ABC-9 is in the global sweep and in NO project's list. A projects-only orient
# drops it silently; this is the cut that catches it.
Assert-Eq 'orient: an issue in the global sweep but in no project is projectless' `
    'ABC-9' ((@($r.Doc.projectless_open_issues | ForEach-Object { $_.identifier })) -join ' ')
Assert-Eq 'orient: issues that DO belong to a project are not projectless' `
    '0' (@($r.Doc.projectless_open_issues | Where-Object { @('ABC-1','ABC-2','ABC-3','ABC-4') -contains $_.identifier }).Count).ToString()

# --- mine + In Progress -------------------------------------------------------
# The mine fixture also contains ABC-9 (Todo); only the In Progress row counts.
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

# --- env seam -----------------------------------------------------------------
# $env:LINEAR_CLI_BIN is the env-side injection seam (same as the hygiene and
# currentness twins).
$savedCliBin = $env:LINEAR_CLI_BIN
try {
    $env:LINEAR_CLI_BIN = $stub1
    $outEnv = (& pwsh -NoProfile -File $ORIENT 2>$null | Out-String)
    $docEnv = $null
    try { $docEnv = $outEnv | ConvertFrom-Json } catch { $docEnv = $null }
    Assert-Eq 'orient: the LINEAR_CLI_BIN env seam reaches the tracker seam' `
        'ok' $docEnv.surfaces.linear.status
} finally {
    if ($null -eq $savedCliBin) { Remove-Item Env:LINEAR_CLI_BIN -ErrorAction SilentlyContinue } else { $env:LINEAR_CLI_BIN = $savedCliBin }
}

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
# schpet wraps every list in an OBJECT {"nodes":[...]} — that is what every
# primary fixture serves. A BARE ARRAY is accepted too (fixture simplicity, and
# a shape the unwrap must not reject). Serve a bare-array payload through the
# per-project path and require the same normalized rows back.
$O2 = New-OrientTmp; $stub2 = New-OrientStub $O2
Copy-OrientFixtures $O2 @('projects.json', 'issues-global.json', 'issues-mine.json', 'whoami.txt')
Copy-Item -LiteralPath (Join-Path $ORIENT_FIX 'issues-bare-array.json') -Destination (Join-Path $O2 'projissues-p-alpha.json') -Force
Copy-Item -LiteralPath (Join-Path $ORIENT_FIX 'issues-bare-array.json') -Destination (Join-Path $O2 'projissues-p-beta.json') -Force
$r = Invoke-Orient $stub2
Assert-Eq 'orient: a bare-array payload (no nodes wrapper) is accepted and normalized' `
    'ABC-7=In Progress' `
    ((@($r.Doc.projects[0].open_issues | ForEach-Object { "$($_.identifier)=$($_.state)" })) -join ' ')
Assert-Eq 'orient: bare-array payloads still satisfy the schema' 'ok' (Test-OrientSchema $r.Doc)

# An object-shaped field with NO `name` (e.g. `assignee: {"id": "usr_123"}`)
# flattens to the EMPTY STRING, never to a stringified object. Get-Flat fell
# through to "$v" here and emitted PowerShell's own object rendering
# (`@{id=usr_123}`) where the bash twin's `.name // ""` yields "". See the bash
# control in tests/orient.test.sh.
$O2N = New-OrientTmp; $stub2n = New-OrientStub $O2N
Copy-OrientFixtures $O2N @('projects.json', 'issues-global.json', 'issues-mine.json', 'whoami.txt')
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
Copy-OrientFixtures $O3 @('projects.json', 'projissues-p-alpha.json', 'projissues-p-beta.json', 'issues-mine.json', 'whoami.txt')
Copy-Item -LiteralPath (Join-Path $ORIENT_FIX 'issues-global-short.json') -Destination (Join-Path $O3 'issues-global.json') -Force
$r = Invoke-Orient $stub3
Assert-Eq 'orient: a disagreeing sweep still exits 0' 0 $r.Rc
Assert-Contains 'orient: project issues absent from the global sweep raise open-issue-count-mismatch' `
    ((@($r.Doc.anomalies | ForEach-Object { "$($_.type)|$($_.detail)" })) -join "`n") `
    'open-issue-count-mismatch|3 identifier(s) listed under a project but absent from the global open sweep (global=1, project-union=4): ABC-2, ABC-3, ABC-4'
Assert-Eq 'orient: the short sweep leaves nothing projectless' `
    '0' (@($r.Doc.projectless_open_issues).Count).ToString()

# ============================ DEGRADATION ====================================

# --- linear CLI not on PATH ---------------------------------------------------
$r = Invoke-Orient (Join-Path $O1 'definitely-absent.ps1') @('--memory-dir', $MEMFIX)
Assert-Eq 'orient: absent linear CLI still exits 0' 0 $r.Rc
Assert-Eq 'orient: absent linear CLI still emits a schema-valid document' 'ok' (Test-OrientSchema $r.Doc)
Assert-Eq 'orient: absent linear CLI marks the surface absent' 'absent' $r.Doc.surfaces.linear.status
Assert-Contains 'orient: absent linear CLI is NAMED in degraded' `
    ((@($r.Doc.degraded)) -join "`n") 'linear: linear CLI not on PATH'
Assert-Contains 'orient: the absent detail points at the injection seam and setup doc' `
    $r.Doc.surfaces.linear.detail 'linear CLI not found (--linear-cli or PATH):'
Assert-Eq 'orient: absent linear CLI yields empty Linear arrays, not missing keys' `
    '0 0 0' (@(@($r.Doc.projects).Count, @($r.Doc.projectless_open_issues).Count, @($r.Doc.mine_in_progress).Count) -join ' ')
Assert-Eq 'orient: the memory surface still reports when Linear is absent' `
    '2' (@($r.Doc.memory_pointers).Count).ToString()

# --- linear CLI on PATH but every call fails ----------------------------------
# The stub exits 1 when its fixture file is missing, so an empty stub dir is a
# tracker that answers with failures rather than one that is not installed —
# a DIFFERENT surface status, and the distinction is the operator's next action.
# whoami fails too, so the mine cut degrades via the whoami path (no display
# name means no --assignee query is even attempted).
$O4 = New-OrientTmp; $stub4 = New-OrientStub $O4   # no fixtures copied
$r = Invoke-Orient $stub4
Assert-Eq 'orient: an erroring linear CLI still exits 0' 0 $r.Rc
Assert-Eq 'orient: an erroring linear CLI still emits a schema-valid document' 'ok' (Test-OrientSchema $r.Doc)
Assert-Eq "orient: an erroring linear CLI is 'error', distinct from 'absent'" 'error' $r.Doc.surfaces.linear.status
Assert-Eq 'orient: the error detail points at degraded' `
    'one or more linear CLI calls failed — see degraded' $r.Doc.surfaces.linear.detail
Assert-Eq 'orient: every failed linear CLI cut is named separately in degraded' `
    'linear: project list failed|linear: global issue query failed|linear: whoami display name unavailable — mine cut skipped|linear: reconciliation unavailable — incomplete project cut' `
    ((@($r.Doc.degraded | Where-Object { $_.StartsWith('linear:', [StringComparison]::Ordinal) })) -join '|')

# --- whoami missing/unparseable: ONLY the mine cut degrades -------------------
# Everything else answers; whoami does not. The mine cut is skipped (it cannot
# even form its --assignee query), the surface is error — but the project cut,
# the global sweep, and the reconciliation are UNAFFECTED: a broken identity
# lookup must not blind the whole kickoff.
$OW = New-OrientTmp; $stubW = New-OrientStub $OW
Copy-OrientFixtures $OW @('projects.json', 'projissues-p-alpha.json', 'projissues-p-beta.json', 'issues-global.json', 'issues-mine.json')
$r = Invoke-Orient $stubW
Assert-Eq 'orient: a whoami failure still exits 0' 0 $r.Rc
Assert-Eq 'orient: a whoami failure still emits a schema-valid document' 'ok' (Test-OrientSchema $r.Doc)
Assert-Contains 'orient: the skipped mine cut is NAMED in degraded' `
    ((@($r.Doc.degraded)) -join "`n") 'linear: whoami display name unavailable — mine cut skipped'
Assert-Eq 'orient: a whoami failure marks the surface error with an empty mine cut' `
    'error 0' "$($r.Doc.surfaces.linear.status) $(@($r.Doc.mine_in_progress).Count)"
Assert-Eq 'orient: the project cut survives a whoami failure' `
    'Alpha Arc=2 Beta Arc=2' `
    ((@($r.Doc.projects | ForEach-Object { "$($_.name)=$(@($_.open_issues).Count)" })) -join ' ')
Assert-Eq 'orient: the reconciliation survives a whoami failure' `
    'ABC-9' ((@($r.Doc.projectless_open_issues | ForEach-Object { $_.identifier })) -join ' ')
Assert-NotContains 'orient: a whoami failure does not suppress the reconciliation' `
    ((@($r.Doc.degraded)) -join "`n") 'reconciliation unavailable'

# --- whoami parses but the mine query itself fails ----------------------------
$OM = New-OrientTmp; $stubM = New-OrientStub $OM
Copy-OrientFixtures $OM @('projects.json', 'projissues-p-alpha.json', 'projissues-p-beta.json', 'issues-global.json', 'whoami.txt')
$r = Invoke-Orient $stubM
Assert-Contains 'orient: a failed mine query is named distinctly from a failed whoami' `
    ((@($r.Doc.degraded)) -join "`n") 'linear: issue query --assignee (mine) failed'
Assert-Eq 'orient: a failed mine query leaves the other cuts intact' `
    'error 2 ABC-9' `
    "$($r.Doc.surfaces.linear.status) $(@($r.Doc.projects).Count) $((@($r.Doc.projectless_open_issues | ForEach-Object { $_.identifier })) -join ',')"

# --- one project's issue list fails -------------------------------------------
# The project must still appear (with an empty open set) and the failure must be
# named against that project, not collapsed into a generic tracker outage.
$O5 = New-OrientTmp; $stub5 = New-OrientStub $O5
Copy-OrientFixtures $O5 @('projects.json', 'projissues-p-alpha.json', 'issues-global.json', 'issues-mine.json', 'whoami.txt')
$r = Invoke-Orient $stub5
Assert-Eq 'orient: a project whose issue list fails still appears with an empty open set' `
    'Alpha Arc=2 Beta Arc=0' `
    ((@($r.Doc.projects | ForEach-Object { "$($_.name)=$(@($_.open_issues).Count)" })) -join ' ')
Assert-Contains 'orient: the failing project is named in degraded' `
    ((@($r.Doc.degraded)) -join "`n") 'linear: issue query failed for project Beta Arc'
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
# project with nothing open, a mine cut with nothing assigned. `{"nodes":[]}`
# back from every cut must read as `ok` with ZERO degraded entries and empty
# arrays.
#
# This is the PS-side regression the bash twin never had: PowerShell UNWRAPS a
# returned collection into the pipeline, so the tracker wrapper's plain
# `return @(… | ConvertFrom-Json)` turned a valid empty list into $null — the
# same value the wrapper uses for "the call failed". Every empty cut was counted
# as an outage: surfaces.linear.status = 'error' plus degraded entries, while
# bash reported 'ok' on the identical fixtures.
$O6 = New-OrientTmp; $stub6 = New-OrientStub $O6
Copy-OrientFixtures $O6 @('projects.json', 'whoami.txt')
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
Copy-OrientFixtures $O7 @('whoami.txt')
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
# The tracker wrapper validates only that the payload unwraps to a top-level
# ARRAY. A well-formed-but-wrong body (`["unexpected"]` — a CLI version change,
# an error envelope, a truncated write) therefore reaches the normalizers.
# Non-object elements are DROPPED; every array key must survive as an ARRAY and
# the document must stay a valid orient/v1 on exit 0.
$O8 = New-OrientTmp; $stub8 = New-OrientStub $O8
Copy-OrientFixtures $O8 @('projects.json', 'projissues-p-alpha.json', 'projissues-p-beta.json', 'issues-mine.json', 'whoami.txt')
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
Copy-OrientFixtures $O9 @('issues-global.json', 'issues-mine.json', 'whoami.txt')
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

# ============================ SAFETY POSTURE =================================
# The Mode-1 "Safety posture" line used to restate DECLARED policy ("safe").
# This key makes it report DETECTED state instead: each configured guardrail
# state file that exists and is non-empty is one named tightening. The three
# cases that matter are 0 files (the default-safe floor), 1, and 2 — plus the
# negative cases (configured-but-absent, configured-but-empty) that must NOT
# count, because a stale or empty state file claiming a tightening is the same
# class of lie as declaring one that was never enforced.
$OS1 = New-OrientTmp; $stubS = New-OrientStub $OS1; Copy-OrientFixtures $OS1

$r = Invoke-Orient $stubS
Assert-Eq 'orient: no guardrail state configured still exits 0' 0 $r.Rc
Assert-Eq 'orient: no guardrail state configured reports safe/none-configured' `
    'safe none-configured 0 0' `
    (@($r.Doc.safety.posture, $r.Doc.safety.detection, (@($r.Doc.safety.tightenings).Count).ToString(), "$($r.Doc.safety.unresolved)") -join ' ')

$OSF = New-OrientTmp
[System.IO.File]::WriteAllText((Join-Path $OSF 'scope.state'), "edits frozen to the work dir`n")
[System.IO.File]::WriteAllText((Join-Path $OSF 'careful.state'), "careful mode: confirm destructive commands`nsecond line ignored`n")
[System.IO.File]::WriteAllText((Join-Path $OSF 'empty.state'), '')

# 1 file — posture tightened, named by BASENAME, detail = its FIRST line.
$env:GUARDRAIL_STATE_FILES = (Join-Path $OSF 'scope.state')
$r = Invoke-Orient $stubS
Assert-Eq 'orient: one guardrail state file tightens the posture' `
    'tightened state-files 1' `
    (@($r.Doc.safety.posture, $r.Doc.safety.detection, (@($r.Doc.safety.tightenings).Count).ToString()) -join ' ')
Assert-Eq 'orient: a tightening is named by basename and detailed by its first line' `
    'scope.state|edits frozen to the work dir' `
    ("$(@($r.Doc.safety.tightenings)[0].name)|$(@($r.Doc.safety.tightenings)[0].detail)")
Assert-Eq 'orient: a tightened document still satisfies the schema' 'ok' (Test-OrientSchema $r.Doc)

# 2 files, plus an EMPTY one and an ABSENT one in the same list: only the two
# non-empty existing files count, and the detail is the first line only.
$env:GUARDRAIL_STATE_FILES = @(
    (Join-Path $OSF 'scope.state'), (' ' + (Join-Path $OSF 'careful.state')),
    (Join-Path $OSF 'empty.state'), (Join-Path $OSF 'nope.state')) -join ','
$r = Invoke-Orient $stubS
Assert-Eq 'orient: two guardrail state files yield two named tightenings' `
    'scope.state careful.state' `
    ((@($r.Doc.safety.tightenings | ForEach-Object { $_.name })) -join ' ')
Assert-Eq 'orient: an empty or absent configured state file is NOT a tightening' `
    '2' (@($r.Doc.safety.tightenings).Count).ToString()
Assert-Eq 'orient: only the first line of a state file becomes the detail' `
    'careful mode: confirm destructive commands' `
    (@($r.Doc.safety.tightenings)[1].detail)

# The key can only ADD tightenings: there is no configured value that reports a
# posture looser than the default. But "configured and inactive" must NOT read
# as "nothing configured" — the unresolved count is what keeps a broken
# guardrail wiring from presenting as a clean default-safe run.
$env:GUARDRAIL_STATE_FILES = @((Join-Path $OSF 'empty.state'), (Join-Path $OSF 'nope.state')) -join ','
$r = Invoke-Orient $stubS
Assert-Eq 'orient: configured-but-inactive guardrails still report the safe floor' `
    'safe' $r.Doc.safety.posture
Assert-Eq 'orient: configured-but-unresolved paths are COUNTED, not silently equal to unconfigured' `
    'state-files 2' "$($r.Doc.safety.detection) $($r.Doc.safety.unresolved)"

# A RELATIVE path is never resolved against the caller's cwd — a posture that
# changes with the launch directory is not a detected posture. It counts as
# unresolved, exactly like a missing one.
$env:GUARDRAIL_STATE_FILES = 'scope.state'
$osPrevCwd = (Get-Location).Path
Set-Location -LiteralPath $OSF
try { $r = Invoke-Orient $stubS } finally { Set-Location -LiteralPath $osPrevCwd }
Assert-Eq 'orient: a relative guardrail path is unresolved, never cwd-resolved' `
    'safe 0 1' `
    (@($r.Doc.safety.posture, (@($r.Doc.safety.tightenings).Count).ToString(), "$($r.Doc.safety.unresolved)") -join ' ')

# PER-ENTRY quotes: the local.env read strips one pair from the WHOLE value, so
# individually-quoted paths arrive here still quoted. Both must still resolve.
$env:GUARDRAIL_STATE_FILES = ('"' + (Join-Path $OSF 'scope.state') + '", "' + (Join-Path $OSF 'careful.state') + '"')
$r = Invoke-Orient $stubS
Assert-Eq 'orient: individually-quoted paths are both detected, not silently corrupted' `
    'tightened 2 0' `
    (@($r.Doc.safety.posture, (@($r.Doc.safety.tightenings).Count).ToString(), "$($r.Doc.safety.unresolved)") -join ' ')

# DETAIL HARDENING. A control character in a state file must not ride into
# model-facing orient output.
[System.IO.File]::WriteAllText((Join-Path $OSF 'ctl.state'),
    ("scope active" + [char]27 + "[31mRED" + [char]7 + " tail`nsecond line`n"))
$env:GUARDRAIL_STATE_FILES = (Join-Path $OSF 'ctl.state')
$r = Invoke-Orient $stubS
Assert-Eq 'orient: control characters are stripped from a state-file detail' `
    'scope active[31mRED tail' (@($r.Doc.safety.tightenings)[0].detail)
Assert-Eq 'orient: a control-char state file still satisfies the schema' 'ok' (Test-OrientSchema $r.Doc)

# A first line LONGER than the truncation limit and made of MULTI-BYTE text: the
# bash twin's byte-offset truncate must not split a UTF-8 sequence, because an
# invalid tail makes its JSON assembler drop the record — and a dropped
# tightening reports `safe` for a run that is tightened. Both twins apply the
# same printable filter so the two details stay identical.
$osAccent = [string][char]0x00E9
[System.IO.File]::WriteAllText((Join-Path $OSF 'multi.state'), (($osAccent * 200) + "`n"))
$env:GUARDRAIL_STATE_FILES = (Join-Path $OSF 'multi.state')
$r = Invoke-Orient $stubS
Assert-Eq 'orient: an over-long multibyte first line still exits 0' 0 $r.Rc
Assert-Eq 'orient: an over-long multibyte detail never drops the tightening' `
    'tightened 1' "$($r.Doc.safety.posture) $(@($r.Doc.safety.tightenings).Count)"
Assert-Eq 'orient: a multibyte detail still emits a schema-valid document' 'ok' (Test-OrientSchema $r.Doc)

# A multi-GB newline-free state file must not stall the kickoff: the read is
# bounded before the first-line split. Size is modest here (the bound is 512
# bytes) — what is pinned is that the detail is TRUNCATED, not whole-file read.
[System.IO.File]::WriteAllText((Join-Path $OSF 'huge.state'), ('z' * 4000))
$env:GUARDRAIL_STATE_FILES = (Join-Path $OSF 'huge.state')
$r = Invoke-Orient $stubS
Assert-Eq 'orient: a newline-free state file yields a bounded 120-char detail' `
    120 (@($r.Doc.safety.tightenings)[0].detail.Length)
Remove-Item Env:\GUARDRAIL_STATE_FILES -ErrorAction SilentlyContinue

# ============================ TELEMETRY ======================================
# The O1 dynamic body reads are the expensive half of a kickoff and nothing
# measured them. Byte counts are asserted against PLANTED fixture notes, not
# against whatever the operator's real store happens to hold.
$OT = New-OrientTmp
[System.IO.File]::WriteAllText((Join-Path $OT 'MEMORY.md'), "INDEX`n")
[System.IO.File]::WriteAllText((Join-Path $OT 'project-a.md'), "---`ntype: project`nname: a`ndescription: d`n---`nAAAA`n")
[System.IO.File]::WriteAllText((Join-Path $OT 'project-b.md'), "---`ntype: project`nname: b`ndescription: d`n---`nBB`n")
[System.IO.File]::WriteAllText((Join-Path $OT 'reference-c.md'), "---`ntype: reference`n---`nnot counted`n")
$otA = (Get-Item -LiteralPath (Join-Path $OT 'project-a.md')).Length
$otB = (Get-Item -LiteralPath (Join-Path $OT 'project-b.md')).Length
$r = Invoke-Orient $stubS @('--memory-dir', $OT)
Assert-Eq 'orient: telemetry reports the memory index size' '6' "$($r.Doc.telemetry.memory_index_bytes)"
Assert-Eq 'orient: telemetry lists one body row per project-type note, in scan order' `
    "project-a.md=$otA project-b.md=$otB" `
    ((@($r.Doc.telemetry.project_note_bodies | ForEach-Object { "$($_.file)=$($_.bytes)" })) -join ' ')
Assert-Eq 'orient: telemetry totals the project-note bodies it listed' `
    "$($otA + $otB)" "$($r.Doc.telemetry.project_note_total_bytes)"
# A non-project note is read at orient as a pointer, not a body — it must not
# inflate the body budget the caller is being asked to watch.
Assert-Eq 'orient: a non-project note contributes no body row' `
    '0' (@($r.Doc.telemetry.project_note_bodies | Where-Object { $_.file -eq 'reference-c.md' }).Count).ToString()

# A store with no MEMORY.md still measures bodies; the index reads null, never 0
# (an absent index is not a zero-byte one).
$OT2 = New-OrientTmp
[System.IO.File]::WriteAllText((Join-Path $OT2 'project-x.md'), "---`ntype: project`n---`nX`n")
$r = Invoke-Orient $stubS @('--memory-dir', $OT2)
Assert-Eq 'orient: a store with no MEMORY.md reports a null index size, not 0' `
    'True' "$($null -eq $r.Doc.telemetry.memory_index_bytes)"

# An unresolved memory surface reports telemetry: null — an unmeasured cost is a
# named absence, never a misleading zero.
$r = Invoke-Orient $stubS
Assert-Eq 'orient: no memory dir reports telemetry null, not a zeroed reading' `
    'True' "$($null -eq $r.Doc.telemetry)"
$r = Invoke-Orient $stubS @('--memory-dir', (Join-Path $OS1 'no-such-memory-dir'))
Assert-Eq 'orient: an absent memory dir also reports telemetry null' `
    'True' "$($null -eq $r.Doc.telemetry)"

# ============================ KEY ORDERING ===================================
# Both new keys are APPENDED LAST so a consumer reading the document
# positionally keeps every pre-existing key at its old offset.
$r = Invoke-Orient $stubS @('--memory-dir', $OT)
Assert-Eq 'orient: safety + telemetry are appended LAST, after every pre-existing key' `
    'schema,surfaces,projects,projectless_open_issues,mine_in_progress,anomalies,memory_pointers,degraded,safety,telemetry' `
    ((@($r.Doc.PSObject.Properties | ForEach-Object { $_.Name })) -join ',')

# ============================ ARGUMENT CONTRACT ==============================
# A non-zero exit means the SCRIPT could not run — never that a surface was down.
$bad = (& pwsh -NoProfile -File $ORIENT '--nope' 2>&1 | Out-String)
Assert-Eq 'orient: unknown argument exits 2' 2 $LASTEXITCODE
Assert-Contains 'orient: unknown argument names itself' $bad 'unknown argument: --nope'
& pwsh -NoProfile -File $ORIENT '--memory-dir' 2>&1 | Out-Null
Assert-Eq 'orient: value-less --memory-dir exits 2 (no self-loop)' 2 $LASTEXITCODE
& pwsh -NoProfile -File $ORIENT '--linear-cli' 2>&1 | Out-Null
Assert-Eq 'orient: value-less --linear-cli exits 2 (no self-loop)' 2 $LASTEXITCODE

foreach ($d in @($O1, $O2, $O2N, $O3, $O4, $O5, $O6, $O7, $O8, $O9,
                 $OW, $OM, $OS1, $OSF, $OT, $OT2)) {
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}
