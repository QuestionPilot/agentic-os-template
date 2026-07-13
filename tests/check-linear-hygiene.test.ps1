#!/usr/bin/env pwsh
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/check-linear-hygiene.test.ps1 — PowerShell twin of
# tests/check-linear-hygiene.test.sh.
#
# Unit acceptance for scripts/check-linear-hygiene.ps1: clean→0, gappy→1 with
# the exact ordered gap list, --list machine mode (incl. the `unchecked`
# token — no silent truncation in machine mode), the --max-reads cap at 0 and
# at a partial boundary, the standard's deliberately-projectless /
# deliberately-unassigned escapes, the line-anchored AC-heading match, read
# failure and non-object reads → unchecked-not-flagged, null / identifier-less
# list entries (StrictMode-safe, NOTEd; all-malformed → skip 2), empty
# workspace→0, and the fail-SOFT skip contract (exit 2) for no-lineark /
# failed-list / non-array / bad-arg — including the native -MaxReads -1 form,
# which bypasses the $Rest regex and must still exit 2.
#
# (The bash twin's "no jq" skip case has no PS analogue — the .ps1 parses via
# ConvertFrom-Json, no jq dependency — so it is not mirrored here; the
# equivalent fail-soft path is the invalid-JSON payload.)
#
# Hermetic: $env:LINEARK_BIN is pointed at a stub .ps1 that serves fixture
# JSON from its own directory — no live Linear access, no token.
#
# Dot-sourced by tests/run.ps1; uses Assert-* from tests/lib.ps1.

$CLH = Join-Path $env:REPO_ROOT 'scripts' 'check-linear-hygiene.ps1'
Assert-File 'check-linear-hygiene.ps1 present' $CLH

$AllGaps = 'no-project,no-priority,no-labels,no-assignee,no-acceptance-criteria'

function New-ClhTmp {
    $p = Join-Path ([IO.Path]::GetTempPath()) ('check-linear-hygiene-' + [Guid]::NewGuid().Guid.Substring(0, 8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

# New-ClhStub <dir> — a stub lineark .ps1 serving <dir>/list.json for
# `issues list` and <dir>/read-<ID>.json for `issues read`.
function New-ClhStub([string]$d) {
    $stub = Join-Path $d 'stub.ps1'
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgList = @())
$d = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($ArgList.Count -ge 2 -and $ArgList[0] -eq 'issues' -and $ArgList[1] -eq 'list') {
    Get-Content -Raw (Join-Path $d 'list.json'); exit 0
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

function Invoke-Clh([string]$stub, [string[]]$flags = @()) {
    $env:LINEARK_BIN = $stub
    try {
        $out = (& pwsh -NoProfile -File $CLH @flags 2>$null | Out-String).Trim()
        return @{ Out = $out; Rc = $LASTEXITCODE }
    } finally {
        Remove-Item Env:LINEARK_BIN -ErrorAction SilentlyContinue
    }
}

# --- mixed: ABC-1 fully conforming, ABC-9 gappy on all five checks -----------
$D1 = New-ClhTmp; $stub1 = New-ClhStub $D1
@'
[
  {"identifier": "ABC-1", "priority": "High", "labels": "Feature", "assignee": "Owner", "state": "Backlog"},
  {"identifier": "ABC-9", "priority": "No priority", "labels": "", "assignee": "", "state": "Backlog"}
]
'@ | Set-Content -LiteralPath (Join-Path $D1 'list.json')
@'
{"identifier": "ABC-1", "project": {"id": "p1", "name": "Some Project"},
 "description": "## Outcome\n\nDone state.\n\n## Acceptance criteria\n\n- [ ] observable\n"}
'@ | Set-Content -LiteralPath (Join-Path $D1 'read-ABC-1.json')
@'
{"identifier": "ABC-9", "project": null, "description": "a prose blob with no structure"}
'@ | Set-Content -LiteralPath (Join-Path $D1 'read-ABC-9.json')

$r = Invoke-Clh $stub1
Assert-Eq          'check-linear-hygiene: mixed exits 1'                 1 $r.Rc
Assert-Contains    'check-linear-hygiene: gappy issue WARNs all five gaps' $r.Out "WARN ABC-9: $AllGaps"
Assert-NotContains 'check-linear-hygiene: conforming issue not flagged'  $r.Out 'WARN ABC-1'
Assert-Contains    'check-linear-hygiene: summary counts 1 of 2'         $r.Out 'SUMMARY 1 of 2'

$r = Invoke-Clh $stub1 @('--list')
Assert-Eq 'check-linear-hygiene: --list exits 1'    1 $r.Rc
Assert-Eq 'check-linear-hygiene: --list line shape' ("ABC-9`t$AllGaps") $r.Out

$r = Invoke-Clh $stub1 @('--max-reads', '0')
Assert-Eq          'check-linear-hygiene: --max-reads 0 still exits 1 (list-level gaps)' 1 $r.Rc
Assert-Contains    'check-linear-hygiene: --max-reads 0 flags list-level gaps only' $r.Out 'WARN ABC-9: no-priority,no-labels,no-assignee'
Assert-NotContains 'check-linear-hygiene: --max-reads 0 does not false-flag project' $r.Out 'no-project'
Assert-Contains    'check-linear-hygiene: --max-reads 0 names both unchecked issues' $r.Out 'NOTE 2 open issue(s) not checked'

$r = Invoke-Clh $stub1 @('--max-reads', '0', '--list')
Assert-Eq       'check-linear-hygiene: --list --max-reads 0 exits 1' 1 $r.Rc
Assert-Contains 'check-linear-hygiene: --list emits clean-but-unchecked issue' $r.Out ("ABC-1`tunchecked")
Assert-Contains 'check-linear-hygiene: --list appends unchecked to gappy issue tokens' $r.Out ("ABC-9`tno-priority,no-labels,no-assignee,unchecked")
Remove-Item -Recurse -Force $D1

# --- clean workspace: PASS, exit 0, empty --list ------------------------------
$D2 = New-ClhTmp; $stub2 = New-ClhStub $D2
@'
[{"identifier": "ABC-1", "priority": "High", "labels": "Feature", "assignee": "Owner", "state": "Backlog"}]
'@ | Set-Content -LiteralPath (Join-Path $D2 'list.json')
@'
{"identifier": "ABC-1", "project": {"id": "p1", "name": "Some Project"},
 "description": "## Outcome\n\nx\n\n## Acceptance criteria\n\n- [ ] y\n"}
'@ | Set-Content -LiteralPath (Join-Path $D2 'read-ABC-1.json')
$r = Invoke-Clh $stub2
Assert-Eq       'check-linear-hygiene: clean exits 0'         0 $r.Rc
Assert-Contains 'check-linear-hygiene: clean prints PASS'     $r.Out 'PASS all 1 open issue'
$r = Invoke-Clh $stub2 @('--list')
Assert-Eq       'check-linear-hygiene: clean --list exits 0'  0 $r.Rc
Assert-Eq       'check-linear-hygiene: clean --list is empty' '' $r.Out
Remove-Item -Recurse -Force $D2

# --- standard's escapes: deliberately projectless + unassigned conform --------
$D6 = New-ClhTmp; $stub6 = New-ClhStub $D6
@'
[{"identifier": "ABC-3", "priority": "Medium", "labels": "Improvement", "assignee": "", "state": "Backlog"}]
'@ | Set-Content -LiteralPath (Join-Path $D6 'list.json')
@'
{"identifier": "ABC-3", "project": null,
 "description": "## Outcome\n\nx. Deliberately projectless: standalone maintenance sweep. Deliberately unassigned: next free agent picks it up.\n\n## Acceptance criteria\n\n- [ ] y\n"}
'@ | Set-Content -LiteralPath (Join-Path $D6 'read-ABC-3.json')
$r = Invoke-Clh $stub6
Assert-Eq          'check-linear-hygiene: documented escapes exit 0'      0 $r.Rc
Assert-NotContains 'check-linear-hygiene: stated projectless not flagged' $r.Out 'no-project'
Assert-NotContains 'check-linear-hygiene: stated unassigned not flagged'  $r.Out 'no-assignee'
Remove-Item -Recurse -Force $D6

# --- AC heading is line-anchored H2: '###' or prose mention does NOT count ----
$D7 = New-ClhTmp; $stub7 = New-ClhStub $D7
@'
[{"identifier": "ABC-7", "priority": "High", "labels": "Bug", "assignee": "Owner", "state": "Backlog"}]
'@ | Set-Content -LiteralPath (Join-Path $D7 'list.json')
@'
{"identifier": "ABC-7", "project": {"id": "p1", "name": "Some Project"},
 "description": "### Acceptance criteria\n\n- x\n\nprose saying ## acceptance criteria inline does not count\n"}
'@ | Set-Content -LiteralPath (Join-Path $D7 'read-ABC-7.json')
$r = Invoke-Clh $stub7
Assert-Eq       'check-linear-hygiene: H3/prose AC mention exits 1'    1 $r.Rc
Assert-Contains 'check-linear-hygiene: H3/prose AC mention is flagged' $r.Out 'WARN ABC-7: no-acceptance-criteria'
Remove-Item -Recurse -Force $D7

# --- partial read cap (--max-reads 1): first read, second NAMED unchecked -----
$D8 = New-ClhTmp; $stub8 = New-ClhStub $D8
@'
[
  {"identifier": "ABC-1", "priority": "High", "labels": "Feature", "assignee": "Owner", "state": "Backlog"},
  {"identifier": "ABC-5", "priority": "Low", "labels": "Improvement", "assignee": "Owner", "state": "Backlog"}
]
'@ | Set-Content -LiteralPath (Join-Path $D8 'list.json')
@'
{"identifier": "ABC-1", "project": {"id": "p1", "name": "Some Project"},
 "description": "## Acceptance criteria\n\n- [ ] y\n"}
'@ | Set-Content -LiteralPath (Join-Path $D8 'read-ABC-1.json')
$r = Invoke-Clh $stub8 @('--max-reads', '1')
Assert-Eq          'check-linear-hygiene: partial cap exits 0'          0 $r.Rc
Assert-Contains    'check-linear-hygiene: partial cap names the capped issue' $r.Out 'ABC-5'
Assert-Contains    'check-linear-hygiene: partial cap NOTE counts 1'    $r.Out 'NOTE 1 open issue(s) not checked'
Assert-NotContains 'check-linear-hygiene: partial cap does not flag the read issue' $r.Out 'WARN ABC-1'
Remove-Item -Recurse -Force $D8

# --- read failure: list-level clean, read fixture missing → unchecked, exit 0 -
$D3 = New-ClhTmp; $stub3 = New-ClhStub $D3
@'
[{"identifier": "ABC-2", "priority": "Medium", "labels": "Improvement", "assignee": "Owner", "state": "Backlog"}]
'@ | Set-Content -LiteralPath (Join-Path $D3 'list.json')
$r = Invoke-Clh $stub3
Assert-Eq       'check-linear-hygiene: read-failure exits 0 (unknown is not a gap)' 0 $r.Rc
Assert-Contains 'check-linear-hygiene: read-failure names the unchecked issue' $r.Out 'ABC-2'
Assert-Contains 'check-linear-hygiene: read-failure PASS is qualified' $r.Out '1 unchecked for project/body'
# non-object read payload → same unchecked path, and --list carries the token
@'
[1, 2]
'@ | Set-Content -LiteralPath (Join-Path $D3 'read-ABC-2.json')
$r = Invoke-Clh $stub3 @('--list')
Assert-Eq 'check-linear-hygiene: non-object read exits 0 (unchecked, not a gap)' 0 $r.Rc
Assert-Eq 'check-linear-hygiene: --list names non-object-read issue unchecked' ("ABC-2`tunchecked") $r.Out
Remove-Item -Recurse -Force $D3

# --- null / identifier-less list entries: StrictMode-safe, NOTEd; all-malformed → 2
$D9 = New-ClhTmp; $stub9 = New-ClhStub $D9
@'
[null, {"identifier": "ABC-1", "priority": "High", "labels": ["Feature", null], "assignee": "Owner", "state": "Backlog"}]
'@ | Set-Content -LiteralPath (Join-Path $D9 'list.json')
@'
{"identifier": "ABC-1", "project": {"id": "p1", "name": "Some Project"},
 "description": "## Acceptance criteria\n\n- [ ] y\n"}
'@ | Set-Content -LiteralPath (Join-Path $D9 'read-ABC-1.json')
$r = Invoke-Clh $stub9
Assert-Eq       'check-linear-hygiene: null list entry exits 0 (no StrictMode crash)' 0 $r.Rc
Assert-Contains 'check-linear-hygiene: null list entry NOTEd as malformed' $r.Out 'NOTE 1 list entr'
@'
[{}, null]
'@ | Set-Content -LiteralPath (Join-Path $D9 'list.json')
$r = Invoke-Clh $stub9
Assert-Eq 'check-linear-hygiene: all-malformed payload exits 2 (skip, not false PASS)' 2 $r.Rc
Remove-Item -Recurse -Force $D9

# --- empty workspace ----------------------------------------------------------
$D4 = New-ClhTmp; $stub4 = New-ClhStub $D4
'[]' | Set-Content -LiteralPath (Join-Path $D4 'list.json')
$r = Invoke-Clh $stub4
Assert-Eq       'check-linear-hygiene: empty workspace exits 0' 0 $r.Rc
Assert-Contains 'check-linear-hygiene: empty workspace prints PASS' $r.Out 'PASS no open issues'
Remove-Item -Recurse -Force $D4

# --- skip contract: fail-SOFT exit 2 -------------------------------------------
$D5 = New-ClhTmp
$r = Invoke-Clh (Join-Path $D5 'does-not-exist.ps1')
Assert-Eq 'check-linear-hygiene: missing lineark exits 2 (skip)' 2 $r.Rc
$broken = Join-Path $D5 'broken.ps1'
'exit 1' | Set-Content -LiteralPath $broken
$r = Invoke-Clh $broken
Assert-Eq 'check-linear-hygiene: failed list call exits 2 (skip)' 2 $r.Rc
$notjson = Join-Path $D5 'notjson.ps1'
"Write-Output 'plain text, not json'`nexit 0" | Set-Content -LiteralPath $notjson
$r = Invoke-Clh $notjson
Assert-Eq 'check-linear-hygiene: non-array payload exits 2 (skip)' 2 $r.Rc
& pwsh -NoProfile -File $CLH --bogus *> $null
Assert-Eq 'check-linear-hygiene: unknown argument exits 2' 2 $LASTEXITCODE
& pwsh -NoProfile -File $CLH --max-reads *> $null
Assert-Eq 'check-linear-hygiene: value-less --max-reads exits 2' 2 $LASTEXITCODE
& pwsh -NoProfile -File $CLH --max-reads abc *> $null
Assert-Eq 'check-linear-hygiene: non-numeric --max-reads exits 2' 2 $LASTEXITCODE
& pwsh -NoProfile -File $CLH --max-reads -1 *> $null
Assert-Eq 'check-linear-hygiene: negative --max-reads exits 2' 2 $LASTEXITCODE
& pwsh -NoProfile -File $CLH -MaxReads -1 *> $null
Assert-Eq 'check-linear-hygiene: native -MaxReads -1 exits 2 (bypasses $Rest regex)' 2 $LASTEXITCODE
Remove-Item -Recurse -Force $D5
