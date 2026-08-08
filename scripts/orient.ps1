#Requires -Version 7
<#
.SYNOPSIS
    PowerShell twin of orient.sh — deterministic ORIENTATION helper.

.DESCRIPTION
    Windows-native port of scripts/orient.sh. Identical flags, identical JSON
    shape, identical degradation semantics.

    session-agent's Mode 1 kickoff collects the same tracker + memory state
    every session, by hand, through a different sequence of ad-hoc CLI calls
    each time. That is the expensive half of the spine: the call order drifts, a
    surface that is down gets narrated instead of named, and the model spends
    context deciding HOW to look rather than reading what it found. This script
    does the collection once, deterministically, and emits ONE compact JSON
    document the caller reads.

    What it emits (schema id `orient/v1`, top-level keys in stable order):

      schema                   "orient/v1"
      surfaces                 per-surface reachability: linear + memory, each
                               {status: ok|absent|error, detail: "<human>"}
      projects                 project-first cut: [{id, name, slug_id,
                               open_issues: [issue...]}] — one issues-list call
                               per project, in tracker order
      projectless_open_issues  open issues in the GLOBAL sweep that appear in no
                               project's list (identifier set difference) — the
                               reconciliation cut a projects-only orient drops.
                               Emitted as [] with a "reconciliation unavailable"
                               degraded entry when the project cut is INCOMPLETE
      mine_in_progress         assigned-to-me AND In Progress
      anomalies                [{type, subject, detail}] — see below
      memory_pointers          project-type memory notes: [{file, name, description}]
      degraded                 named degraded surfaces, e.g.
                               "linear: lineark not on PATH (lineark)"
      safety                   DETECTED per-run safety posture (see below)
      telemetry                orientation-cost measurement (see below)

    SAFETY POSTURE (appended last but one; schema id unchanged — additive).
      {posture: "safe"|"tightened",
       tightenings: [{name, path, detail}],
       detection: "state-files"|"none-configured"}
    The kickoff line this feeds must report what was DETECTED, not what policy
    declares. Detection reads $GUARDRAIL_STATE_FILES — a comma-separated list
    of absolute paths to the session-guardrail state files an operator's
    guardrail skill writes, from local.env (read as DATA, never imported) then
    the ambient env. Each configured path that exists and is NON-EMPTY is one
    tightening: name = its basename, detail = its first line (truncated ~120
    chars). No key configured -> posture "safe", detection "none-configured".

    The key can only ADD tightenings to the default-safe posture: there is no
    value of it that reports a LOOSER posture than "safe". Enforcement STRENGTH
    is harness-dependent and deliberately NOT claimed here — this helper
    reports the state files it can see, not whether a hook enforces them.

    TELEMETRY (appended last; informational, never a status).
      {memory_index_bytes, project_note_bodies: [{file, bytes}],
       project_note_total_bytes}
    The O1 dynamic body reads are the expensive half of a kickoff and no other
    surface measures them. Sizes come from the SAME memory dir this run already
    scans. `telemetry` is null when the memory surface did not resolve (an
    unmeasured cost is a named absence, never a misleading 0).

    An `issue` is normalized to {identifier, title, state, priority, assignee, url}.

    ANOMALY CLASSES. `project-idle-with-active-children` is NOT detectable here:
    `lineark projects list` carries no project state field (verified — it
    returns {id, name, slug_id, lead}), and paying a `projects read` per project
    to get one is check-state-currentness's job, not a kickoff helper's. The two
    classes a single-pass sweep CAN decide:
      all-issues-backlog-no-assignee  every open issue in a project is Backlog
                                      with no assignee — a project nobody is on
      open-issue-count-mismatch       an identifier appears under a project but
                                      not in the global open sweep, so the two
                                      cuts disagree about what is open

    RECONCILIATION INTEGRITY. The projectless cut is a set difference against the
    union of the per-project lists, so it is only meaningful when that union is
    COMPLETE. If the projects list failed, or ANY per-project issues call failed,
    the union is short by exactly the rows that are missing — and the difference
    would name real, correctly-filed issues as projectless while raising an
    open-issue-count-mismatch anomaly from the same hole. In that case the helper
    emits `projectless_open_issues: []`, adds the degraded entry
    "linear: reconciliation unavailable — incomplete project cut", and SUPPRESSES
    the count-mismatch anomaly for that run. A fully absent linear surface is not
    this case: every input is empty and the difference is honestly empty.

    DEGRADES, NEVER FAILS. A missing or erroring surface produces empty arrays,
    a named `degraded` entry, and STILL a valid `orient/v1` document on exit 0 —
    the caller must be able to parse one shape no matter what is down. A
    non-zero exit means the script itself could not run (bad argument), never
    that a surface was unreachable.

    Tracker access is the `lineark` CLI ONLY (linear/linear-setup.md §3.2) — no
    MCP. Override the binary with --lineark / -TrackerCli / $env:LINEARK_BIN;
    the hermetic tests inject a stub serving fixture JSON, so this runs without
    live credentials.

    Response shapes handled (verified against lineark, not assumed):
      projects list  -> [{id, name, slug_id, lead}]          NO state field
      issues list    -> [{identifier, ..., state: "Backlog"}] state is a BARE
                                                              STRING, Done and
                                                              Canceled hidden
      issues read    -> {..., state: {id, name}}              state is an OBJECT
    Every state read goes through one normalizer that accepts either shape.

.PARAMETER MemoryDir
    Memory store to scan for project-type notes (POSIX form: --memory-dir).
    Omit to skip the memory surface.

.PARAMETER TrackerCli
    Tracker CLI to invoke (POSIX form: --lineark). Default $env:LINEARK_BIN,
    else `lineark`.

    Named `TrackerCli`, not `Lineark`, on purpose: PowerShell's binder resolves
    a bare `--lineark` token to any parameter it prefix-matches, which would
    consume the flag natively and make a repeated `--lineark` hard-error
    "specified more than once" instead of reaching the parser below.
    `TrackerCli` is not prefix-matched by `--lineark`, so the flag falls through
    to $Rest where the twin's semantics live. (`--pretty` DOES prefix-match
    -Pretty and binds there; that is harmless — identical effect, no value
    token to swallow.)

.PARAMETER Pretty
    Indent the JSON (default: one compact line).

.NOTES
    Exit codes, parity with the bash twin:
      0  a valid orient/v1 document was emitted (degraded or not)
      2  the script could not run: bad argument

    The bash twin's "jq unavailable" exit-2 case has no PS analogue — this port
    parses with ConvertFrom-Json and emits with ConvertTo-Json — so that skip
    path is absent by construction, not by omission.
#>

# PositionalBinding=$false: without it the leading [string]$MemoryDir would
# swallow the first bare `--flag` token positionally before $Rest ever sees it,
# and the POSIX parser below would never run.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$MemoryDir = '',
    [string]$TrackerCli = '',
    [switch]$Pretty,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$global:LASTEXITCODE = 0

# lineark's documented ceiling. Not a flag: a kickoff sweep that needs paging is
# a different problem than this helper solves, and the count-mismatch anomaly
# surfaces the truncation rather than hiding it.
$Limit = 250

# --- argv ---------------------------------------------------------------------
# POSIX-style flag pass-through (mirror the bash twin's `while [ $# -gt 0 ]`).
# Every value-taking flag guards its argument BEFORE consuming two slots — a
# value-less flag would otherwise re-loop on itself forever.
$i = 0
while ($i -lt $Rest.Count) {
    switch -CaseSensitive ($Rest[$i]) {
        '--memory-dir' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('orient: --memory-dir needs a path'); exit 2
            }
            $MemoryDir = $Rest[$i + 1]; $i += 2
        }
        '--lineark' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('orient: --lineark needs a path'); exit 2
            }
            $TrackerCli = $Rest[$i + 1]; $i += 2
        }
        '--pretty' { $Pretty = [switch]$true; $i += 1 }
        default {
            [Console]::Error.WriteLine("orient: unknown argument: $($Rest[$i])"); exit 2
        }
    }
}

if ($TrackerCli -eq '') {
    $TrackerCli = if ($env:LINEARK_BIN) { $env:LINEARK_BIN } else { 'lineark' }
}

$degraded = [System.Collections.Generic.List[string]]::new()
$anomalies = [System.Collections.Generic.List[object]]::new()
$projectsOut = [System.Collections.Generic.List[object]]::new()
$memoryOut = [System.Collections.Generic.List[object]]::new()

function Add-Degraded([string]$entry) { $degraded.Add($entry) }
function Add-Anomaly([string]$type, [string]$subject, [string]$detail) {
    $anomalies.Add([ordered]@{ type = $type; subject = $subject; detail = $detail })
}

# The ONE state/field normalizer. `state` arrives as a bare string from
# `issues list` and as an object from `issues read`; `priority` and `assignee`
# can be absent or null. Everything downstream consumes this shape only.
function Get-Flat($obj, [string]$name) {
    if ($null -eq $obj) { return '' }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    $v = $p.Value
    if ($v -is [PSCustomObject]) {
        $np = $v.PSObject.Properties['name']
        if ($null -ne $np -and $null -ne $np.Value) { return "$($np.Value)" }
        # NO `name` field: return EMPTY, matching the bash twin's `.name // ""`.
        # `"$v"` here stringified the object itself (`@{id=usr_123}`) into the
        # emitted document — a value the bash twin never produces, so the two
        # renders disagreed on a nameless assignee/state object.
        return ''
    }
    return "$v"
}

# Test-OrientObject — is this array element an OBJECT (the only element shape an
# issue/project row can have)? A well-formed-but-wrong payload (`["unexpected"]`)
# passes the array-ness check in Invoke-Tracker and would otherwise normalize
# into a row of empty strings. Non-objects are SKIPPED, matching the bash twin's
# `select(type == "object")` guards.
function Test-OrientObject($it) {
    return ($it -is [System.Management.Automation.PSCustomObject])
}

function ConvertTo-OrientIssue($it) {
    return [ordered]@{
        identifier = (Get-Flat $it 'identifier')
        title      = (Get-Flat $it 'title')
        state      = (Get-Flat $it 'state')
        priority   = (Get-Flat $it 'priority')
        assignee   = (Get-Flat $it 'assignee')
        url        = (Get-Flat $it 'url')
    }
}

# Invoke-Tracker — run the tracker CLI, require a JSON ARRAY back. A non-zero
# exit, an exec failure (wrong arch, not executable — $ErrorActionPreference is
# 'Stop', so those THROW rather than setting $LASTEXITCODE), or a non-array
# payload are all one thing to the caller: this cut is unavailable ($null).
#
# `return ,@(...)` — the leading comma is load-bearing, NOT style. PowerShell
# unwraps a returned collection into the pipeline, so a plain `return @(...)` of
# a VALID EMPTY array (`[]` — a tracker with nothing open, an unpopulated
# workspace) emits nothing and the caller's `$x = Invoke-Tracker …` binds $null:
# indistinguishable from the call-failed sentinel. Every empty cut then counted
# as a failure and the whole linear surface reported `error` with three degraded
# entries while the bash twin reported `ok`. The comma operator wraps the array
# in a one-element outer array; PS unwraps exactly that one level, so the caller
# receives the array itself — empty or not. $null therefore means ONLY "the call
# failed".
function Invoke-Tracker([string[]]$CliArgs) {
    try {
        $raw = (& $TrackerCli @CliArgs --format json 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0) { return $null }
        if (-not $raw.TrimStart().StartsWith('[')) { return $null }
        return ,@($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# ---- linear surface ----------------------------------------------------------
$linearStatus = 'ok'
$linearDetail = ''
$projects = @()
$globalIssues = @()
$mineIssues = @()
$projIds = [System.Collections.Generic.List[string]]::new()
# Set when the PROJECT CUT itself is incomplete — the projects list failed, or any
# per-project issues call failed. See the reconciliation-integrity note below.
$projectCutIncomplete = $false

if (-not (Get-Command $TrackerCli -ErrorAction SilentlyContinue)) {
    $linearStatus = 'absent'
    $linearDetail = "lineark not found (--lineark or PATH): $TrackerCli — see linear/linear-setup.md §3.2"
    Add-Degraded "linear: lineark not on PATH ($TrackerCli)"
} else {
    $linearErrs = $false

    $projects = Invoke-Tracker @('projects', 'list')
    if ($null -eq $projects) {
        $projects = @(); $linearErrs = $true; $projectCutIncomplete = $true
        Add-Degraded 'linear: projects list failed'
    }

    $globalIssues = Invoke-Tracker @('issues', 'list', '--limit', "$Limit")
    # A failed GLOBAL sweep breaks reconciliation the same way a failed project
    # cut does (every project-listed id would phantom-mismatch the empty sweep).
    if ($null -eq $globalIssues) { $globalIssues = @(); $linearErrs = $true; $projectCutIncomplete = $true; Add-Degraded 'linear: global issues list failed' }

    $mineIssues = Invoke-Tracker @('issues', 'list', '--mine', '--limit', "$Limit")
    if ($null -eq $mineIssues) { $mineIssues = @(); $linearErrs = $true; Add-Degraded 'linear: issues list --mine failed' }

    # Project-first cut: one issues-list call per project, in tracker order.
    $pn = 0
    foreach ($p in $projects) {
        if (-not (Test-OrientObject $p)) { continue }
        $pid_ = Get-Flat $p 'id'
        if ($pid_ -eq '') { continue }
        $pname = Get-Flat $p 'name'
        if ($pname -eq '') { $pname = '-' }
        $pslug = Get-Flat $p 'slug_id'
        $pn++

        $pissues = Invoke-Tracker @('issues', 'list', '--project', $pid_, '--limit', "$Limit")
        if ($null -eq $pissues) {
            $pissues = @(); $linearErrs = $true; $projectCutIncomplete = $true
            Add-Degraded "linear: issues list failed for project $pname"
        }

        $openIssues = [System.Collections.Generic.List[object]]::new()
        foreach ($it in $pissues) {
            if (-not (Test-OrientObject $it)) { continue }
            $norm = ConvertTo-OrientIssue $it
            $openIssues.Add($norm)
            if ($norm.identifier -ne '') { $projIds.Add($norm.identifier) }
        }

        $projectsOut.Add([ordered]@{
            id          = $pid_
            name        = $pname
            slug_id     = $pslug
            open_issues = $openIssues
        })

        # ANOMALY: a project whose whole open set is unassigned Backlog. Empty
        # projects are NOT this class — nothing is stalled when nothing is open.
        $pTotal = $openIssues.Count
        if ($pTotal -gt 0) {
            $pIdle = @($openIssues | Where-Object { $_.state -ceq 'Backlog' -and $_.assignee -ceq '' }).Count
            if ($pIdle -eq $pTotal) {
                Add-Anomaly 'all-issues-backlog-no-assignee' $pname "all $pTotal open issue(s) are Backlog with no assignee"
            }
        }
    }

    if ($linearErrs) {
        $linearStatus = 'error'
        $linearDetail = 'one or more lineark calls failed — see degraded'
    } else {
        $linearDetail = "lineark ok: $pn project(s), $(@($globalIssues).Count) open issue(s) in the global sweep"
    }
}

# ---- reconciliation: global sweep vs the union of per-project lists ----------
# ORDINAL comparison + ordinal sort on every set operation. The bash twin pins
# LC_ALL=C on its sort/comm call sites for exactly this reason: these are
# byte-oriented set operations over identifiers, and a culture-sensitive
# comparer would order and match them differently from the C-locale twin —
# producing a phantom projectless list on one platform and not the other.
$globalSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($it in $globalIssues) {
    if (-not (Test-OrientObject $it)) { continue }
    $id = Get-Flat $it 'identifier'
    if ($id -ne '') { [void]$globalSet.Add($id) }
}
$projSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($id in $projIds) { if ($id -ne '') { [void]$projSet.Add($id) } }

# INTEGRITY GATE. When the project cut is INCOMPLETE (projects list failed, or any
# per-project call failed) the project union is missing rows that really exist, so
# the difference is not "issues in no project" — it is "issues whose project call
# failed". Emitting it would name real, correctly-filed issues as projectless AND
# raise a count-mismatch anomaly from the very same hole. Report the reconciliation
# as unavailable instead. A FULLY ABSENT linear surface is a different, honest
# case: every input is empty and the difference is naturally empty — unchanged.
#
# Emitted in GLOBAL SWEEP order (not sorted): the caller reads this as a list of
# issues, and the sweep's own newest-first order is the useful one.
$projectless = [System.Collections.Generic.List[object]]::new()
if ($projectCutIncomplete) {
    Add-Degraded 'linear: reconciliation unavailable — incomplete project cut'
} else {
    foreach ($it in $globalIssues) {
        if (-not (Test-OrientObject $it)) { continue }
        $id = Get-Flat $it 'identifier'
        if ($id -eq '' -or $projSet.Contains($id)) { continue }
        $projectless.Add((ConvertTo-OrientIssue $it))
    }
}

$mineInProgress = [System.Collections.Generic.List[object]]::new()
foreach ($it in $mineIssues) {
    if (-not (Test-OrientObject $it)) { continue }
    $norm = ConvertTo-OrientIssue $it
    if ($norm.state -ceq 'In Progress') { $mineInProgress.Add($norm) }
}

[string[]]$extra = @($projSet | Where-Object { -not $globalSet.Contains($_) })
if ((-not $projectCutIncomplete) -and $extra.Count -gt 0) {
    [Array]::Sort($extra, [System.StringComparer]::Ordinal)
    $extraList = ($extra -join ', ')
    Add-Anomaly 'open-issue-count-mismatch' 'global-sweep' `
        "$($extra.Count) identifier(s) listed under a project but absent from the global open sweep (global=$($globalSet.Count), project-union=$($projSet.Count)): $extraList"
}

# ---- memory surface ----------------------------------------------------------
# Get-FmType — the note's memory type from frontmatter: the first `type:` line
# inside the leading `---` block, top-level or nested under `metadata:`.
# Lowercased; empty when absent. `node_type:` is deliberately NOT matched (the
# pattern anchors `type:` to the line start after optional indent). Mirrors the
# bash twin's awk reader and check-memory-drift's, so all three agree on what a
# "project" note is.
function Get-FmType([string]$path) {
    try { $lines = [System.IO.File]::ReadAllLines($path) } catch { return '' }
    if ($lines.Count -eq 0) { return '' }
    $first = $lines[0]
    if ($first.Length -gt 0 -and $first[0] -eq [char]0xFEFF) { $first = $first.Substring(1) }
    if ($first -cnotmatch '^---\s*$') { return '' }
    $saw = 1
    for ($n = 1; $n -lt $lines.Count; $n++) {
        $l = $lines[$n]
        if ($l -cmatch '^---\s*$') { $saw++; if ($saw -eq 2) { break }; continue }
        if ($saw -eq 1 -and $l -cmatch '^\s*type:\s*') {
            $v = ($l -replace '^\s*type:\s*', '').Trim()
            $v = Remove-FmQuotes $v
            return $v.ToLowerInvariant()
        }
    }
    return ''
}

# Remove-FmQuotes — strip ONE surrounding quote pair, so `type: "project"`
# classifies as project rather than "project".
function Remove-FmQuotes([string]$v) {
    if ($v.Length -ge 2) {
        $f = $v[0]; $l = $v[$v.Length - 1]
        if (($f -ceq '"' -and $l -ceq '"') -or ($f -ceq "'" -and $l -ceq "'")) {
            return $v.Substring(1, $v.Length - 2)
        }
    }
    return $v
}

# Get-FmField — a TOP-LEVEL frontmatter scalar (`name:`, `description:`), one
# surrounding quote pair stripped. Indented keys are ignored on purpose: a
# nested `metadata: name:` is not the note's name.
function Get-FmField([string]$path, [string]$key) {
    try { $lines = [System.IO.File]::ReadAllLines($path) } catch { return '' }
    if ($lines.Count -eq 0) { return '' }
    $first = $lines[0]
    if ($first.Length -gt 0 -and $first[0] -eq [char]0xFEFF) { $first = $first.Substring(1) }
    if ($first -cnotmatch '^---\s*$') { return '' }
    $saw = 1
    $prefix = $key + ':'
    for ($n = 1; $n -lt $lines.Count; $n++) {
        $l = $lines[$n]
        if ($l -cmatch '^---\s*$') { $saw++; if ($saw -eq 2) { break }; continue }
        if ($saw -eq 1 -and $l.StartsWith($prefix, [StringComparison]::Ordinal)) {
            $v = $l.Substring($prefix.Length).Trim()
            return (Remove-FmQuotes $v)
        }
    }
    return ''
}

$memStatus = 'absent'
$memDetail = ''
# Telemetry state (see the header contract). $telemetryOk stays $false until the
# memory dir is actually scanned, so an unresolved surface emits `telemetry:
# null` rather than a 0-byte reading that reads like "orientation is free".
$telemetryOk = $false
$memIndexBytes = [long](-1)
$projBodyTotal = [long]0
$projBodies = [System.Collections.Generic.List[object]]::new()

# CONTAINED PROBE. $ErrorActionPreference is 'Stop' for the whole script, so a
# bare `Test-Path` here promotes a provider/access error (an unreadable ancestor
# directory, a denied share, a broken reparse point) into a TERMINATING error
# that kills the process before ANY JSON is written — the exact opposite of the
# "degrades, never fails" contract this script exists to hold. Contained, an
# unprobeable path becomes the memory surface's error path with a named degraded
# entry, and the document still lands on exit 0. $null = "could not tell".
$memDirExists = $null
try {
    $memDirExists = [bool](Test-Path -LiteralPath $MemoryDir -PathType Container)
} catch {
    $memDirExists = $null
}

if ($MemoryDir -eq '') {
    $memDetail = 'no --memory-dir given'
    Add-Degraded 'memory: no --memory-dir given'
} elseif ($null -eq $memDirExists) {
    $memStatus = 'error'
    $memDetail = "memory dir not readable: $MemoryDir"
    Add-Degraded "memory: dir not readable ($MemoryDir)"
} elseif (-not $memDirExists) {
    $memDetail = "memory dir absent: $MemoryDir"
    Add-Degraded "memory: dir absent ($MemoryDir)"
} else {
    $notes = $null
    try {
        # Ordinal sort — the bash twin pipes `find` through `LC_ALL=C sort`, and
        # Sort-Object's culture-sensitive default would order a mixed-case or
        # punctuated file set differently from it.
        $notes = @(Get-ChildItem -LiteralPath $MemoryDir -Filter '*.md' -File -ErrorAction Stop |
            ForEach-Object { $_.FullName } |
            Sort-Object -Property { $_ } -Culture ([System.Globalization.CultureInfo]::InvariantCulture))
        [string[]]$notes = $notes
        [Array]::Sort($notes, [System.StringComparer]::Ordinal)
    } catch {
        $notes = $null
    }
    if ($null -eq $notes) {
        $memStatus = 'error'
        $memDetail = "memory dir not readable: $MemoryDir"
        Add-Degraded "memory: dir not readable ($MemoryDir)"
    } else {
        $memStatus = 'ok'
        $telemetryOk = $true
        $memIndex = Join-Path $MemoryDir 'MEMORY.md'
        if (Test-Path -LiteralPath $memIndex -PathType Leaf) {
            try { $memIndexBytes = [long](Get-Item -LiteralPath $memIndex).Length } catch { $memIndexBytes = [long](-1) }
        }
        $memProj = 0
        foreach ($mf in $notes) {
            if ((Get-FmType $mf) -cne 'project') { continue }
            $memProj++
            $memoryOut.Add([ordered]@{
                file        = [System.IO.Path]::GetFileName($mf)
                name        = (Get-FmField $mf 'name')
                description = (Get-FmField $mf 'description')
            })
            # Body cost of the same note, for the telemetry key. Measured here
            # rather than in a second pass so the two lists can never disagree
            # about which notes a kickoff reads.
            $pb = [long]0
            try { $pb = [long](Get-Item -LiteralPath $mf).Length } catch { $pb = [long]0 }
            $projBodyTotal += $pb
            $projBodies.Add([ordered]@{ file = [System.IO.Path]::GetFileName($mf); bytes = $pb })
        }
        $memDetail = "$memProj project-type note(s) of $($notes.Count) note(s) in $MemoryDir"
    }
}

# ---- safety posture (detected, never declared) -------------------------------
# See the header contract. The value is read from local.env as DATA (the same
# no-importing posture scripts/self-audit.ps1 uses — Import-LocalEnv would push
# EVERY key, including a hostile PATH=, into the process env), then from the
# ambient env. local.env wins when it carries a non-empty value.
function Get-OrientLocalEnvValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $pat = '^(?:export\s+)?' + [regex]::Escape($Key) + '=(.*)$'
    $result = ''
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $t = $line.Trim()
        if ($t.Length -eq 0 -or $t.StartsWith('#', [StringComparison]::Ordinal)) { continue }
        if ($t -match $pat) {
            $v = $matches[1]
            if ($v.Length -ge 2) {
                $f = $v[0]; $l = $v[$v.Length - 1]
                if (($f -ceq '"' -and $l -ceq '"') -or ($f -ceq "'" -and $l -ceq "'")) {
                    $v = $v.Substring(1, $v.Length - 2)
                } elseif ($v.Contains([char]'\')) {
                    $v = [System.Text.RegularExpressions.Regex]::Replace($v, '\\(.)', '$1')
                }
            }
            $result = $v  # last assignment wins
        }
    }
    return $result
}

$orientRepoRoot = ''
if ($PSScriptRoot) { $orientRepoRoot = Split-Path $PSScriptRoot -Parent }
$guardSpec = ''
if ($orientRepoRoot) {
    try { $guardSpec = Get-OrientLocalEnvValue -Path (Join-Path $orientRepoRoot 'local.env') -Key 'GUARDRAIL_STATE_FILES' } catch { $guardSpec = '' }
}
if ([string]::IsNullOrEmpty($guardSpec) -and -not [string]::IsNullOrEmpty($env:GUARDRAIL_STATE_FILES)) {
    $guardSpec = $env:GUARDRAIL_STATE_FILES
}

$safetyPosture = 'safe'
$safetyDetection = 'none-configured'
$tightenings = [System.Collections.Generic.List[object]]::new()
if (-not [string]::IsNullOrEmpty($guardSpec)) {
    $safetyDetection = 'state-files'
    foreach ($raw in ($guardSpec -split ',')) {
        $gpath = $raw.Trim()
        if ($gpath -eq '') { continue }
        # A configured path that does not exist, or exists but is EMPTY, is not
        # a tightening — a guardrail skill writes state only while a scope is
        # active. Contained probe: $ErrorActionPreference is 'Stop', so an
        # unreadable ancestor must not kill the document.
        $ok = $false
        try { $ok = [bool]((Test-Path -LiteralPath $gpath -PathType Leaf) -and ((Get-Item -LiteralPath $gpath).Length -gt 0)) } catch { $ok = $false }
        if (-not $ok) { continue }
        $detail = ''
        try {
            $first = (Get-Content -LiteralPath $gpath -TotalCount 1 -ErrorAction Stop)
            if ($null -ne $first) { $detail = "$first" }
        } catch { $detail = '' }
        if ($detail.Length -gt 120) { $detail = $detail.Substring(0, 120) }
        $tightenings.Add([ordered]@{
            name   = [System.IO.Path]::GetFileName($gpath)
            path   = $gpath
            detail = $detail
        })
        $safetyPosture = 'tightened'
    }
}

$safetyObj = [ordered]@{
    posture     = $safetyPosture
    tightenings = $tightenings
    detection   = $safetyDetection
}

$telemetryObj = $null
if ($telemetryOk) {
    $telemetryObj = [ordered]@{
        memory_index_bytes      = $(if ($memIndexBytes -ge 0) { $memIndexBytes } else { $null })
        project_note_bodies     = $projBodies
        project_note_total_bytes = $projBodyTotal
    }
}

# ---- emit --------------------------------------------------------------------
$doc = [ordered]@{
    schema   = 'orient/v1'
    surfaces = [ordered]@{
        linear = [ordered]@{ status = $linearStatus; detail = $linearDetail }
        memory = [ordered]@{ status = $memStatus;    detail = $memDetail }
    }
    projects                = $projectsOut
    projectless_open_issues = $projectless
    mine_in_progress        = $mineInProgress
    anomalies               = $anomalies
    memory_pointers         = $memoryOut
    degraded                = $degraded
    # APPENDED LAST, in this order, so every pre-existing key keeps its name,
    # shape, AND position for a consumer that reads the document positionally.
    safety                  = $safetyObj
    telemetry               = $telemetryObj
}

# -Depth 12 clears the deepest nesting (doc -> projects -> open_issues -> field)
# with room to spare; the default of 2 would silently stringify the issue rows.
if ($Pretty) {
    Write-Output ($doc | ConvertTo-Json -Depth 12)
} else {
    Write-Output ($doc | ConvertTo-Json -Depth 12 -Compress)
}
exit 0
