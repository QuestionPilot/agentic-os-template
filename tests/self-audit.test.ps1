#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/self-audit.test.ps1 — Windows-native twin of tests/self-audit.test.sh.
#
# Fixture-based scoring tests for scripts/self-audit.ps1 (the PS twin of
# self-audit.sh shipped). Each pillar gets a positive (clean →
# 20/20) and negative (with-gap → <20) case. Fixtures are minimal mini-repos
# under a tmp dir; the script is invoked with --repo-root / --memory-dir
# --vault-dir overrides so a fixture's state is the only thing scored.
#
# Mirrors tests/self-audit.test.sh 1:1 — same fixtures, same assertions,
# same AC count. Per [[reference_ps_port_traps]] trap #10 the PS port honors
# the POSIX-style `--foo bar` flags via ValueFromRemainingArguments + switch
# loop in self-audit.ps1.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$SA_SCRIPT = Join-Path $env:REPO_ROOT 'scripts' 'self-audit.ps1'
Assert-File 'self-audit.test: scripts/self-audit.ps1 exists' $SA_SCRIPT

# Helper: capture stdout (string) from pwsh -File <SA_SCRIPT> <args...>.
# Note: `$Args` is an automatic PS variable — use `$Argv` for our parameter.
function Invoke-SelfAudit {
    param([string[]]$Argv)
    $out = & pwsh -NoProfile -File $SA_SCRIPT @Argv 2>$null
    if ($out -is [array]) { return ($out -join "`n") }
    return [string]$out
}

# Helper: write a file with LF endings + UTF-8 no-BOM.
function Write-LfFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# Helper: minimal valid framework fixture under <root>.
function New-SaFixtureRepo {
    param([string]$Root)
    foreach ($d in @(
        (Join-Path $Root 'capabilities'),
        (Join-Path $Root 'verification'),
        (Join-Path $Root 'harnesses' 'claude' 'capabilities'),
        (Join-Path $Root 'harnesses' 'codex' 'capabilities'))) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    Write-LfFile (Join-Path $Root 'capabilities' 'example.md') @'
---
name: example
summary: example capability for fixture
triggers: [test]
verification: example
harnesses: [claude, codex]
kind: native
lifecycle: shipped
---

# Example
'@
    Write-LfFile (Join-Path $Root 'harnesses' 'claude' 'capabilities' 'example.md') @'
---
lifecycle: shipped
---

## Claude realization — example
'@
    Write-LfFile (Join-Path $Root 'harnesses' 'codex' 'capabilities' 'example.md') @'
---
lifecycle: shipped
---

## Codex realization — example
'@
    Write-LfFile (Join-Path $Root 'verification' 'example.md') @'
# Example verification recipe
'@
}

# Helper: pull a single pillar's score from --json output.
function Get-SaPillarScore {
    param([string]$Json, [string]$Pillar)
    if (-not $Json) { return '' }
    try {
        $obj = $Json | ConvertFrom-Json -ErrorAction Stop
        return [string]($obj.pillars.$Pillar.score)
    } catch {
        return ''
    }
}

function Get-SaTotal {
    param([string]$Json)
    if (-not $Json) { return $null }
    try {
        $obj = $Json | ConvertFrom-Json -ErrorAction Stop
        return $obj.total
    } catch { return $null }
}

function Test-JqAvailable {
    return $null -ne (Get-Command jq -ErrorAction SilentlyContinue)
}

# Helper: new tmp dir.
function New-SaTmp {
    $p = Join-Path ([IO.Path]::GetTempPath()) ('sa-fix-' + [Guid]::NewGuid().Guid.Substring(0,8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

# --- semantic currentness (<TEAM>-522) ---------------------------------------
# The advisory semantic check is wired in via $env:SELF_AUDIT_CURRENTNESS_BIN so
# the assertions are hermetic: a stub .ps1 stands in for
# check-state-currentness.ps1 and replays a chosen exit code + --list payload.
# What is under test is the WIRING contract, not the extractor (that lives in
# check-state-currentness.test.ps1): its own section, its own JSON key, and —
# the load-bearing part — that a semantic finding NEVER moves total, a pillar
# score, or gaps. A checker that could depress the score would get disabled.
function New-SaCurrentnessStub {
    param([string]$Path, [int]$ExitCode, [string[]]$Records = @())
    $body = New-Object System.Text.StringBuilder
    [void]$body.AppendLine('param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgList = @())')
    foreach ($r in $Records) {
        [void]$body.AppendLine("Write-Output `"$($r.Replace('"', '`"'))`"")
    }
    [void]$body.AppendLine('[Console]::Error.WriteLine("SKIP stub reason")')
    [void]$body.AppendLine("exit $ExitCode")
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, ($body.ToString() -replace "`r`n", "`n"), $utf8NoBom)
}

function Invoke-SaWithCurrentness {
    param([string]$Stub, [string[]]$Argv)
    $env:SELF_AUDIT_CURRENTNESS_BIN = $Stub
    try { return (Invoke-SelfAudit $Argv) }
    finally { Remove-Item Env:SELF_AUDIT_CURRENTNESS_BIN -ErrorAction SilentlyContinue }
}

$scFixture = New-SaTmp
New-SaFixtureRepo $scFixture
$scStub = Join-Path $scFixture 'stub.ps1'
$TAB = "`t"

# Baseline WITHOUT the checker, so score-neutrality is proved by comparison
# rather than asserted against a hard-coded number.
$scBaseJson = Invoke-SelfAudit @('--isolated', '--repo-root', $scFixture, '--json')
$scBase = $scBaseJson | ConvertFrom-Json

# 1. findings — rendered, keyed, and score-neutral.
New-SaCurrentnessStub $scStub 1 @(
    "claim${TAB}stale-claim${TAB}ABC-1${TAB}In Progress${TAB}Done${TAB}-${TAB}notes.md:7",
    "project${TAB}project-closed-with-open-children${TAB}Shipped Thing${TAB}Completed${TAB}2${TAB}0"
)
$scRaw = Invoke-SaWithCurrentness $scStub @('--isolated', '--repo-root', $scFixture, '--json')
$scJson = $scRaw | ConvertFrom-Json
Assert-Eq 'self-audit.test: semantic currentness status is findings' 'findings' $scJson.semantic_currentness.status
Assert-Eq 'self-audit.test: semantic currentness claim record lands in the claims array' 'ABC-1' $scJson.semantic_currentness.claims[0].identifier
Assert-Eq 'self-audit.test: semantic currentness claim carries its live-vs-stored pair' 'In Progress|Done' `
    ("{0}|{1}" -f $scJson.semantic_currentness.claims[0].stored, $scJson.semantic_currentness.claims[0].live)
Assert-Eq 'self-audit.test: semantic currentness project record lands in the projects array' `
    'project-closed-with-open-children' $scJson.semantic_currentness.projects[0].class
# Asserted against the SERIALIZED form, not the deserialized .NET type: the bash
# twin's jq check is `type == "number"`, and ConvertFrom-Json's integer width
# (Int32 vs Int64) is an implementation detail that would make the twins disagree
# for no behavioral reason.
Assert-Eq         'self-audit.test: semantic currentness open_children value round-trips' 2 $scJson.semantic_currentness.projects[0].open_children
Assert-NotContains 'self-audit.test: semantic currentness open_children is numeric, not a string' $scRaw '"open_children": "2"'
# The whole point: advisory means advisory.
Assert-Eq 'self-audit.test: semantic currentness findings do NOT change the total score' $scBase.total $scJson.total
Assert-Eq 'self-audit.test: semantic currentness findings do NOT enter the gap list' `
    @($scBase.gaps).Count @($scJson.gaps).Count

$scMd = Invoke-SaWithCurrentness $scStub @('--isolated', '--repo-root', $scFixture)
Assert-Contains 'self-audit.test: semantic currentness markdown has its own section' $scMd '## Semantic currentness'
Assert-Contains 'self-audit.test: semantic currentness markdown renders the claim finding' `
    $scMd 'stale-claim ABC-1: note says "In Progress", tracker says "Done" (as-of -) — notes.md:7'
Assert-Contains 'self-audit.test: semantic currentness markdown renders the project finding' `
    $scMd 'project-closed-with-open-children "Shipped Thing": status "Completed" with 2 open child issue(s), 0 active'
Assert-Contains 'self-audit.test: semantic currentness markdown states the advisory boundary' `
    $scMd 'never change the pillar scores'

# 2. clean — exit 0, no findings.
New-SaCurrentnessStub $scStub 0
$scJson = (Invoke-SaWithCurrentness $scStub @('--isolated', '--repo-root', $scFixture, '--json')) | ConvertFrom-Json
Assert-Eq 'self-audit.test: semantic currentness exit 0 reports clean' 'clean' $scJson.semantic_currentness.status
Assert-Eq 'self-audit.test: semantic currentness clean run has an empty claims array' 0 @($scJson.semantic_currentness.claims).Count

# 3. skip — exit 2 fails SOFT and the reason is NAMED, never anonymous.
New-SaCurrentnessStub $scStub 2
$scJson = (Invoke-SaWithCurrentness $scStub @('--isolated', '--repo-root', $scFixture, '--json')) | ConvertFrom-Json
Assert-Eq 'self-audit.test: semantic currentness exit 2 reports skipped' 'skipped' $scJson.semantic_currentness.status
Assert-Eq 'self-audit.test: semantic currentness skip reason is named, not anonymous' 'stub reason' $scJson.semantic_currentness.reason
Assert-Eq 'self-audit.test: semantic currentness a skip preserves the filesystem score' $scBase.total $scJson.total

# 4. exit 1 with no parseable record is a contract break, not a clean run.
New-SaCurrentnessStub $scStub 1
$scJson = (Invoke-SaWithCurrentness $scStub @('--isolated', '--repo-root', $scFixture, '--json')) | ConvertFrom-Json
Assert-Eq 'self-audit.test: semantic currentness exit 1 with no records degrades to skipped' 'skipped' $scJson.semantic_currentness.status

# 5. plain --isolated (no stub): the section still exists and names the skip.
Assert-Eq 'self-audit.test: semantic currentness isolated run without a checker is a named skip' `
    'isolated run — semantic currentness not evaluated' $scBase.semantic_currentness.reason

Remove-Item -LiteralPath $scFixture -Recurse -Force -ErrorAction SilentlyContinue

# Test 0 — smoke: scorecard against the real repo.
$SMOKE_OUT = Invoke-SelfAudit @('--repo-root', $env:REPO_ROOT)
Assert-Contains 'self-audit.test: smoke scorecard heading present' $SMOKE_OUT '/self-audit scorecard'
Assert-Contains 'self-audit.test: smoke total line present' $SMOKE_OUT 'Total:'
Assert-Contains 'self-audit.test: smoke all five pillar labels present (Cross-layer handoffs)' $SMOKE_OUT 'Cross-layer handoffs'
Assert-Contains 'self-audit.test: smoke pillar 5 label present (Closeout / spine discipline)' $SMOKE_OUT 'Closeout / spine discipline'
Assert-Contains 'self-audit.test: smoke top gaps section present' $SMOKE_OUT 'Top gaps (leverage-weighted)'
Assert-Contains 'self-audit.test: smoke skipped surfaces section present' $SMOKE_OUT 'Skipped surfaces'

# Test 1 — --json shape: structured object with all expected keys.
$SMOKE_JSON = Invoke-SelfAudit @('--repo-root', $env:REPO_ROOT, '--json')
$jqAvail = Test-JqAvailable
if ($jqAvail) {
    $total = Get-SaTotal $SMOKE_JSON
    if ($total -is [int] -or ($total -is [long])) {
        _Pass 'self-audit.test: --json total key is integer'
    } elseif ($total -is [double] -and ([math]::Truncate($total) -eq $total)) {
        _Pass 'self-audit.test: --json total key is integer'
    } else {
        $type = if ($null -ne $total) { $total.GetType().Name } else { 'null' }
        _Fail 'self-audit.test: --json total key is integer' "expected integer, got $type"
    }
    $obj = $SMOKE_JSON | ConvertFrom-Json
    $pillarCount = ($obj.pillars | Get-Member -MemberType NoteProperty).Count
    Assert-Eq 'self-audit.test: --json pillars object has 5 keys' '5' "$pillarCount"

    $hasCl = $null -ne $obj.pillars.'cross-layer-handoffs'
    Assert-Eq 'self-audit.test: --json cross-layer-handoffs pillar key present' 'True' "$hasCl"
    $hasCs = $null -ne $obj.pillars.'closeout-spine-discipline'
    Assert-Eq 'self-audit.test: --json closeout-spine-discipline pillar key present' 'True' "$hasCs"

    $gapsIsArray = ($obj.gaps -is [array]) -or ($null -ne $obj.gaps -and $obj.gaps.GetType().IsArray)
    Assert-Eq 'self-audit.test: --json gaps key is array' 'True' "$gapsIsArray"
    $skippedIsArray = ($obj.skipped -is [array]) -or ($null -ne $obj.skipped -and $obj.skipped.GetType().IsArray)
    Assert-Eq 'self-audit.test: --json skipped key is array' 'True' "$skippedIsArray"
} else {
    _Skip 'self-audit.test: --json shape tests' 'jq not installed (PS twin still asserts shape via ConvertFrom-Json — but bash skip-marker mirrored for AC parity)'
}

# --- Pillar 5 negative: missing Codex realization
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    Remove-Item -LiteralPath (Join-Path $fixture 'harnesses' 'codex' 'capabilities' 'example.md') -Force
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $score = Get-SaPillarScore $out 'closeout-spine-discipline'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if ($score -and ([int]$score -lt 20)) {
        _Pass 'self-audit.test: pillar 5 deducts when a native capability is missing its Codex realization'
    } else {
        _Fail 'self-audit.test: pillar 5 deducts when a native capability is missing its Codex realization' "expected score < 20, got [$score]"
    }
} else {
    _Skip 'self-audit.test: pillar 5 missing-codex test' 'jq not installed'
}

# --- Pillar 5 positive: symmetric spine scores 20/20.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $score = Get-SaPillarScore $out 'closeout-spine-discipline'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: pillar 5 is 20/20 on symmetric-spine fixture' '20' "$score"
} else {
    _Skip 'self-audit.test: pillar 5 symmetric-clean test' 'jq not installed'
}

# --- Pillar 5 — hermes first-class: a native cap declaring hermes in its
# `harnesses:` frontmatter but missing the hermes realization must deduct
# (harness set derived from each capability's frontmatter, not a hardcoded pair).
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    # Promote the fixture cap to a 3-harness spine + add the hermes realization.
    Write-LfFile (Join-Path $fixture 'capabilities' 'example.md') @'
---
name: example
summary: example capability for fixture
triggers: [test]
verification: example
harnesses: [claude, codex, hermes]
kind: native
lifecycle: shipped
---

# Example
'@
    New-Item -ItemType Directory -Path (Join-Path $fixture 'harnesses' 'hermes' 'capabilities') -Force | Out-Null
    Write-LfFile (Join-Path $fixture 'harnesses' 'hermes' 'capabilities' 'example.md') @'
---
lifecycle: shipped
---

## Hermes realization — example
'@
    # Sanity: a symmetric 3-harness spine scores 20/20.
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $score = Get-SaPillarScore $out 'closeout-spine-discipline'
    Assert-Eq 'self-audit.test: pillar 5 is 20/20 on a symmetric 3-harness (incl. hermes) fixture' '20' "$score"

    # Drop ONLY the hermes realization → pillar 5 must deduct.
    Remove-Item -LiteralPath (Join-Path $fixture 'harnesses' 'hermes' 'capabilities' 'example.md') -Force
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $score = Get-SaPillarScore $out 'closeout-spine-discipline'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if ($score -and ([int]$score -lt 20)) {
        _Pass 'self-audit.test: pillar 5 deducts when a native capability is missing its Hermes realization (hermes first-class)'
    } else {
        _Fail 'self-audit.test: pillar 5 deducts when a native capability is missing its Hermes realization (hermes first-class)' "expected score < 20, got [$score]"
    }
} else {
    _Skip 'self-audit.test: pillar 5 missing-hermes test' 'jq not installed'
}

# --- Pillar 4 negative: orphan recipe.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    Write-LfFile (Join-Path $fixture 'verification' 'orphan.md') "# Orphan recipe — no capability points here`n"
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $score = Get-SaPillarScore $out 'verification-coverage'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if ($score -and ([int]$score -lt 20)) {
        _Pass 'self-audit.test: pillar 4 deducts when a verification recipe has no capability consumer'
    } else {
        _Fail 'self-audit.test: pillar 4 deducts when a verification recipe has no capability consumer' "expected score < 20, got [$score]"
    }
} else {
    _Skip 'self-audit.test: pillar 4 orphan-recipe test' 'jq not installed'
}

# --- Pillar 4 positive: every recipe has a consumer.
# lift: the (?m) multiline-flag fix plus the D3 by-name
# widening make the PS twin score the clean fixture 20/20, matching the bash
# twin's pillar-4-clean test. The historical _Skip — deferred for the pre-(?m)
# regex bug and never lifted after shipped — is now a real assertion.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $score = Get-SaPillarScore $out 'verification-coverage'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: pillar 4 is 20/20 on clean recipe<->capability fixture' '20' "$score"
} else {
    _Skip 'self-audit.test: pillar 4 clean test' 'jq not installed'
}

# --- Pillar 3 negative: anti-pattern directory.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    New-Item -ItemType Directory -Path (Join-Path $fixture 'misc') -Force | Out-Null
    Write-LfFile (Join-Path $fixture 'misc' 'sentinel.md') "sentinel`n"
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $score = Get-SaPillarScore $out 'folder-hygiene'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if ($score -and ([int]$score -lt 20)) {
        _Pass 'self-audit.test: pillar 3 deducts on anti-pattern directory name (misc/)'
    } else {
        _Fail 'self-audit.test: pillar 3 deducts on anti-pattern directory name (misc/)' "expected score < 20, got [$score]"
    }
} else {
    _Skip 'self-audit.test: pillar 3 antipattern-dir test' 'jq not installed'
}

# --- Pillar 3 negative: a live .git inside the configured vault (the Drive-sync
# corruption footgun <TEAM>-298 #2 guards against).
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $vault = New-SaTmp
    New-Item -ItemType Directory -Path (Join-Path $vault '.git') -Force | Out-Null
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--vault-dir', $vault, '--json')
    $score = Get-SaPillarScore $out 'folder-hygiene'
    if ($score -and ([int]$score -lt 20)) {
        _Pass 'self-audit.test: pillar 3 deducts on a live .git inside the vault'
    } else {
        _Fail 'self-audit.test: pillar 3 deducts on a live .git inside the vault' "expected score < 20, got [$score]"
    }
    Assert-Contains 'self-audit.test: pillar 3 names the .git-in-vault gap' `
        $out 'Live .git inside the sync-hosted vault'

    # A .git gitlink FILE (worktree/submodule pointer), not a dir, is the same
    # footgun — the guard uses -e / Test-Path, which catches both (cross-model note).
    Remove-Item -LiteralPath (Join-Path $vault '.git') -Recurse -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText((Join-Path $vault '.git'), "gitdir: /elsewhere/.git/worktrees/x`n", [System.Text.UTF8Encoding]::new($false))
    $outGl = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--vault-dir', $vault, '--json')
    Assert-Contains 'self-audit.test: Drive-git guard also fires on a .git gitlink FILE' `
        $outGl 'Live .git inside the sync-hosted vault'
    Remove-Item -LiteralPath (Join-Path $vault '.git') -Force -ErrorAction SilentlyContinue

    # Positive: a clean vault (no .git) must NOT trip the check — proves the guard
    # is additive (no false positive on the common, correct setup).
    Remove-Item -LiteralPath (Join-Path $vault '.git') -Recurse -Force -ErrorAction SilentlyContinue
    $out2 = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--vault-dir', $vault, '--json')
    $score2 = Get-SaPillarScore $out2 'folder-hygiene'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $vault -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: pillar 3 stays 20/20 with a vault that has no .git' '20' "$score2"
} else {
    _Skip 'self-audit.test: pillar 3 drive-git test' 'jq not installed'
}

# --- Pillar 3 positive: clean folder structure.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $score = Get-SaPillarScore $out 'folder-hygiene'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: pillar 3 is 20/20 on clean folder fixture' '20' "$score"
} else {
    _Skip 'self-audit.test: pillar 3 clean test' 'jq not installed'
}

# --- Pillar 2 negative: orphan memory file.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $mem = New-SaTmp
    Write-LfFile (Join-Path $mem 'MEMORY.md') "# Memory Index`n`n(intentionally empty body — no entries)`n"
    Write-LfFile (Join-Path $mem 'feedback_orphan.md') @'
---
name: feedback_orphan
metadata: { type: feedback }
---
orphan content
'@
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--memory-dir', $mem, '--json')
    $score = Get-SaPillarScore $out 'memory-hygiene'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $mem -Recurse -Force -ErrorAction SilentlyContinue
    if ($score -and ([int]$score -lt 20)) {
        _Pass 'self-audit.test: pillar 2 deducts when a memory file has no MEMORY.md index entry'
    } else {
        _Fail 'self-audit.test: pillar 2 deducts when a memory file has no MEMORY.md index entry' "expected score < 20, got [$score]"
    }
} else {
    _Skip 'self-audit.test: pillar 2 orphan-memory test' 'jq not installed'
}

# --- Pillar 2 negative: MEMORY.md over recall cap.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $mem = New-SaTmp
    # Build a MEMORY.md just over the 24400-byte threshold via ~400 lines.
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# Memory Index`n`n")
    for ($i = 1; $i -le 400; $i++) {
        [void]$sb.Append("- [pad-entry-$i](pad.md) lorem ipsum dolor sit amet consectetur adipiscing elit padding padding padding padding`n")
    }
    Write-LfFile (Join-Path $mem 'MEMORY.md') $sb.ToString()
    Write-LfFile (Join-Path $mem 'pad.md') @'
---
name: pad
---
pad content
'@
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--memory-dir', $mem, '--json')
    $score = Get-SaPillarScore $out 'memory-hygiene'
    $cap_gap_present = $false
    try {
        $obj = $out | ConvertFrom-Json -ErrorAction Stop
        foreach ($g in $obj.gaps) {
            if ($g.title -and $g.title.Contains('over recall cap')) {
                $cap_gap_present = $true; break
            }
        }
    } catch { }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $mem -Recurse -Force -ErrorAction SilentlyContinue
    if ($score -and ([int]$score -lt 20) -and $cap_gap_present) {
        _Pass 'self-audit.test: pillar 2 deducts when MEMORY.md exceeds the recall cap'
    } else {
        _Fail 'self-audit.test: pillar 2 deducts when MEMORY.md exceeds the recall cap' "expected score < 20 + over-cap gap, got score=[$score] cap_gap=[$cap_gap_present]"
    }
} else {
    _Skip 'self-audit.test: pillar 2 over-cap test' 'jq not installed'
}

# --- Pillar 2 negative: MEMORY.md index entry over the per-line cap.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $mem = New-SaTmp
    # MEMORY.md well under the size cap but with ONE entry line > 300 chars.
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# Memory Index`n`n")
    [void]$sb.Append("- [Short](pad.md) — fine`n")
    [void]$sb.Append("- [Long](pad.md) — ")
    for ($i = 1; $i -le 30; $i++) { [void]$sb.Append('overlongwordpadding ') }
    [void]$sb.Append("`n")
    Write-LfFile (Join-Path $mem 'MEMORY.md') $sb.ToString()
    Write-LfFile (Join-Path $mem 'pad.md') @'
---
name: pad
---
pad content
'@
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--memory-dir', $mem, '--json')
    $score = Get-SaPillarScore $out 'memory-hygiene'
    $line_gap_present = $false
    # Codex review missing-test: the line-cap deduction must be LOCALIZED to the
    # memory-hygiene pillar — the other four pillars must stay at 20/20.
    $other_pillars_clean = $true
    try {
        $obj = $out | ConvertFrom-Json -ErrorAction Stop
        foreach ($g in $obj.gaps) {
            if ($g.title -and $g.title.Contains('over line-length cap')) {
                $line_gap_present = $true; break
            }
        }
        foreach ($p in $obj.pillars.PSObject.Properties) {
            if ($p.Name -ne 'memory-hygiene' -and [int]$p.Value.score -ne 20) {
                $other_pillars_clean = $false
            }
        }
    } catch { }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $mem -Recurse -Force -ErrorAction SilentlyContinue
    if ($score -and ([int]$score -lt 20) -and $line_gap_present -and $other_pillars_clean) {
        _Pass 'self-audit.test: pillar 2 deducts when a MEMORY.md index entry exceeds the per-line cap'
    } else {
        _Fail 'self-audit.test: pillar 2 deducts when a MEMORY.md index entry exceeds the per-line cap' "expected score < 20 + over-line-length gap + other pillars 20/20, got score=[$score] line_gap=[$line_gap_present] others_clean=[$other_pillars_clean]"
    }
} else {
    _Skip 'self-audit.test: pillar 2 over-line-cap test' 'jq not installed'
}

# --- Pillar 2 positive: clean memory + index.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $mem = New-SaTmp
    Write-LfFile (Join-Path $mem 'MEMORY.md') "# Memory Index`n`n- [Example](feedback_example.md) — small clean entry`n"
    Write-LfFile (Join-Path $mem 'feedback_example.md') @'
---
name: feedback_example
metadata: { type: feedback }
---
example
'@
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--memory-dir', $mem, '--json')
    $score = Get-SaPillarScore $out 'memory-hygiene'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $mem -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: pillar 2 is 20/20 on clean memory fixture' '20' "$score"
} else {
    _Skip 'self-audit.test: pillar 2 clean test' 'jq not installed'
}

# --- Pillar 1 negative: broken MEMORY.md link.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $mem = New-SaTmp
    Write-LfFile (Join-Path $mem 'MEMORY.md') "# Memory Index`n`n- [Missing](does_not_exist.md) — link target does not exist`n"
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--memory-dir', $mem, '--json')
    $score = Get-SaPillarScore $out 'cross-layer-handoffs'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $mem -Recurse -Force -ErrorAction SilentlyContinue
    if ($score -and ([int]$score -lt 20)) {
        _Pass 'self-audit.test: pillar 1 deducts when MEMORY.md has a broken file link'
    } else {
        _Fail 'self-audit.test: pillar 1 deducts when MEMORY.md has a broken file link' "expected score < 20, got [$score]"
    }
} else {
    _Skip 'self-audit.test: pillar 1 broken-link test' 'jq not installed'
}

# --- Cross-pillar: --save writes the same content to disk.
$fixture = New-SaTmp
New-SaFixtureRepo $fixture
$out_path = Join-Path $fixture 'audits' 'audit-2026-05-25.md'
& pwsh -NoProfile -File $SA_SCRIPT --isolated --repo-root $fixture --save 'audits/audit-2026-05-25.md' *>$null
$saved = Test-Path -LiteralPath $out_path -PathType Leaf
Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
if ($saved) {
    _Pass 'self-audit.test: --save writes the scorecard to the given path'
} else {
    _Fail 'self-audit.test: --save writes the scorecard to the given path' "expected file at $out_path"
}

# --- Cross-pillar: script exits 0 on a fixture with multiple gaps.
$fixture = New-SaTmp
New-SaFixtureRepo $fixture
Remove-Item -LiteralPath (Join-Path $fixture 'harnesses' 'codex' 'capabilities' 'example.md') -Force
Write-LfFile (Join-Path $fixture 'verification' 'orphan.md') "# Orphan recipe`n"
New-Item -ItemType Directory -Path (Join-Path $fixture 'misc') -Force | Out-Null
Write-LfFile (Join-Path $fixture 'misc' 'x.md') "x`n"
& pwsh -NoProfile -File $SA_SCRIPT --isolated --repo-root $fixture *>$null
$rc = $LASTEXITCODE
Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
Assert-Eq 'self-audit.test: exits 0 even with multiple gaps surfaced' '0' "$rc"

# --- Capability shape ---
$SA_PATH = Join-Path $env:REPO_ROOT 'capabilities' 'self-audit.md'
Assert-File 'self-audit.test: capabilities/self-audit.md exists' $SA_PATH
$SA_CONTENT = if (Test-Path -LiteralPath $SA_PATH) { Get-Content -LiteralPath $SA_PATH -Raw } else { '' }
Assert-Contains 'self-audit.test: capability declares name: self-audit' $SA_CONTENT 'name: self-audit'
Assert-Contains 'self-audit.test: capability declares kind: native' $SA_CONTENT 'kind: native'
Assert-Contains 'self-audit.test: capability ships to every spine harness' $SA_CONTENT 'harnesses: [claude, codex, hermes, cursor]'
Assert-Contains 'self-audit.test: capability declares verification: self-audit' $SA_CONTENT 'verification: self-audit'

# Both harness realizations exist.
Assert-File 'self-audit.test: harnesses/claude/capabilities/self-audit.md exists' `
    (Join-Path $env:REPO_ROOT 'harnesses' 'claude' 'capabilities' 'self-audit.md')
Assert-File 'self-audit.test: harnesses/codex/capabilities/self-audit.md exists' `
    (Join-Path $env:REPO_ROOT 'harnesses' 'codex' 'capabilities' 'self-audit.md')
Assert-File 'self-audit.test: verification/self-audit.md recipe exists' `
    (Join-Path $env:REPO_ROOT 'verification' 'self-audit.md')

# operating-system.md.
$OS_PATH = Join-Path $env:REPO_ROOT 'core' 'operating-system.md'
$OS_CONTENT = Get-Content -LiteralPath $OS_PATH -Raw
Assert-Contains 'self-audit.test: core/operating-system.md names self-audit in the spine' `
    $OS_CONTENT 'self-audit'

# --- Codex B-3: --isolated nullifies operator-env leakage.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $savedCcd = $env:CLAUDE_CONFIG_DIR
    $savedOvp = $env:OBSIDIAN_VAULT_PATH
    try {
        $env:CLAUDE_CONFIG_DIR = $env:REPO_ROOT
        $env:OBSIDIAN_VAULT_PATH = $env:REPO_ROOT
        $out_iso = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
        $score_iso = Get-SaPillarScore $out_iso 'closeout-spine-discipline'
    } finally {
        if ($null -ne $savedCcd) { $env:CLAUDE_CONFIG_DIR = $savedCcd } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
        if ($null -ne $savedOvp) { $env:OBSIDIAN_VAULT_PATH = $savedOvp } else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: --isolated nullifies CLAUDE_CONFIG_DIR + OBSIDIAN_VAULT_PATH (Codex B-3 regression guard)' `
        '20' "$score_iso"
} else {
    _Skip 'self-audit.test: isolation env-leak test' 'jq not installed'
}

# --- Codex missing-test: vendored capability does not require harness realizations.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    Write-LfFile (Join-Path $fixture 'capabilities' 'vendor-thing.md') @'
---
name: vendor-thing
summary: hypothetical vendored capability
triggers: [test]
verification: example
harnesses: [claude]
kind: vendored
source: github.com/somewhere/somerepo
version: pinned
install: see source
lifecycle: shipped
---

# Vendored body
'@
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $score = Get-SaPillarScore $out 'closeout-spine-discipline'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: pillar 5 ignores kind: vendored capabilities for spine-symmetry (Codex missing-test)' `
        '20' "$score"
} else {
    _Skip 'self-audit.test: pillar 5 vendored test' 'jq not installed'
}

# --- Codex S-3: folder hygiene respects.gitignore.
$gitAvail = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
if ($jqAvail -and $gitAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    Push-Location $fixture
    try {
        & git init -q 2>$null
        Write-LfFile (Join-Path $fixture '.gitignore') "scratch/`n"
    } finally {
        Pop-Location
    }
    New-Item -ItemType Directory -Path (Join-Path $fixture 'scratch' 'empty-leaf') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'scratch' 'tmp') -Force | Out-Null
    Write-LfFile (Join-Path $fixture 'scratch' 'tmp' 'x.md') "x`n"
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $score = Get-SaPillarScore $out 'folder-hygiene'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: pillar 3 respects .gitignore — empty + anti-pattern dirs under ignored subtree do not deduct (Codex S-3)' `
        '20' "$score"
} else {
    if (-not $jqAvail) { _Skip 'self-audit.test: pillar 3 gitignore test' 'jq not installed' }
    else { _Skip 'self-audit.test: pillar 3 gitignore test' 'git not installed' }
}

# --- Codex N-1: fm_get trims trailing whitespace.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    # Write capability with trailing space after `native`.
    Write-LfFile (Join-Path $fixture 'capabilities' 'example.md') ('---' + "`n" +
        'name: example' + "`n" +
        'summary: example with trailing space in kind' + "`n" +
        'triggers: [test]' + "`n" +
        'verification: example' + "`n" +
        'harnesses: [claude, codex]' + "`n" +
        'kind: native ' + "`n" +
        'lifecycle: shipped' + "`n" +
        '---' + "`n`n" +
        '# Body' + "`n")
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $score = Get-SaPillarScore $out 'closeout-spine-discipline'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: fm_get tolerates trailing whitespace in YAML value (Codex N-1)' `
        '20' "$score"
} else {
    _Skip 'self-audit.test: fm_get trim test' 'jq not installed'
}

# --- Codex N-2: MEMORY.md link regex accepts #anchor suffix.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $mem = New-SaTmp
    Write-LfFile (Join-Path $mem 'MEMORY.md') "# Memory Index`n`n- [Anchor link to missing](does_not_exist.md#section) — broken anchor target`n"
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--memory-dir', $mem, '--json')
    $score = Get-SaPillarScore $out 'cross-layer-handoffs'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $mem -Recurse -Force -ErrorAction SilentlyContinue
    if ($score -and ([int]$score -lt 20)) {
        _Pass 'self-audit.test: pillar 1 catches broken MEMORY.md link with #anchor suffix (Codex N-2)'
    } else {
        _Fail 'self-audit.test: pillar 1 catches broken MEMORY.md link with #anchor suffix (Codex N-2)' "expected score < 20, got [$score]"
    }
} else {
    _Skip 'self-audit.test: anchor-link test' 'jq not installed'
}

# =============================================================================
# parity twins for the three self-audit defects (mirror
# tests/self-audit.test.sh).
# =============================================================================

# --- D1 (<TEAM>-366): memory scoring AGGREGATES all projects/*/memory stores. The
# stray store's missing MEMORY.md is a REAL gap now, attributed to its store —
# the old picker scored only the "primary" store and left the stray invisible.
# Non-isolated so the CONFIG_DIR→memory resolution runs; --config-dir pins
# config so the result is env-independent.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $cfg = Join-Path $fixture 'config'
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'aaa-stray' 'memory') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'zzz-primary' 'memory') -Force | Out-Null
    Write-LfFile (Join-Path $cfg 'projects' 'aaa-stray' 'memory' 'note.md') "stray`n"
    Write-LfFile (Join-Path $cfg 'projects' 'zzz-primary' 'memory' 'MEMORY.md') "# Memory Index`n`n- [Proj](project_real.md) — the operator's active project`n"
    Write-LfFile (Join-Path $cfg 'projects' 'zzz-primary' 'memory' 'project_real.md') "---`nname: project_real`nmetadata:`n  type: project`n---`nreal project body`n"
    $savedOvp = $env:OBSIDIAN_VAULT_PATH
    $savedPmd = $env:CLAUDE_PRIMARY_MEMORY_DIR
    try {
        Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue
        $out = Invoke-SelfAudit @('--repo-root', $fixture, '--config-dir', $cfg, '--json')
        $p2 = Get-SaPillarScore $out 'memory-hygiene'
        $missingDetail = ''
        try { $obj = $out | ConvertFrom-Json; foreach ($g in $obj.gaps) { if ($g.title -and $g.title.Contains('MEMORY.md index missing')) { $missingDetail = $g.detail; break } } } catch { }
    } finally {
        if ($null -ne $savedOvp) { $env:OBSIDIAN_VAULT_PATH = $savedOvp } else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $savedPmd) { $env:CLAUDE_PRIMARY_MEMORY_DIR = $savedPmd } else { Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if ($p2 -and ([int]$p2 -lt 20) -and $missingDetail -and $missingDetail.Contains('aaa-stray')) {
        _Pass 'self-audit.test: D1 all memory stores scanned; stray store missing index flags, attributed to its store'
    } else {
        _Fail 'self-audit.test: D1 all memory stores scanned; stray store missing index flags, attributed to its store' "expected pillar 2 < 20 + missing-index gap naming aaa-stray, got score=[$p2] detail=[$missingDetail]"
    }
} else {
    _Skip 'self-audit.test: D1 all-stores-scanned test' 'jq not installed'
}

# --- D1b: explicit $CLAUDE_PRIMARY_MEMORY_DIR pins the scan to that ONE store
# (<TEAM>-366: the pin has always meant single-store scoring — with the pin set,
# the config's other stores are intentionally out of scope).
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $cfg = Join-Path $fixture 'config'
    $pinned = Join-Path $fixture 'pinned-memory'
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'only' 'memory') -Force | Out-Null
    New-Item -ItemType Directory -Path $pinned -Force | Out-Null
    Write-LfFile (Join-Path $cfg 'projects' 'only' 'memory' 'note.md') "x`n"
    Write-LfFile (Join-Path $pinned 'MEMORY.md') "# Memory Index`n`n- [Proj](project_pinned.md) — pinned active project`n"
    Write-LfFile (Join-Path $pinned 'project_pinned.md') "---`nname: project_pinned`nmetadata:`n  type: project`n---`npinned project body`n"
    $savedOvp = $env:OBSIDIAN_VAULT_PATH
    $savedPmd = $env:CLAUDE_PRIMARY_MEMORY_DIR
    try {
        Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
        $env:CLAUDE_PRIMARY_MEMORY_DIR = $pinned
        $out = Invoke-SelfAudit @('--repo-root', $fixture, '--config-dir', $cfg, '--json')
        $p2 = Get-SaPillarScore $out 'memory-hygiene'
    } finally {
        if ($null -ne $savedOvp) { $env:OBSIDIAN_VAULT_PATH = $savedOvp } else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $savedPmd) { $env:CLAUDE_PRIMARY_MEMORY_DIR = $savedPmd } else { Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: D1b CLAUDE_PRIMARY_MEMORY_DIR pins the memory surface over the heuristic' '20' "$p2"
} else {
    _Skip 'self-audit.test: D1b explicit-override test' 'jq not installed'
}

# --- D1h: an EMPTY auto-created store (zero *.md files) must NOT floor
# Pillar 2: it is named informationally in skipped[] and excluded from
# scoring, while the healthy sibling store keeps its clean 20/20. Teeth kept:
# a store WITH notes but no MEMORY.md still deducts (D1 above pins that case).
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $cfg = Join-Path $fixture 'config'
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' '-private-tmp' 'memory') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'zzz-primary' 'memory') -Force | Out-Null
    Write-LfFile (Join-Path $cfg 'projects' 'zzz-primary' 'memory' 'MEMORY.md') "# Memory Index`n`n- [Proj](project_real.md) — the operator's active project`n"
    Write-LfFile (Join-Path $cfg 'projects' 'zzz-primary' 'memory' 'project_real.md') "---`nname: project_real`nmetadata:`n  type: project`n---`nreal project body`n"
    $savedOvp = $env:OBSIDIAN_VAULT_PATH
    $savedPmd = $env:CLAUDE_PRIMARY_MEMORY_DIR
    $savedCxh = $env:CODEX_HOME
    try {
        Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
        $out = Invoke-SelfAudit @('--repo-root', $fixture, '--config-dir', $cfg, '--json')
        $p2 = Get-SaPillarScore $out 'memory-hygiene'
        $emptyNote = ''
        try { $obj = $out | ConvertFrom-Json; foreach ($s in $obj.skipped) { if ($s -and $s.Contains('empty memory store')) { $emptyNote = $s; break } } } catch { }
    } finally {
        if ($null -ne $savedOvp) { $env:OBSIDIAN_VAULT_PATH = $savedOvp } else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $savedPmd) { $env:CLAUDE_PRIMARY_MEMORY_DIR = $savedPmd } else { Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue }
        if ($null -ne $savedCxh) { $env:CODEX_HOME = $savedCxh } else { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if (("$p2" -eq '20') -and $emptyNote -and $emptyNote.Contains('-private-tmp')) {
        _Pass 'self-audit.test: D1h an empty memory store is named informationally and does not floor pillar 2'
    } else {
        _Fail 'self-audit.test: D1h an empty memory store is named informationally and does not floor pillar 2' "expected pillar 2 == 20 + an empty-store skipped line naming -private-tmp, got score=[$p2] note=[$emptyNote]"
    }
} else {
    _Skip 'self-audit.test: D1h empty-store test' 'jq not installed'
}

# --- D1i: when EVERY resolved store is empty, the pillar must report
# UNSCORED (a cannot-run check fails loudly), never a clean 20/20 and never
# a spurious missing-index 0/20.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $cfg = Join-Path $fixture 'config'
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'aaa-empty' 'memory') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'bbb-empty' 'memory') -Force | Out-Null
    $savedOvp = $env:OBSIDIAN_VAULT_PATH
    $savedPmd = $env:CLAUDE_PRIMARY_MEMORY_DIR
    $savedCxh = $env:CODEX_HOME
    try {
        Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
        $out = Invoke-SelfAudit @('--repo-root', $fixture, '--config-dir', $cfg, '--json')
        $unscored = ''
        $note = ''
        try {
            $obj = $out | ConvertFrom-Json
            $p2obj = $obj.pillars.'memory-hygiene'
            if ($null -ne $p2obj) { $unscored = "$($p2obj.unscored)"; $note = "$($p2obj.notes)" }
        } catch { }
    } finally {
        if ($null -ne $savedOvp) { $env:OBSIDIAN_VAULT_PATH = $savedOvp } else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $savedPmd) { $env:CLAUDE_PRIMARY_MEMORY_DIR = $savedPmd } else { Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue }
        if ($null -ne $savedCxh) { $env:CODEX_HOME = $savedCxh } else { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if (($unscored -eq 'True' -or $unscored -eq 'true') -and $note.Contains('all resolved memory stores are empty')) {
        _Pass 'self-audit.test: D1i all-empty stores report pillar 2 UNSCORED with the named reason'
    } else {
        _Fail 'self-audit.test: D1i all-empty stores report pillar 2 UNSCORED with the named reason' "expected unscored=true + all-empty note, got unscored=[$unscored] note=[$note]"
    }
} else {
    _Skip 'self-audit.test: D1i all-empty-stores test' 'jq not installed'
}

# --- D2: local.env is read for config so the no-flag run resolves the vault
# (reproducible across shells), not from the ambient env only. Run A (no ambient
# vault) and run B (bogus ambient vault) must BOTH resolve the vault from
# local.env → vault never "skipped".
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    New-Item -ItemType Directory -Path (Join-Path $fixture 'vault' '01-Projects') -Force | Out-Null
    # QUOTE the value: an unquoted Windows backslash path (C:\…) would hit
    # Get-SaLocalEnvValue's bash-%q backslash-collapse and be mangled (C:\… → C:…);
    # the canonical local.env format (tests/lib.ps1 Write-LocalEnvFixture) quotes,
    # and quoted values skip the collapse. macOS forward-slash paths no-op it,
    # which hid this until the Windows lane.
    Write-LfFile (Join-Path $fixture 'local.env') ('OBSIDIAN_VAULT_PATH="' + (Join-Path $fixture 'vault') + '"' + "`n")
    $savedOvp = $env:OBSIDIAN_VAULT_PATH
    $savedCcd = $env:CLAUDE_CONFIG_DIR
    $skippedA = $true
    $skippedB = $true
    try {
        Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        $outA = Invoke-SelfAudit @('--repo-root', $fixture, '--json')
        $objA = $outA | ConvertFrom-Json
        $skippedA = [bool](@($objA.skipped | Where-Object { $_ -like '*vault dir not configured*' }).Count -gt 0)
        $env:OBSIDIAN_VAULT_PATH = '/nonexistent/ambient/vault'
        $outB = Invoke-SelfAudit @('--repo-root', $fixture, '--json')
        $objB = $outB | ConvertFrom-Json
        $skippedB = [bool](@($objB.skipped | Where-Object { $_ -like '*vault dir not configured*' }).Count -gt 0)
    } finally {
        if ($null -ne $savedOvp) { $env:OBSIDIAN_VAULT_PATH = $savedOvp } else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $savedCcd) { $env:CLAUDE_CONFIG_DIR = $savedCcd } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $skippedA -and -not $skippedB) {
        _Pass 'self-audit.test: D2 local.env is read (vault resolved) + wins over ambient env → reproducible'
    } else {
        _Fail 'self-audit.test: D2 local.env is read (vault resolved) + wins over ambient env → reproducible' "expected vault NOT skipped in either run; got skippedA=$skippedA skippedB=$skippedB"
    }
} else {
    _Skip 'self-audit.test: D2 local.env-sourced test' 'jq not installed'
}

# --- D3: a recipe routed BY NAME (routing doc, not verification: frontmatter) is
# not flagged orphan.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    Write-LfFile (Join-Path $fixture 'verification' 'by-name-gate.md') "# By-name-routed verification recipe`n"
    Write-LfFile (Join-Path $fixture 'core' 'routing.md') "# Routing`nChoose the matching gate from verification: by-name-gate and example.`n"
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $score = Get-SaPillarScore $out 'verification-coverage'
    $orphanGap = $false
    try { $obj = $out | ConvertFrom-Json; foreach ($g in $obj.gaps) { if ($g.title -and $g.title.Contains('Orphan verification')) { $orphanGap = $true; break } } } catch { }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if ($score -eq '20' -and -not $orphanGap) {
        _Pass 'self-audit.test: D3 a recipe routed by NAME is not flagged orphan'
    } else {
        _Fail 'self-audit.test: D3 a recipe routed by NAME is not flagged orphan' "expected 20/20 + no orphan gap, got score=[$score] orphanGap=$orphanGap"
    }
} else {
    _Skip 'self-audit.test: D3 by-name reference test' 'jq not installed'
}

# --- D3b: a genuinely-dangling recipe (named nowhere) is still flagged — teeth kept.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    Write-LfFile (Join-Path $fixture 'verification' 'dangling-nowhere.md') "# A recipe referenced by no capability, playbook, or routing doc.`n"
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $score = Get-SaPillarScore $out 'verification-coverage'
    $orphanGap = $false
    try { $obj = $out | ConvertFrom-Json; foreach ($g in $obj.gaps) { if ($g.title -and $g.title.Contains('Orphan verification')) { $orphanGap = $true; break } } } catch { }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if ($score -and ([int]$score -lt 20) -and $orphanGap) {
        _Pass 'self-audit.test: D3b a genuinely-dangling recipe is still flagged orphan — check keeps its teeth'
    } else {
        _Fail 'self-audit.test: D3b a genuinely-dangling recipe is still flagged orphan — check keeps its teeth' "expected score < 20 + orphan gap, got score=[$score] orphanGap=$orphanGap"
    }
} else {
    _Skip 'self-audit.test: D3b teeth test' 'jq not installed'
}

# --- D1c (Codex review): a CLAUDE_PRIMARY_MEMORY_DIR pin in local.env wins over
# an ambient CLAUDE_PRIMARY_MEMORY_DIR.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $cfg = Join-Path $fixture 'config'
    $good = Join-Path $fixture 'good-memory'
    $bad = Join-Path $fixture 'bad-memory'
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'only' 'memory') -Force | Out-Null
    New-Item -ItemType Directory -Path $good -Force | Out-Null
    New-Item -ItemType Directory -Path $bad -Force | Out-Null
    Write-LfFile (Join-Path $cfg 'projects' 'only' 'memory' 'note.md') "x`n"
    Write-LfFile (Join-Path $good 'MEMORY.md') "# Memory Index`n`n- [Proj](project_g.md) — active`n"
    Write-LfFile (Join-Path $good 'project_g.md') "---`nname: project_g`nmetadata:`n  type: project`n---`nbody`n"
    Write-LfFile (Join-Path $bad 'stray.md') "stray`n"
    # Quote the value (see D2): an unquoted Windows backslash path is mangled by
    # the bash-%q backslash-collapse; the canonical local.env format quotes.
    Write-LfFile (Join-Path $fixture 'local.env') ('CLAUDE_PRIMARY_MEMORY_DIR="' + $good + '"' + "`n")
    $savedOvp = $env:OBSIDIAN_VAULT_PATH
    $savedPmd = $env:CLAUDE_PRIMARY_MEMORY_DIR
    try {
        Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
        $env:CLAUDE_PRIMARY_MEMORY_DIR = $bad
        $out = Invoke-SelfAudit @('--repo-root', $fixture, '--config-dir', $cfg, '--json')
        $p2 = Get-SaPillarScore $out 'memory-hygiene'
    } finally {
        if ($null -ne $savedOvp) { $env:OBSIDIAN_VAULT_PATH = $savedOvp } else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $savedPmd) { $env:CLAUDE_PRIMARY_MEMORY_DIR = $savedPmd } else { Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: D1c local.env CLAUDE_PRIMARY_MEMORY_DIR wins over ambient' '20' "$p2"
} else {
    _Skip 'self-audit.test: D1c local.env-primary-wins test' 'jq not installed'
}

# --- D1d (<TEAM>-366): a hygiene signal in the NON-largest store is scored. Two
# indexed stores; the orphan lives in bbb-tie — the store the old tie-break never
# scanned. Aggregation must surface it, attributed to its store.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $cfg = Join-Path $fixture 'config'
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'aaa-tie' 'memory') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'bbb-tie' 'memory') -Force | Out-Null
    Write-LfFile (Join-Path $cfg 'projects' 'aaa-tie' 'memory' 'MEMORY.md') "# Memory Index`n`n- [A](project_a.md) — clean`n"
    Write-LfFile (Join-Path $cfg 'projects' 'aaa-tie' 'memory' 'project_a.md') "---`nname: project_a`nmetadata:`n  type: project`n---`na`n"
    Write-LfFile (Join-Path $cfg 'projects' 'bbb-tie' 'memory' 'MEMORY.md') "# Memory Index`n`n- [B](project_b.md) — has orphan sibling`n"
    Write-LfFile (Join-Path $cfg 'projects' 'bbb-tie' 'memory' 'project_b.md') "---`nname: project_b`nmetadata:`n  type: project`n---`nb`n"
    Write-LfFile (Join-Path $cfg 'projects' 'bbb-tie' 'memory' 'feedback_orphan.md') "orphan`n"
    $savedOvp = $env:OBSIDIAN_VAULT_PATH
    $savedPmd = $env:CLAUDE_PRIMARY_MEMORY_DIR
    try {
        Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue
        $out = Invoke-SelfAudit @('--repo-root', $fixture, '--config-dir', $cfg, '--json')
        $p2 = Get-SaPillarScore $out 'memory-hygiene'
        $orphanDetail = ''
        try { $obj = $out | ConvertFrom-Json; foreach ($g in $obj.gaps) { if ($g.title -and $g.title.Contains('Orphan memory file')) { $orphanDetail = $g.detail; break } } } catch { }
    } finally {
        if ($null -ne $savedOvp) { $env:OBSIDIAN_VAULT_PATH = $savedOvp } else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $savedPmd) { $env:CLAUDE_PRIMARY_MEMORY_DIR = $savedPmd } else { Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if ($p2 -and ([int]$p2 -lt 20) -and $orphanDetail -and $orphanDetail.Contains('bbb-tie')) {
        _Pass 'self-audit.test: D1d orphan in the secondary (non-largest) store is scored + attributed to that store'
    } else {
        _Fail 'self-audit.test: D1d orphan in the secondary (non-largest) store is scored + attributed to that store' "expected pillar 2 < 20 + orphan gap naming bbb-tie, got score=[$p2] detail=[$orphanDetail]"
    }
} else {
    _Skip 'self-audit.test: D1d secondary-store-signal test' 'jq not installed'
}

# --- D1e (<TEAM>-366): aggregation spans pillars — each store's own MEMORY.md is
# link-walked (pillar 1) while the other store's hygiene is scored (pillar 2),
# in the same run. Store A has a broken index link; store B has an orphan note.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $cfg = Join-Path $fixture 'config'
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'aaa-links' 'memory') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'bbb-orphan' 'memory') -Force | Out-Null
    Write-LfFile (Join-Path $cfg 'projects' 'aaa-links' 'memory' 'MEMORY.md') "# Memory Index`n`n- [Missing](does_not_exist.md) — broken link in store A`n"
    Write-LfFile (Join-Path $cfg 'projects' 'bbb-orphan' 'memory' 'MEMORY.md') "# Memory Index`n`n(no entries)`n"
    Write-LfFile (Join-Path $cfg 'projects' 'bbb-orphan' 'memory' 'feedback_orphan.md') "orphan`n"
    $savedOvp = $env:OBSIDIAN_VAULT_PATH
    $savedPmd = $env:CLAUDE_PRIMARY_MEMORY_DIR
    try {
        Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue
        $out = Invoke-SelfAudit @('--repo-root', $fixture, '--config-dir', $cfg, '--json')
        $p1 = Get-SaPillarScore $out 'cross-layer-handoffs'
        $p2 = Get-SaPillarScore $out 'memory-hygiene'
        $linkDetail = ''
        try { $obj = $out | ConvertFrom-Json; foreach ($g in $obj.gaps) { if ($g.title -and $g.title.Contains('Broken MEMORY.md link')) { $linkDetail = $g.detail; break } } } catch { }
    } finally {
        if ($null -ne $savedOvp) { $env:OBSIDIAN_VAULT_PATH = $savedOvp } else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $savedPmd) { $env:CLAUDE_PRIMARY_MEMORY_DIR = $savedPmd } else { Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if ($p1 -and ([int]$p1 -lt 20) -and $p2 -and ([int]$p2 -lt 20) -and $linkDetail -and $linkDetail.Contains('aaa-links')) {
        _Pass 'self-audit.test: D1e one run scores store A broken index link AND store B orphan, each attributed'
    } else {
        _Fail 'self-audit.test: D1e one run scores store A broken index link AND store B orphan, each attributed' "expected p1 < 20 + p2 < 20 + link gap naming aaa-links, got p1=[$p1] p2=[$p2] detail=[$linkDetail]"
    }
} else {
    _Skip 'self-audit.test: D1e cross-pillar aggregation test' 'jq not installed'
}

# --- D1f (<TEAM>-366, panel: Codex + Gemini): an explicit --memory-dir means
# exactly ONE store even when the config dir holds other discoverable stores
# with gaps AND a CLAUDE_PRIMARY_MEMORY_DIR pin points at the broken store —
# the full precedence is flag > pin > discovery.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $cfg = Join-Path $fixture 'config'
    $flagged = Join-Path $fixture 'flagged-memory'
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'broken' 'memory') -Force | Out-Null
    New-Item -ItemType Directory -Path $flagged -Force | Out-Null
    Write-LfFile (Join-Path $cfg 'projects' 'broken' 'memory' 'note.md') "x`n"
    Write-LfFile (Join-Path $flagged 'MEMORY.md') "# Memory Index`n`n- [Proj](project_f.md) — flagged active project`n"
    Write-LfFile (Join-Path $flagged 'project_f.md') "---`nname: project_f`nmetadata:`n  type: project`n---`nflagged project body`n"
    $savedOvp = $env:OBSIDIAN_VAULT_PATH
    $savedPmd = $env:CLAUDE_PRIMARY_MEMORY_DIR
    try {
        Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
        # Pin the AMBIENT env at the broken store: the explicit flag must still win.
        $env:CLAUDE_PRIMARY_MEMORY_DIR = (Join-Path $cfg 'projects' 'broken' 'memory')
        $out = Invoke-SelfAudit @('--repo-root', $fixture, '--config-dir', $cfg, '--memory-dir', $flagged, '--json')
        $p2 = Get-SaPillarScore $out 'memory-hygiene'
    } finally {
        if ($null -ne $savedOvp) { $env:OBSIDIAN_VAULT_PATH = $savedOvp } else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $savedPmd) { $env:CLAUDE_PRIMARY_MEMORY_DIR = $savedPmd } else { Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: D1f explicit --memory-dir scans exactly one store — flag wins over the pin and over discovery' '20' "$p2"
} else {
    _Skip 'self-audit.test: D1f flag-excludes-discovery test' 'jq not installed'
}

# --- D3c (Codex review): token boundary is precise — a recipe name that is only
# a SUBSTRING of other words ("database", "data-driven") is still orphan.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    Write-LfFile (Join-Path $fixture 'verification' 'data.md') "# A recipe named data`n"
    Write-LfFile (Join-Path $fixture 'core' 'routing.md') "# Routing`nUse the database layer and a data-driven approach.`n"
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $score = Get-SaPillarScore $out 'verification-coverage'
    $orphanGap = $false
    try { $obj = $out | ConvertFrom-Json; foreach ($g in $obj.gaps) { if ($g.title -and $g.title.Contains('Orphan verification')) { $orphanGap = $true; break } } } catch { }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if ($score -and ([int]$score -lt 20) -and $orphanGap) {
        _Pass 'self-audit.test: D3c recipe data not matched by database/data-driven substrings — still orphan'
    } else {
        _Fail 'self-audit.test: D3c recipe data not matched by database/data-driven substrings — still orphan' "expected score < 20 + orphan gap, got score=[$score] orphanGap=$orphanGap"
    }
} else {
    _Skip 'self-audit.test: D3c boundary test' 'jq not installed'
}

# --- D2b (Codex review): a local.env vault path WITH A SPACE (the operator's
# real "Claude - Local" shape), double-quoted, resolves — not skipped.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    New-Item -ItemType Directory -Path (Join-Path $fixture 'my vault' '01-Projects') -Force | Out-Null
    Write-LfFile (Join-Path $fixture 'local.env') ('OBSIDIAN_VAULT_PATH="' + (Join-Path $fixture 'my vault') + '"' + "`n")
    $savedOvp = $env:OBSIDIAN_VAULT_PATH
    $savedCcd = $env:CLAUDE_CONFIG_DIR
    $vaultSkipped = $true
    try {
        Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        $out = Invoke-SelfAudit @('--repo-root', $fixture, '--json')
        $obj = $out | ConvertFrom-Json
        $vaultSkipped = [bool](@($obj.skipped | Where-Object { $_ -like '*vault dir not configured*' }).Count -gt 0)
    } finally {
        if ($null -ne $savedOvp) { $env:OBSIDIAN_VAULT_PATH = $savedOvp } else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $savedCcd) { $env:CLAUDE_CONFIG_DIR = $savedCcd } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $vaultSkipped) {
        _Pass 'self-audit.test: D2b a quoted local.env vault path with a space resolves (operator "Claude - Local" shape)'
    } else {
        _Fail 'self-audit.test: D2b a quoted local.env vault path with a space resolves (operator "Claude - Local" shape)' "expected vault NOT skipped, got skipped=$vaultSkipped"
    }
} else {
    _Skip 'self-audit.test: D2b space-path test' 'jq not installed'
}

# --- F1 (Codex pre-merge review): the PS twin reads local.env as DATA via
# Get-SaLocalEnvValue (only the 3 config keys, never PATH) — parity with the
# hardened bash twin. A local.env carrying a non-config PATH= line is ignored;
# the legitimate OBSIDIAN_VAULT_PATH key is still resolved (run completes, vault
# not skipped). Invoke-SelfAudit runs the script in a CHILD process, so a child
# env change cannot leak back here — the meaningful assertion is selective DATA
# parsing (vault read, PATH= line ignored), mirroring the bash F1 teeth.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    New-Item -ItemType Directory -Path (Join-Path $fixture 'vault' '01-Projects') -Force | Out-Null
    Write-LfFile (Join-Path $fixture 'local.env') (
        'OBSIDIAN_VAULT_PATH="' + (Join-Path $fixture 'vault') + '"' + "`n" +
        'PATH="/nonexistent/evil:placeholder"' + "`n")
    $savedOvp = $env:OBSIDIAN_VAULT_PATH
    $savedCcd = $env:CLAUDE_CONFIG_DIR
    $vaultSkipped = $true
    try {
        Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        $out = Invoke-SelfAudit @('--repo-root', $fixture, '--json')
        $obj = $out | ConvertFrom-Json
        $vaultSkipped = [bool](@($obj.skipped | Where-Object { $_ -like '*vault dir not configured*' }).Count -gt 0)
    } finally {
        if ($null -ne $savedOvp) { $env:OBSIDIAN_VAULT_PATH = $savedOvp } else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $savedCcd) { $env:CLAUDE_CONFIG_DIR = $savedCcd } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $vaultSkipped) {
        _Pass 'self-audit.test: F1 PS reads local.env as DATA — non-config PATH= line ignored, vault still resolved'
    } else {
        _Fail 'self-audit.test: F1 PS reads local.env as DATA — non-config PATH= line ignored, vault still resolved' "expected vault NOT skipped, got vaultSkipped=$vaultSkipped"
    }
} else {
    _Skip 'self-audit.test: F1 PS local.env-as-data test' 'jq not installed'
}

# --- UNSCORED pillars: a clean clone with NO operator surfaces (no Linear, no
# memory dir, no vault) must NOT manufacture a false ~100/100. A pillar that can
# run zero real checks is floored to 0 and flagged UNSCORED (core/verification.md:
# a check that cannot run must fail, never pass), so the total lands well below the
# ~95-100 "in good shape" band the seed-20 bug produced. Mirrors the bash twin.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    # --isolated nullifies ambient CLAUDE_CONFIG_DIR + OBSIDIAN_VAULT_PATH and skips
    # lineark detection → the cross-layer + memory pillars can measure nothing.
    $out = Invoke-SelfAudit @('--repo-root', $fixture, '--isolated', '--json')
    $obj = $out | ConvertFrom-Json
    $p1  = Get-SaPillarScore $out 'cross-layer-handoffs'
    $p2  = Get-SaPillarScore $out 'memory-hygiene'
    $p1u = "$($obj.pillars.'cross-layer-handoffs'.unscored)"
    $p2u = "$($obj.pillars.'memory-hygiene'.unscored)"
    $uc  = "$($obj.unscored_count)"
    $tot = [int]$obj.total
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: unscored cross-layer pillar floored to 0 when no surface reachable' '0' $p1
    Assert-Eq 'self-audit.test: unscored memory pillar floored to 0 when no surface reachable' '0' $p2
    Assert-Eq 'self-audit.test: unscored cross-layer pillar flagged unscored=true' 'True' $p1u
    Assert-Eq 'self-audit.test: unscored memory pillar flagged unscored=true' 'True' $p2u
    Assert-Eq 'self-audit.test: unscored_count counts both unmeasured pillars' '2' $uc
    if ($tot -lt 95) {
        _Pass "self-audit.test: unscored no-surface clone total ($tot) is below the 'in good shape' band"
    } else {
        _Fail "self-audit.test: unscored no-surface clone total below 'in good shape' band" "got total=$tot (expected <95)"
    }
} else {
    _Skip 'self-audit.test: unscored-pillars false-100 test' 'jq not installed'
}

# --- Read-only contract regression guard.
$SA_CAP_CONTENT = Get-Content -LiteralPath (Join-Path $env:REPO_ROOT 'capabilities' 'self-audit.md') -Raw
$SA_VER_CONTENT = Get-Content -LiteralPath (Join-Path $env:REPO_ROOT 'verification' 'self-audit.md') -Raw
Assert-Contains 'self-audit.test: capability spec documents --save as the only write path (Codex B-1)' $SA_CAP_CONTENT '--save'
Assert-Contains 'self-audit.test: verification recipe documents --save as the only write path (Codex B-1)' $SA_VER_CONTENT '--save'

# --- <TEAM>-370 twin-parity guard: EQUAL-leverage gaps keep insertion order
# after the leverage-descending sort (mirrors tests/self-audit.test.sh). Both
# twins sort on explicit (leverage desc, insertion index asc) keys — the bash
# twin's bare `sort -nr` used to reverse insertion order on ties while
# Sort-Object preserved it. Same fixture, same expected order as the sh twin:
# pillar 1 (broken MEMORY.md link) is recorded before pillar 5 (missing
# ## State Deltas), so the pillar-1 gap must emit first.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $mem = New-SaTmp
    Write-LfFile (Join-Path $mem 'MEMORY.md') @'
# Memory Index

- [Proj](project_recent.md) — active project note
- [Missing](does_not_exist.md) — broken link target
'@
    Write-LfFile (Join-Path $mem 'project_recent.md') @'
---
name: project_recent
metadata:
  type: project
---
recent project body, deliberately without a state-deltas section
'@
    $out  = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--memory-dir', $mem, '--json')
    $obj  = $out | ConvertFrom-Json
    $lev4 = @($obj.gaps | Where-Object { $_.leverage -eq 4 } | ForEach-Object { $_.title }) -join '|'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $mem -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: equal-leverage gaps emit in insertion order (pillar 1 before pillar 5) — twin-parity tie-break' `
        'Broken MEMORY.md link(s)|Recent project memory lacks ## State Deltas' $lev4
} else {
    _Skip 'self-audit.test: equal-leverage gap-order test' 'jq not installed'
}

# --- <TEAM>-371 twin-parity guard: multi-hit gap RECORDING order is
# traversal-independent (mirrors tests/self-audit.test.sh). Both twins sort the
# pillar-3.2 enumeration (bash: find | LC_ALL=C sort; PS: ordinal Array.Sort),
# so two dirs matching the same anti-pattern name record in byte order, not
# filesystem enumeration order. Same fixture, same expected order as the sh
# twin: zeta/tmp is created BEFORE alpha/tmp; alpha's gap must emit first.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    New-Item -ItemType Directory -Path (Join-Path $fixture 'zeta' 'tmp') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'alpha' 'tmp') -Force | Out-Null
    Write-LfFile (Join-Path $fixture 'zeta' 'tmp' 'keep.txt') "keep`n"
    Write-LfFile (Join-Path $fixture 'alpha' 'tmp' 'keep.txt') "keep`n"
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $obj = $out | ConvertFrom-Json
    $details = @($obj.gaps | Where-Object { $_.title -eq 'Anti-pattern directory name' } | ForEach-Object { $_.detail }) -join '|'
    $expA = (Join-Path $fixture 'alpha' 'tmp') + ' uses a name ("tmp") that signals undisciplined accretion'
    $expZ = (Join-Path $fixture 'zeta' 'tmp') + ' uses a name ("tmp") that signals undisciplined accretion'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: anti-pattern multi-hit gaps record in C-sorted path order (alpha before zeta) — twin-parity traversal determinism' `
        "$expA|$expZ" $details
} else {
    _Skip 'self-audit.test: anti-pattern gap-order test' 'jq not installed'
}

# --- <TEAM>-371 twin-parity guard: spine-asymmetry gap order derives from the
# SORTED capability enumeration (mirrors tests/self-audit.test.sh). bb-caps.md
# is created before aa-caps.md and is the only declarer of the second harness;
# post-fix both twins enumerate aa-caps, bb-caps (byte order): harness-union
# first-seen order is echo then foxtrot, and echo's missing_for is
# "aa-caps bb-caps".
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    Write-LfFile (Join-Path $fixture 'capabilities' 'bb-caps.md') @'
---
name: bb-caps
summary: fixture capability
triggers: [test]
verification: example
harnesses: [echo, foxtrot]
kind: native
lifecycle: shipped
---

# bb-caps
'@
    Write-LfFile (Join-Path $fixture 'capabilities' 'aa-caps.md') @'
---
name: aa-caps
summary: fixture capability
triggers: [test]
verification: example
harnesses: [echo]
kind: native
lifecycle: shipped
---

# aa-caps
'@
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $obj = $out | ConvertFrom-Json
    $titles = @($obj.gaps | Where-Object { $_.title -like 'Spine asymmetry*' } | ForEach-Object { $_.title }) -join '|'
    $echoDetail = @($obj.gaps | Where-Object { $_.title -eq 'Spine asymmetry: missing Echo realization(s)' } | ForEach-Object { $_.detail }) | Select-Object -First 1
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: spine-asymmetry gaps record per sorted cap enumeration (Echo before Foxtrot) — twin-parity traversal determinism' `
        'Spine asymmetry: missing Echo realization(s)|Spine asymmetry: missing Foxtrot realization(s)' $titles
    Assert-Eq 'self-audit.test: spine-asymmetry missing_for names follow sorted cap enumeration (aa-caps before bb-caps)' `
        'Native capability(s) without harnesses/echo/capabilities/<name>.md: aa-caps bb-caps' $echoDetail
} else {
    _Skip 'self-audit.test: spine-asymmetry gap-order test' 'jq not installed'
}

# --- <TEAM>-371 panel ask: a fixture with NO capabilities/ dir must not trip
# the sorted enumeration (mirrors tests/self-audit.test.sh) — Test-Path guards
# the block, the script completes, and no spine-asymmetry gap records.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    Remove-Item -LiteralPath (Join-Path $fixture 'capabilities') -Recurse -Force -ErrorAction SilentlyContinue
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $obj = $null
    try { $obj = $out | ConvertFrom-Json -ErrorAction Stop } catch { $obj = $null }
    $totalIsNumber = if ($null -ne $obj -and ($obj.total -is [int64] -or $obj.total -is [int32] -or $obj.total -is [double])) { 'number' } else { 'not-number' }
    $spineCount = if ($null -ne $obj) { @($obj.gaps | Where-Object { $_.title -like 'Spine asymmetry*' }).Count } else { -1 }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: no capabilities/ dir: script still emits valid JSON (guarded enumeration yields zero rows)' `
        'number' $totalIsNumber
    Assert-Eq 'self-audit.test: no capabilities/ dir: no spine-asymmetry gap records' `
        '0' "$spineCount"
} else {
    _Skip 'self-audit.test: no-capabilities-dir test' 'jq not installed'
}

# Helper (<TEAM>-364): injection-surface fixture layered on New-SaFixtureRepo —
# a fake config dir with a rendered CLAUDE.md, one memory store whose MEMORY.md
# is the only file (no orphan / broken-link interactions), and a vault whose
# START.md names an identity note via the FIRST wikilink (aliased, to exercise
# the |alias strip) BEFORE the `## Read Order` heading — the mechanical
# resolution rule sub-check 2.4 implements. Mirrors _sa_mk_injection_fixture.
function New-SaInjectionFixture {
    param([string]$Root)
    New-SaFixtureRepo $Root
    foreach ($d in @('config', 'mem', 'vault')) {
        New-Item -ItemType Directory -Path (Join-Path $Root $d) -Force | Out-Null
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# Rendered CLAUDE.md`n")
    for ($i = 1; $i -le 20; $i++) { [void]$sb.Append("entrypoint padding line for the injection surface fixture`n") }
    Write-LfFile (Join-Path $Root 'config' 'CLAUDE.md') $sb.ToString()
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# Memory Index`n`n")
    for ($i = 1; $i -le 12; $i++) { [void]$sb.Append("- headline entry $i — short, under the per-line cap`n") }
    Write-LfFile (Join-Path $Root 'mem' 'MEMORY.md') $sb.ToString()
    Write-LfFile (Join-Path $Root 'vault' 'START.md') @'
# START

## Who You're Working For

Work for [[Operator Profile|the operator]] first.

## Read Order

1. [[Memory Core]]
'@
    Write-LfFile (Join-Path $Root 'vault' 'Operator Profile.md') "# Operator Profile`n`nidentity note body for the injection fixture`n"
}

# --- <TEAM>-364 (a): over the soft threshold → warned=true, a pillar-2 gap, and
# the 2-pt deduction (18/20 — the fixture is otherwise clean). The identity
# component must resolve THROUGH the |alias to the note named before
# ## Read Order, not to the [[Memory Core]] link inside the read order.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaInjectionFixture $fixture
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture,
        '--memory-dir', (Join-Path $fixture 'mem'),
        '--config-dir', (Join-Path $fixture 'config'),
        '--vault-dir', (Join-Path $fixture 'vault'),
        '--injection-warn-kb', '1', '--json')
    $obj = $out | ConvertFrom-Json
    $warned = "$($obj.injection_surface.warned)"
    $gap = ''
    foreach ($g in $obj.gaps) { if ($g.title -eq 'Injection surface over soft threshold') { $gap = $g.title; break } }
    $p2 = Get-SaPillarScore $out 'memory-hygiene'
    $compCount = @($obj.injection_surface.components).Count
    $idPath = ''
    foreach ($c in $obj.injection_surface.components) { if ($c.name -eq 'identity note') { $idPath = $c.path; break } }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: injection surface warned=true when total exceeds --injection-warn-kb 1' 'True' $warned
    Assert-Eq 'self-audit.test: injection surface pillar-2 gap titled Injection surface over soft threshold recorded' `
        'Injection surface over soft threshold' $gap
    Assert-Eq 'self-audit.test: injection surface pillar 2 reflects the 2-pt soft deduction' '18' "$p2"
    Assert-Eq 'self-audit.test: injection surface all four components resolve on the full fixture' '4' "$compCount"
    if ($idPath -and $idPath.EndsWith('Operator Profile.md', [StringComparison]::Ordinal)) {
        _Pass 'self-audit.test: injection surface identity note resolves via first pre-Read-Order wikilink (alias stripped)'
    } else {
        _Fail 'self-audit.test: injection surface identity note resolves via first pre-Read-Order wikilink (alias stripped)' "expected path ending 'Operator Profile.md', got [$idPath]"
    }
} else {
    _Skip 'self-audit.test: injection-surface warn test' 'jq not installed'
}

# --- <TEAM>-364 (b): a huge threshold → no warn, no gap, no deduction. The
# measurement itself still reports (soft warn ≠ measurement gate).
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaInjectionFixture $fixture
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture,
        '--memory-dir', (Join-Path $fixture 'mem'),
        '--config-dir', (Join-Path $fixture 'config'),
        '--vault-dir', (Join-Path $fixture 'vault'),
        '--injection-warn-kb', '4096', '--json')
    $obj = $out | ConvertFrom-Json
    $warned = "$($obj.injection_surface.warned)"
    $gapCount = @($obj.gaps | Where-Object { $_.title -eq 'Injection surface over soft threshold' }).Count
    $p2 = Get-SaPillarScore $out 'memory-hygiene'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: injection surface warned=false under a huge threshold' 'False' $warned
    Assert-Eq 'self-audit.test: injection surface no over-threshold gap under a huge threshold' '0' "$gapCount"
    Assert-Eq 'self-audit.test: injection surface pillar 2 stays 20/20 under a huge threshold' '20' "$p2"
} else {
    _Skip 'self-audit.test: injection-surface clean test' 'jq not installed'
}

# --- <TEAM>-364 (c): markdown output carries the ## Injection surface section
# (between the pillar table and Top gaps) with per-component lines and the
# Total line naming the threshold + OK/OVER verdict.
$fixture = New-SaTmp
New-SaInjectionFixture $fixture
$outOver = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture,
    '--memory-dir', (Join-Path $fixture 'mem'),
    '--config-dir', (Join-Path $fixture 'config'),
    '--vault-dir', (Join-Path $fixture 'vault'),
    '--injection-warn-kb', '1')
$outOk = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture,
    '--memory-dir', (Join-Path $fixture 'mem'),
    '--config-dir', (Join-Path $fixture 'config'),
    '--vault-dir', (Join-Path $fixture 'vault'),
    '--injection-warn-kb', '4096')
Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
Assert-Contains 'self-audit.test: injection surface markdown section heading present' `
    $outOver '## Injection surface'
Assert-Contains 'self-audit.test: injection surface markdown per-component line present' `
    $outOver 'MEMORY.md (largest store):'
Assert-Contains 'self-audit.test: injection surface markdown Total line says OVER past the threshold' `
    $outOver 'soft threshold 1 KB (OVER)'
Assert-Contains 'self-audit.test: injection surface markdown Total line says OK under the threshold' `
    $outOk 'soft threshold 4096 KB (OK)'

# --- <TEAM>-364 (d): a component that cannot resolve is SKIPPED by name, never
# an error — no vault dir → START.md + identity note both land in .skipped and
# the remaining two components still measure.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaInjectionFixture $fixture
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture,
        '--memory-dir', (Join-Path $fixture 'mem'),
        '--config-dir', (Join-Path $fixture 'config'),
        '--injection-warn-kb', '4096', '--json')
    $obj = $out | ConvertFrom-Json
    $skippedList = @($obj.injection_surface.skipped) -join '|'
    $compCount = @($obj.injection_surface.components).Count
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: injection surface vault-side components listed in skipped when no vault dir' `
        'START.md (vault)|identity note' $skippedList
    Assert-Eq 'self-audit.test: injection surface the two resolvable components still measure' '2' "$compCount"
} else {
    _Skip 'self-audit.test: injection-surface skip test' 'jq not installed'
}

# --- <TEAM>-364 (e): when NO component resolves (no memory store, no config,
# no vault), the measurement is not-measured — JSON injection_surface is null
# (a distinct state from a 0-byte surface) and the markdown says so.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture, '--json')
    $obj = $out | ConvertFrom-Json
    $nullType = if ($null -eq $obj.injection_surface) { 'null' } else { 'not-null' }
    $mdOut = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture)
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: injection surface JSON injection_surface is null when nothing resolves' `
        'null' $nullType
    Assert-Contains 'self-audit.test: injection surface markdown reports not-measured when nothing resolves' `
        $mdOut '_(not measured — no injection-surface component resolved)_'
} else {
    _Skip 'self-audit.test: injection-surface null test' 'jq not installed'
}

# --- <TEAM>-394: codex-native memory registry — audit-covered, not canonical ---
# Twin of the bash codex-registry block: the registry gets its own pillar-2
# surface (sub-check 2.5) — index PRESENCE only; its sidecars must never trip
# the 2.1 orphan check.
# <TEAM>-468: the 2.2/2.3 recall caps are claude-side recall semantics and do
# NOT apply to the codex registry (no size cap or read-side truncation exists in
# openai/codex at rust-v0.144.1). Size is reported informationally instead — no
# deduction, no gap — and the registry is excluded from the sub-check-2.4
# injection-surface largest-store scan.
function New-SaCodexCase {
    param([string]$Root)
    $mem = Join-Path $Root 'mem'
    $cx = Join-Path $Root 'codex-mem'
    New-Item -ItemType Directory -Path $mem -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $cx 'rollout_summaries') -Force | Out-Null
    Write-LfFile (Join-Path $mem 'MEMORY.md') "- [note](note.md) — fixture note`n"
    Write-LfFile (Join-Path $mem 'note.md') "body`n"
    Write-LfFile (Join-Path $cx 'MEMORY.md') "- codex fact one`n"
    Write-LfFile (Join-Path $cx 'memory_summary.md') "summary sidecar`n"
    Write-LfFile (Join-Path $cx 'raw_memories.md') "raw sidecar`n"
}

if ($jqAvail) {
    # Clean registry + sidecars → 20/20, no orphan false-trip.
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    New-SaCodexCase $fixture
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture,
        '--memory-dir', (Join-Path $fixture 'mem'),
        '--codex-memory-dir', (Join-Path $fixture 'codex-mem'), '--json')
    $mdOut = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture,
        '--memory-dir', (Join-Path $fixture 'mem'),
        '--codex-memory-dir', (Join-Path $fixture 'codex-mem'))
    $score = Get-SaPillarScore $out 'memory-hygiene'
    # <TEAM>-468: size is reported as an additive optional JSON field, and every
    # pre-existing top-level field keeps its name and position.
    $regBytes = (Get-Item -LiteralPath (Join-Path $fixture 'codex-mem' 'MEMORY.md')).Length
    $cxObj = $out | ConvertFrom-Json
    $cxBytes = [string]$cxObj.codex_registry_bytes
    $fields = (($cxObj.PSObject.Properties | ForEach-Object { $_.Name }) -join ',')
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: codex registry clean registry + sidecars score 20/20 (no orphan false-trip)' '20' "$score"
    Assert-NotContains 'self-audit.test: codex registry sidecars never trip the orphan check' $out 'Orphan memory file(s)'
    Assert-Eq 'self-audit.test: codex registry JSON reports the registry byte size informationally' `
        "$regBytes" "$cxBytes"
    Assert-Eq 'self-audit.test: codex registry JSON stays backward-compatible (existing fields intact, new field additive)' `
        'date,total,unscored_count,pillars,injection_surface,gaps,skipped,codex_registry_bytes,semantic_currentness,orientation_surface,recall_failures,operator_subgates' "$fields"
    Assert-Contains 'self-audit.test: codex registry markdown carries the non-scoring informational size line' `
        $mdOut "- codex memory registry (informational, not scored): $regBytes bytes"

    # <TEAM>-468: over-cap content in the codex registry deducts NOTHING — no
    # line-cap gap, no size-cap gap, pillar 2 stays 20/20; the size surfaces only
    # via the informational field.
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    New-SaCodexCase $fixture
    [System.IO.File]::AppendAllText((Join-Path $fixture 'codex-mem' 'MEMORY.md'), ('- ' + ('x' * 320) + "`n"))
    $cxPad = '- ' + ('y' * 200) + "`n"
    $cxSb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 200; $i++) { [void]$cxSb.Append($cxPad) }
    [System.IO.File]::AppendAllText((Join-Path $fixture 'codex-mem' 'MEMORY.md'), $cxSb.ToString())
    $regBytes = (Get-Item -LiteralPath (Join-Path $fixture 'codex-mem' 'MEMORY.md')).Length
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture,
        '--memory-dir', (Join-Path $fixture 'mem'),
        '--codex-memory-dir', (Join-Path $fixture 'codex-mem'), '--json')
    $score = Get-SaPillarScore $out 'memory-hygiene'
    $cxObj = $out | ConvertFrom-Json
    $cxBytes = [string]$cxObj.codex_registry_bytes
    $cxGaps = (@($cxObj.gaps | Where-Object { $_.title -like '*Codex registry*' }) | ForEach-Object { $_.title }) -join '|'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: codex registry over-cap size + long lines deduct nothing (pillar 2 stays 20)' '20' "$score"
    Assert-Eq 'self-audit.test: codex registry over-cap content records no codex cap gap' '' "$cxGaps"
    Assert-NotContains 'self-audit.test: codex registry no line-cap gap title remains' `
        $out 'Codex registry MEMORY.md entries over line-length cap'
    Assert-NotContains 'self-audit.test: codex registry no size-cap gap title remains' `
        $out 'Codex registry MEMORY.md over recall cap'
    Assert-Eq 'self-audit.test: codex registry informational byte size reported for the over-cap registry' `
        "$regBytes" "$cxBytes"

    # <TEAM>-468: a codex registry LARGER than every claude store must not win
    # the injection-surface largest-store pick — it is excluded from that scan.
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    New-SaCodexCase $fixture
    $cxPad = '- ' + ('z' * 200) + "`n"
    $cxSb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 300; $i++) { [void]$cxSb.Append($cxPad) }
    [System.IO.File]::AppendAllText((Join-Path $fixture 'codex-mem' 'MEMORY.md'), $cxSb.ToString())
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture,
        '--memory-dir', (Join-Path $fixture 'mem'),
        '--codex-memory-dir', (Join-Path $fixture 'codex-mem'), '--json')
    $cxObj = $out | ConvertFrom-Json
    $largestPath = [string](@($cxObj.injection_surface.components |
        Where-Object { $_.name -eq 'MEMORY.md (largest store)' } | ForEach-Object { $_.path }) -join '')
    # New-SaTmp's RETURNED path is the canonical one (macOS /var symlink), so
    # compare against it rather than a re-derived temp root.
    $expectedLargest = Join-Path (Join-Path $fixture 'mem') 'MEMORY.md'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: codex registry oversized registry never wins the injection-surface largest-store pick' `
        "$expectedLargest" "$largestPath"

    # Missing MEMORY.md in the registry → blind-kickoff gap + 14/20.
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    New-SaCodexCase $fixture
    Remove-Item -LiteralPath (Join-Path $fixture 'codex-mem' 'MEMORY.md') -Force
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture,
        '--memory-dir', (Join-Path $fixture 'mem'),
        '--codex-memory-dir', (Join-Path $fixture 'codex-mem'), '--json')
    $score = Get-SaPillarScore $out 'memory-hygiene'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Contains 'self-audit.test: codex registry missing MEMORY.md records the blind-kickoff gap' `
        $out 'Codex memory registry has no MEMORY.md index'
    Assert-Eq 'self-audit.test: codex registry missing-index deduction lands on pillar 2' '14' "$score"

    # Non-existent path → surface skipped, pillar 2 unaffected, no codex gap.
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    New-SaCodexCase $fixture
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture,
        '--memory-dir', (Join-Path $fixture 'mem'),
        '--codex-memory-dir', (Join-Path $fixture 'does-not-exist'), '--json')
    $score = Get-SaPillarScore $out 'memory-hygiene'
    $cxBytes = [string](($out | ConvertFrom-Json).codex_registry_bytes)
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: codex registry non-existent path skips the surface (pillar 2 unaffected)' '20' "$score"
    Assert-NotContains 'self-audit.test: codex registry non-existent path records no codex gap' `
        $out 'Codex memory registry'
    Assert-Eq 'self-audit.test: codex registry non-existent path reports codex_registry_bytes as null' '' "$cxBytes"

    # Panel finding (<TEAM>-468): a codex-ONLY install (zero claude stores →
    # pillar 2 UNSCOREDs at its early return) must STILL report the registry
    # size — Measure-CodexRegistry runs before the early return. Twin of
    # _test_codex_only_install_still_reports_registry.
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    New-SaCodexCase $fixture
    $regBytes = [string](Get-Item -LiteralPath (Join-Path (Join-Path $fixture 'codex-mem') 'MEMORY.md')).Length
    $out = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture,
        '--memory-dir', (Join-Path $fixture 'no-claude-store'),
        '--codex-memory-dir', (Join-Path $fixture 'codex-mem'), '--json')
    $mdOut = Invoke-SelfAudit @('--isolated', '--repo-root', $fixture,
        '--memory-dir', (Join-Path $fixture 'no-claude-store'),
        '--codex-memory-dir', (Join-Path $fixture 'codex-mem'))
    $cxObj = $out | ConvertFrom-Json
    $unscored = [string]$cxObj.pillars.'memory-hygiene'.unscored
    $cxBytes = [string]$cxObj.codex_registry_bytes
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: codex-only pillar 2 is UNSCORED with zero claude stores' 'True' "$unscored"
    Assert-Eq 'self-audit.test: codex-only registry byte size is still reported in JSON' "$regBytes" "$cxBytes"
    Assert-Contains 'self-audit.test: codex-only markdown still carries the informational size line' `
        $mdOut "- codex memory registry (informational, not scored): $regBytes bytes"
} else {
    _Skip 'self-audit.test: codex-registry clean test' 'jq not installed'
    _Skip 'self-audit.test: codex-registry over-cap informational test' 'jq not installed'
    _Skip 'self-audit.test: codex-registry injection-surface exclusion test' 'jq not installed'
    _Skip 'self-audit.test: codex-registry missing-index test' 'jq not installed'
    _Skip 'self-audit.test: codex-registry bogus-path test' 'jq not installed'
    _Skip 'self-audit.test: codex-only registry-report test' 'jq not installed'
}

# --- orientation surface (<TEAM>-524) ----------------------------------------
# Windows-native twin of the tests/self-audit.test.sh orientation-surface block.
# The effective Mode 1 kickoff surface = static entrypoint + the compiled spine
# capability bodies (session-agent + closeout) the kickoff mandates + the vault
# lesson index read at every orient. Its OWN section, its OWN JSON key, and —
# the load-bearing part — it NEVER moves total, a pillar score, or gaps.

# New-SaOrientHome — a rendered harness home fixture: an entrypoint file plus the
# two compiled spine skill bodies.
function New-SaOrientHome {
    param([string]$Home_, [string]$Entry)
    Write-LfFile (Join-Path $Home_ $Entry) "entrypoint body`nsecond line`n"
    Write-LfFile (Join-Path $Home_ 'skills' 'session-agent' 'SKILL.md') "session-agent compiled body`n"
    Write-LfFile (Join-Path $Home_ 'skills' 'closeout' 'SKILL.md') "closeout compiled body`nline two`nline three`n"
}
function Get-SaFileBytes {
    param([string]$Path)
    return [int]([System.IO.FileInfo]::new($Path).Length)
}

$oriFixture = New-SaTmp
New-SaFixtureRepo $oriFixture
$oriCfg = Join-Path $oriFixture 'config'
$oriVault = Join-Path $oriFixture 'vault'
New-SaOrientHome $oriCfg 'CLAUDE.md'
Write-LfFile (Join-Path $oriVault '04-Lessons' '_index.md') "| Trigger | Lesson |`n| --- | --- |`n| before a fetch | use the CLI |`n"

$oriEpB = Get-SaFileBytes (Join-Path $oriCfg 'CLAUDE.md')
$oriSpB = (Get-SaFileBytes (Join-Path $oriCfg 'skills' 'session-agent' 'SKILL.md')) +
          (Get-SaFileBytes (Join-Path $oriCfg 'skills' 'closeout' 'SKILL.md'))
$oriLiB = Get-SaFileBytes (Join-Path $oriVault '04-Lessons' '_index.md')
$oriWant = $oriEpB + $oriSpB + $oriLiB

$oriJson = (Invoke-SelfAudit @('--isolated', '--repo-root', $oriFixture,
    '--config-dir', $oriCfg, '--vault-dir', $oriVault, '--json')) | ConvertFrom-Json
$oriMd = Invoke-SelfAudit @('--isolated', '--repo-root', $oriFixture,
    '--config-dir', $oriCfg, '--vault-dir', $oriVault)

Assert-Eq 'self-audit.test: orientation surface measured against a rendered harness home' `
    'True' ([string]$oriJson.orientation_surface.measured)
Assert-Eq 'self-audit.test: orientation surface the claude render gets a per-harness row' `
    'claude' $oriJson.orientation_surface.harnesses[0].harness
Assert-Eq 'self-audit.test: orientation surface row names the compiled entrypoint' `
    'CLAUDE.md' $oriJson.orientation_surface.harnesses[0].entrypoint
Assert-Eq 'self-audit.test: orientation surface entrypoint_bytes matches the compiled entrypoint' `
    "$oriEpB" ([string]$oriJson.orientation_surface.harnesses[0].entrypoint_bytes)
# The whole point of <TEAM>-524: the mandatory capability bodies are counted,
# not just the static entrypoint file.
Assert-Eq 'self-audit.test: orientation surface spine_bytes covers session-agent + closeout, not the entrypoint alone' `
    "$oriSpB" ([string]$oriJson.orientation_surface.harnesses[0].spine_bytes)
Assert-Eq 'self-audit.test: orientation surface the vault lesson index is measured, not silently dropped' `
    "$oriLiB" ([string]$oriJson.orientation_surface.harnesses[0].lesson_index_bytes)
Assert-Eq 'self-audit.test: orientation surface effective_total_bytes = entrypoint + spine + lesson index' `
    "$oriWant" ([string]$oriJson.orientation_surface.harnesses[0].effective_total_bytes)
Assert-Eq 'self-audit.test: orientation surface lesson index status is measured' `
    'measured' $oriJson.orientation_surface.lesson_index.status
Assert-Eq 'self-audit.test: orientation surface aggregate total_bytes sums the harness rows' `
    "$oriWant" ([string]$oriJson.orientation_surface.total_bytes)
Assert-Contains 'self-audit.test: orientation surface an unresolved harness home is a named skip' `
    (@($oriJson.orientation_surface.skipped) -join '|') 'hermes (HERMES_HOME) not set'
Assert-Contains 'self-audit.test: orientation surface markdown has its own section' $oriMd '## Orientation surface'
Assert-Contains 'self-audit.test: orientation surface markdown states the informational boundary' `
    $oriMd 'Informational only; never scored.'

# Non-scoring proof. Same fixture, same config dir, same vault — the ONLY
# difference is the size of the compiled spine bodies (no pillar reads
# <config-dir>/skills/), so a total or gap-count delta could only come from the
# new section.
$oriPad = ('y' * 400)
$oriFatBody = (1..50 | ForEach-Object { $oriPad }) -join "`n"
Write-LfFile (Join-Path $oriCfg 'skills' 'session-agent' 'SKILL.md') ("session-agent compiled body`n" + $oriFatBody + "`n")
$oriFat = (Invoke-SelfAudit @('--isolated', '--repo-root', $oriFixture,
    '--config-dir', $oriCfg, '--vault-dir', $oriVault, '--json')) | ConvertFrom-Json
Remove-Item -LiteralPath (Join-Path $oriCfg 'skills') -Recurse -Force -ErrorAction SilentlyContinue
$oriThin = (Invoke-SelfAudit @('--isolated', '--repo-root', $oriFixture,
    '--config-dir', $oriCfg, '--vault-dir', $oriVault, '--json')) | ConvertFrom-Json

Assert-Eq 'self-audit.test: orientation surface a fat vs absent spine does NOT change the total score' `
    ([string]$oriThin.total) ([string]$oriFat.total)
Assert-Eq 'self-audit.test: orientation surface a fat vs absent spine does NOT change the gap count' `
    @($oriThin.gaps).Count @($oriFat.gaps).Count
Assert-Eq 'self-audit.test: orientation surface never enters the gap list' `
    0 @($oriFat.gaps | Where-Object { ("$($_.title)$($_.detail)$($_.fix)").ToLower().Contains('orientation') }).Count
# Positive control: the two runs really did measure different surfaces, so the
# equality above is a non-scoring proof and not a dead measurement.
if ([int]$oriFat.orientation_surface.total_bytes -gt [int]$oriThin.orientation_surface.total_bytes) {
    _Pass 'self-audit.test: orientation surface positive control — the fat run measured a larger surface than the thin run'
} else {
    _Fail 'self-audit.test: orientation surface positive control — the fat run measured a larger surface than the thin run' `
        ("expected fat > thin, got fat=[{0}] thin=[{1}]" -f $oriFat.orientation_surface.total_bytes, $oriThin.orientation_surface.total_bytes)
}
Assert-Contains 'self-audit.test: orientation surface an absent spine body is named, not silently zero' `
    ((@($oriThin.orientation_surface.harnesses[0].missing)) -join '|') 'skills/session-agent/SKILL.md'

Remove-Item -LiteralPath $oriFixture -Recurse -Force -ErrorAction SilentlyContinue

# Lesson index: an unmeasured index is NAMED, never a silent 0.
$oriFixture2 = New-SaTmp
New-SaFixtureRepo $oriFixture2
$oriCfg2 = Join-Path $oriFixture2 'config'
$oriVault2 = Join-Path $oriFixture2 'vault'
New-SaOrientHome $oriCfg2 'CLAUDE.md'
New-Item -ItemType Directory -Path (Join-Path $oriVault2 '04-Lessons') -Force | Out-Null  # index absent

$oriNoVaultRaw = Invoke-SelfAudit @('--isolated', '--repo-root', $oriFixture2, '--config-dir', $oriCfg2, '--json')
$oriNoVault = $oriNoVaultRaw | ConvertFrom-Json
$oriWithVault = (Invoke-SelfAudit @('--isolated', '--repo-root', $oriFixture2,
    '--config-dir', $oriCfg2, '--vault-dir', $oriVault2, '--json')) | ConvertFrom-Json

Assert-Contains 'self-audit.test: orientation surface no vault → lesson_index_bytes is null (unmeasured, not 0)' `
    $oriNoVaultRaw '"lesson_index_bytes": null'
Assert-Contains 'self-audit.test: orientation surface no vault is a NAMED unmeasured state' `
    $oriNoVault.orientation_surface.lesson_index.status 'unmeasured — no vault configured'
Assert-Contains 'self-audit.test: orientation surface a vault without the index names the missing path' `
    $oriWithVault.orientation_surface.lesson_index.status 'unmeasured — not found at'
Assert-Eq 'self-audit.test: orientation surface a vault without the index still reports null bytes' `
    'True' ([string]($null -eq $oriWithVault.orientation_surface.lesson_index.bytes))

Remove-Item -LiteralPath $oriFixture2 -Recurse -Force -ErrorAction SilentlyContinue

# No resolvable render home at all: measured false, total null (distinct from 0),
# every unresolved home named.
$oriFixture3 = New-SaTmp
New-SaFixtureRepo $oriFixture3
$oriNoneRaw = Invoke-SelfAudit @('--isolated', '--repo-root', $oriFixture3, '--json')
$oriNone = $oriNoneRaw | ConvertFrom-Json
$oriNoneMd = Invoke-SelfAudit @('--isolated', '--repo-root', $oriFixture3)
Assert-Eq 'self-audit.test: orientation surface no resolvable home → measured false' `
    'False' ([string]$oriNone.orientation_surface.measured)
Assert-Contains 'self-audit.test: orientation surface no resolvable home → total_bytes null (distinct from 0)' `
    $oriNoneRaw '"total_bytes": null'
Assert-Eq 'self-audit.test: orientation surface every unresolved home is named in skipped' `
    5 @($oriNone.orientation_surface.skipped).Count
Assert-Contains 'self-audit.test: orientation surface markdown still carries the section when unmeasured' `
    $oriNoneMd '## Orientation surface'
Assert-Contains 'self-audit.test: orientation surface markdown names the unmeasured state' `
    $oriNoneMd '_(not measured — no rendered harness home resolved)_'
Remove-Item -LiteralPath $oriFixture3 -Recurse -Force -ErrorAction SilentlyContinue

# Multi-harness: resolution mirrors check-drift --auto's four harness:env-var
# pairs, so a codex/hermes/agents render each gets its own row with its own
# entrypoint (and the .agents co-render, which has no entrypoint of its own,
# reports null rather than pretending to one).
$oriFixture4 = New-SaTmp
New-SaFixtureRepo $oriFixture4
$oriC = Join-Path $oriFixture4 'claude'
$oriX = Join-Path $oriFixture4 'codex'
$oriH = Join-Path $oriFixture4 'hermes'
$oriA = Join-Path $oriFixture4 'agents'
$oriU = Join-Path $oriFixture4 'cursor'
New-SaOrientHome $oriC 'CLAUDE.md'
New-SaOrientHome $oriX 'AGENTS.md'
New-SaOrientHome $oriH 'SOUL.md'
New-SaOrientHome $oriU 'AGENTS.md'
New-SaOrientHome $oriA 'unused.md'

# Non-isolated (so the env fallbacks run) with an empty fixture repo root, and
# every operator env var pinned per-invocation — no ambient leak.
$oriSaved = @{}
foreach ($k in @('CODEX_HOME', 'HERMES_HOME', 'CURSOR_CONFIG_DIR', 'AGENTS_DIR', 'OBSIDIAN_VAULT_PATH', 'CLAUDE_PRIMARY_MEMORY_DIR')) {
    $oriSaved[$k] = [Environment]::GetEnvironmentVariable($k)
}
try {
    $env:CODEX_HOME = $oriX
    $env:HERMES_HOME = $oriH
    $env:CURSOR_CONFIG_DIR = $oriU
    $env:AGENTS_DIR = $oriA
    Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue
    $oriMultiRaw = Invoke-SelfAudit @('--repo-root', $oriFixture4, '--config-dir', $oriC, '--json')
    $oriMulti = $oriMultiRaw | ConvertFrom-Json
} finally {
    foreach ($k in $oriSaved.Keys) {
        if ($null -eq $oriSaved[$k]) { Remove-Item ("Env:" + $k) -ErrorAction SilentlyContinue }
        else { Set-Item ("Env:" + $k) $oriSaved[$k] }
    }
}
Assert-Eq 'self-audit.test: orientation surface all five render homes get a row' `
    'claude|codex|hermes|cursor|agents' ((@($oriMulti.orientation_surface.harnesses | ForEach-Object { $_.harness })) -join '|')
Assert-Eq 'self-audit.test: orientation surface the codex row names AGENTS.md' `
    'AGENTS.md' $oriMulti.orientation_surface.harnesses[1].entrypoint
Assert-Eq 'self-audit.test: orientation surface the hermes row names SOUL.md' `
    'SOUL.md' $oriMulti.orientation_surface.harnesses[2].entrypoint
Assert-Eq 'self-audit.test: orientation surface the cursor row names AGENTS.md' `
    'AGENTS.md' $oriMulti.orientation_surface.harnesses[3].entrypoint
Assert-Eq 'self-audit.test: orientation surface the .agents co-render reports no entrypoint of its own' `
    'True' ([string]($null -eq $oriMulti.orientation_surface.harnesses[4].entrypoint))
Assert-Eq 'self-audit.test: orientation surface the .agents co-render still measures its spine bodies' `
    'True' ([string]([int]$oriMulti.orientation_surface.harnesses[4].spine_bytes -gt 0))
Assert-Eq 'self-audit.test: orientation surface nothing is skipped when all five resolve' `
    0 @($oriMulti.orientation_surface.skipped).Count
Remove-Item -LiteralPath $oriFixture4 -Recurse -Force -ErrorAction SilentlyContinue

# =============================================================================
# Operator sub-gates + project-note body budget
# =============================================================================

# --- operator sub-gates -------------------------------------------------------
# Operators accumulate their own semantic checkers that no audit aggregates, so
# the scorecard can read 100/100 while every one of them fails or silently
# lapses. The registry names them. What is under test is the WIRING contract —
# its own section, its own JSON key, and the load-bearing part: an operator gate
# NEVER moves total, a pillar score, or gaps.
#
# Hermetic: the fixture repo's OWN local.env carries AUDIT_SUBGATES_FILE, and
# every registered command is a stub written into the fixture — the operator's
# real registry is never read (a fixture repo-root has no operator local.env).
# This twin runs each command through `pwsh -NoProfile -Command`, so the
# registry holds PowerShell commands where the bash twin holds sh commands.
$sgFixture = New-SaTmp
New-SaFixtureRepo $sgFixture
$sgReg = Join-Path $sgFixture 'subgates.txt'
# Quoted, like every other path fixture here (see D2/D1c): an UNQUOTED value
# takes the bash-%q backslash-collapse branch in Get-SaLocalEnvValue, which
# destroys a Windows temp path (`D:\a\...` → `D:a...`) and skipped this whole
# suite on the Windows lane. The canonical local.env format quotes.
Write-LfFile (Join-Path $sgFixture 'local.env') ('AUDIT_SUBGATES_FILE="' + $sgReg + '"' + "`n")

Write-LfFile $sgReg @"
# operator sub-gates

map check = Write-Output 'map is current'
drift check = [Console]::Error.WriteLine('two entries drifted'); exit 4
no command here
"@

$sgOut = Invoke-SelfAudit @('--repo-root', $sgFixture, '--json') | ConvertFrom-Json
Assert-Eq 'self-audit.test: operator sub-gates a passing gate reports pass with exit 0' `
    'map check|pass|0' `
    ("$($sgOut.operator_subgates.gates[0].name)|$($sgOut.operator_subgates.gates[0].status)|$($sgOut.operator_subgates.gates[0].exit_code)")
Assert-Eq 'self-audit.test: operator sub-gates a passing gate carries its first output line as detail' `
    'map is current' $sgOut.operator_subgates.gates[0].detail
Assert-Eq 'self-audit.test: operator sub-gates a failing gate reports fail WITH its exit code' `
    'drift check|fail|4' `
    ("$($sgOut.operator_subgates.gates[1].name)|$($sgOut.operator_subgates.gates[1].status)|$($sgOut.operator_subgates.gates[1].exit_code)")
Assert-Eq 'self-audit.test: operator sub-gates a failing gate stderr first line is the detail' `
    'two entries drifted' $sgOut.operator_subgates.gates[1].detail
# A typo that makes a gate disappear is exactly the failure this closes, so a
# malformed line is REPORTED, never silently dropped.
Assert-Eq 'self-audit.test: operator sub-gates a malformed registry line is named, not dropped' `
    'no command here|error' `
    ("$($sgOut.operator_subgates.gates[2].name)|$($sgOut.operator_subgates.gates[2].status)")
Assert-Eq 'self-audit.test: operator sub-gates comments and blank lines register no gate' `
    3 @($sgOut.operator_subgates.gates).Count
Assert-Eq 'self-audit.test: operator sub-gates the JSON key carries a literal scored:false' `
    'False' "$($sgOut.operator_subgates.scored)"

# THE load-bearing property: informational means informational. Compared against
# the SAME fixture with the registry disabled, so score-neutrality is proved
# rather than asserted against a hard-coded number.
$sgBase = Invoke-SelfAudit @('--repo-root', $sgFixture, '--no-subgates', '--json') | ConvertFrom-Json
Assert-Eq 'self-audit.test: operator sub-gates a FAILING gate does not change the total score' `
    "$($sgBase.total)" "$($sgOut.total)"
Assert-Eq 'self-audit.test: operator sub-gates a FAILING gate does not enter the gap list' `
    @($sgBase.gaps).Count @($sgOut.gaps).Count
Assert-Eq 'self-audit.test: operator sub-gates a FAILING gate does not move the memory pillar' `
    "$($sgBase.pillars.'memory-hygiene'.score)" "$($sgOut.pillars.'memory-hygiene'.score)"

$sgMd = Invoke-SelfAudit @('--repo-root', $sgFixture)
Assert-Contains 'self-audit.test: operator sub-gates markdown has its own section' $sgMd '## Operator sub-gates'
Assert-Contains 'self-audit.test: operator sub-gates markdown renders the passing gate' `
    $sgMd '- map check: pass — map is current'
Assert-Contains 'self-audit.test: operator sub-gates markdown renders the failing gate with its exit code' `
    $sgMd '- drift check: fail (exit 4) — two entries drifted'
Assert-Contains 'self-audit.test: operator sub-gates markdown states the informational boundary' `
    $sgMd 'never scored'

# A hanging gate is bounded and reported as that gate's OWN error — the audit
# still exits 0. The timeout is injected so this costs a second, not a minute.
Write-LfFile $sgReg "hang = Start-Sleep -Seconds 30`n"
$env:SELF_AUDIT_SUBGATE_TIMEOUT = '1'
try {
    $sgSlowRaw = & pwsh -NoProfile -File $SA_SCRIPT '--repo-root' $sgFixture '--json' 2>$null
    $sgSlowRc = $LASTEXITCODE
    $sgSlow = (($sgSlowRaw -join "`n") | ConvertFrom-Json)
} finally { Remove-Item Env:SELF_AUDIT_SUBGATE_TIMEOUT -ErrorAction SilentlyContinue }
Assert-Eq 'self-audit.test: operator sub-gates a hanging gate does not fail the audit' 0 $sgSlowRc
Assert-Eq 'self-audit.test: operator sub-gates a hanging gate is bounded and reported as error' `
    'hang|error|timed out after 1s' `
    ("$($sgSlow.operator_subgates.gates[0].name)|$($sgSlow.operator_subgates.gates[0].status)|$($sgSlow.operator_subgates.gates[0].detail)")

# --no-subgates: execution off, section still rendered as a NAMED skip.
Write-LfFile $sgReg "map check = Write-Output 'ran'`n"
$sgNoSub = Invoke-SelfAudit @('--repo-root', $sgFixture, '--no-subgates', '--json') | ConvertFrom-Json
$sgNoSubMd = Invoke-SelfAudit @('--repo-root', $sgFixture, '--no-subgates')
Assert-Eq 'self-audit.test: operator sub-gates --no-subgates nulls the JSON key' `
    'True' "$($null -eq $sgNoSub.operator_subgates)"
Assert-Contains 'self-audit.test: operator sub-gates --no-subgates still renders a NAMED skip' `
    $sgNoSubMd '_(skipped — --no-subgates given)_'

# Registry configured but MISSING: a named skip, never a silent clean pass.
Write-LfFile (Join-Path $sgFixture 'local.env') ('AUDIT_SUBGATES_FILE="' + (Join-Path $sgFixture 'absent-registry.txt') + '"' + "`n")
$sgGone = Invoke-SelfAudit @('--repo-root', $sgFixture, '--json') | ConvertFrom-Json
$sgGoneMd = Invoke-SelfAudit @('--repo-root', $sgFixture)
Assert-Eq 'self-audit.test: operator sub-gates a missing registry nulls the JSON key' `
    'True' "$($null -eq $sgGone.operator_subgates)"
Assert-Contains 'self-audit.test: operator sub-gates a missing registry is a NAMED skip' `
    $sgGoneMd 'registry file not found:'

# Key UNSET: same named-skip contract, different named reason.
Write-LfFile (Join-Path $sgFixture 'local.env') "OBSIDIAN_VAULT_PATH=`n"
$sgUnsetRaw = Invoke-SelfAudit @('--repo-root', $sgFixture, '--json')
$sgUnset = $sgUnsetRaw | ConvertFrom-Json
$sgUnsetMd = Invoke-SelfAudit @('--repo-root', $sgFixture)
Assert-Eq 'self-audit.test: operator sub-gates an unset registry key nulls the JSON key' `
    'True' "$($null -eq $sgUnset.operator_subgates)"
Assert-Contains 'self-audit.test: operator sub-gates an unset registry key is a NAMED skip' `
    $sgUnsetMd 'no AUDIT_SUBGATES_FILE configured'
# The section can never vanish: an invisible sub-gate surface is the exact
# failure mode this whole lane exists to close.
Assert-Contains 'self-audit.test: operator sub-gates the section renders even when nothing ran' `
    $sgUnsetMd '## Operator sub-gates'

# JSON key ORDER: the new key is appended LAST so every pre-existing field keeps
# its position for a positional consumer.
Assert-Eq 'self-audit.test: operator sub-gates no pre-existing JSON key moved' `
    'date,total,unscored_count,pillars,injection_surface,gaps,skipped,codex_registry_bytes,semantic_currentness,orientation_surface,recall_failures,operator_subgates' `
    ((($sgUnset.PSObject.Properties | ForEach-Object { $_.Name }) -join ','))
Remove-Item -LiteralPath $sgFixture -Recurse -Force -ErrorAction SilentlyContinue

# --- Pillar 2 sub-check 2.6: project-note body budget -------------------------
# The recall caps bound the INDEX; nothing bounded the note BODIES the index
# points at — exactly what a kickoff orient dereferences. Advisory: one
# aggregate warn, never a hard cap.
$pnbFixture = New-SaTmp
New-SaFixtureRepo $pnbFixture
$pnbMem = Join-Path $pnbFixture 'memory'
New-Item -ItemType Directory -Path $pnbMem -Force | Out-Null
$pnbBody = ("---`nmetadata:`n  type: project`n---`n" + (('x' * 50 + "`n") * 400))
$pnbRefBody = ("---`nmetadata:`n  type: reference`n---`n" + (('x' * 50 + "`n") * 400))
Write-LfFile (Join-Path $pnbMem 'project-big.md') $pnbBody
Write-LfFile (Join-Path $pnbMem 'project-small.md') "---`nmetadata:`n  type: project`n---`nsmall`n"
Write-LfFile (Join-Path $pnbMem 'reference-big.md') $pnbRefBody
Write-LfFile (Join-Path $pnbMem 'MEMORY.md') "project-big.md project-small.md reference-big.md`n"

function Invoke-SaPnb {
    param([string[]]$Extra = @())
    return (Invoke-SelfAudit (@('--isolated', '--repo-root', $pnbFixture, '--memory-dir', $pnbMem) + $Extra + @('--json')) | ConvertFrom-Json)
}
function Get-PnbGaps($obj) {
    return @($obj.gaps | Where-Object { $_.title -eq 'Project-type note body over budget' })
}

$pnbOverJson = Invoke-SaPnb
$pnbGaps = Get-PnbGaps $pnbOverJson
Assert-Eq 'self-audit.test: body budget an over-budget project note raises exactly one gap' `
    1 $pnbGaps.Count
Assert-Eq 'self-audit.test: body budget the gap carries leverage 4 on pillar 2' `
    '2|4' "$($pnbGaps[0].pillar)|$($pnbGaps[0].leverage)"
Assert-Contains 'self-audit.test: body budget the gap names the offending note' `
    $pnbGaps[0].detail 'project-big.md'
Assert-Contains 'self-audit.test: body budget the gap names the soft 16 KB default' `
    $pnbGaps[0].detail 'soft 16 KB per-note budget'
# A non-project note of the same size is NOT in scope — orient dereferences
# project-type bodies, and warning on the rest is alarm fatigue.
Assert-NotContains 'self-audit.test: body budget a non-project note of the same size does not trip the warn' `
    $pnbGaps[0].detail 'reference-big.md'
Assert-Eq 'self-audit.test: body budget the warn costs exactly 2 pillar-2 points' `
    '18' "$($pnbOverJson.pillars.'memory-hygiene'.score)"

# A raised threshold clears it — the knob is real, and the check is advisory.
$pnbUnder = Invoke-SaPnb @('--project-note-warn-kb', '512')
Assert-Eq 'self-audit.test: body budget a raised threshold clears the warn' `
    0 (Get-PnbGaps $pnbUnder).Count
Assert-Eq 'self-audit.test: body budget a raised threshold clears the deduction too' `
    '20' "$($pnbUnder.pillars.'memory-hygiene'.score)"

# A garbage knob falls back to the DEFAULT silently — an advisory measurement
# must degrade to the default, never break the audit (or silently disable
# itself, which a 0-KB or negative reading would do).
foreach ($pnbBad in @('abc', '0', '-5')) {
    Assert-Eq "self-audit.test: body budget a garbage threshold ($pnbBad) falls back to the 16 KB default" `
        1 (Get-PnbGaps (Invoke-SaPnb @('--project-note-warn-kb', $pnbBad))).Count
}

# The warn is an AGGREGATE: two oversize notes still cost 2 points once.
Write-LfFile (Join-Path $pnbMem 'project-big2.md') $pnbBody
Write-LfFile (Join-Path $pnbMem 'MEMORY.md') "project-big.md project-big2.md project-small.md reference-big.md`n"
$pnbTwo = Invoke-SaPnb
Assert-Eq 'self-audit.test: body budget two oversize notes still deduct exactly once' `
    '18' "$($pnbTwo.pillars.'memory-hygiene'.score)"
Assert-Eq 'self-audit.test: body budget both oversize notes are named in the single gap' `
    'True' "$((Get-PnbGaps $pnbTwo)[0].detail.StartsWith('2 project-type'))"
Remove-Item -LiteralPath $pnbFixture -Recurse -Force -ErrorAction SilentlyContinue

# --- operator sub-gates: bounding + a runner that never runs ------------------
# The bash twin's bound had to be rebuilt around a process group (its in-process
# alarm was defeated by `trap '' ALRM` and by backgrounded children). This twin
# needed the SAME rebuild: Stop-Job left the job's grandchild pwsh running on
# Windows, so a flooding gate survived its timeout as an orphan holding the
# caller's stdout handle and wedged the whole lane — the runner is now a direct
# Process killed with its entire tree on timeout. What the crasher case pins is
# the other half: a runner that fails outright must be an ERROR or FAIL, never
# a pass — seeding the exit code to 0 and falling through would report a runner
# that never ran as a clean `pass "(no output)"`.
$sgbFixture = New-SaTmp
New-SaFixtureRepo $sgbFixture
$sgbReg = Join-Path $sgbFixture 'subgates.txt'
# Quoted — same Windows backslash-collapse trap as the fixture above.
Write-LfFile (Join-Path $sgbFixture 'local.env') ('AUDIT_SUBGATES_FILE="' + $sgbReg + '"' + "`n")

function Invoke-SaSubgate {
    param([string]$Timeout = '30')
    $prev = $env:SELF_AUDIT_SUBGATE_TIMEOUT
    $env:SELF_AUDIT_SUBGATE_TIMEOUT = $Timeout
    try { return (Invoke-SelfAudit @('--repo-root', $sgbFixture, '--json') | ConvertFrom-Json) }
    finally {
        if ($null -eq $prev) { Remove-Item Env:\SELF_AUDIT_SUBGATE_TIMEOUT -ErrorAction SilentlyContinue }
        else { $env:SELF_AUDIT_SUBGATE_TIMEOUT = $prev }
    }
}

# A gate that exits without running a command. With the direct-Process runner
# the wrapper's own `exit` carries the code through as an ordinary fail — what
# this pins is that no shape of early exit ever lands on `pass`.
Write-LfFile $sgbReg "crasher = exit 7`n"
$sgbCrash = Invoke-SaSubgate '30'
Assert-NotContains 'self-audit.test: sub-gate bounding a job with no exit status is never reported as pass' `
    "$($sgbCrash.operator_subgates.gates[0].status)" 'pass'
Assert-Eq 'self-audit.test: sub-gate bounding a nonzero gate is fail or error, never silently clean' `
    'True' "$(@('fail','error') -contains $sgbCrash.operator_subgates.gates[0].status)"

# A hanging gate is bounded and reported as this gate's OWN error.
Write-LfFile $sgbReg "hang = Start-Sleep -Seconds 30`n"
$sgbT0 = Get-Date
$sgbHang = Invoke-SaSubgate '2'
$sgbElapsed = ((Get-Date) - $sgbT0).TotalSeconds
Assert-Eq 'self-audit.test: sub-gate bounding a hanging gate is bounded and reported as a timeout' `
    'error|timed out after 2s' `
    "$($sgbHang.operator_subgates.gates[0].status)|$($sgbHang.operator_subgates.gates[0].detail)"
Assert-Eq 'self-audit.test: sub-gate bounding the hanging gate returns near its ceiling, not near its sleep' `
    'True' "$($sgbElapsed -lt 25)"

# A flooding gate: bounded in TIME by Wait-Job and in MEMORY by the file capture
# + 512-byte bounded read (never Out-String accumulation). The audit exits 0.
Write-LfFile $sgbReg "flood = while (`$true) { Write-Output ('A' * 200) }`n"
$sgbFloodRaw = & pwsh -NoProfile -File $SA_SCRIPT '--repo-root' $sgbFixture '--json' 2>$null
$sgbFloodRc = $LASTEXITCODE
Assert-Eq 'self-audit.test: sub-gate bounding a flooding gate does not fail the audit' 0 $sgbFloodRc

# A genuine fast exit 142: an ordinary failure carrying its code. (The bash twin
# must disambiguate this from its runner's own SIGALRM code by wall clock; here
# Wait-Job returns a distinct false, so no exit code can impersonate a timeout —
# the twin asymmetry is deliberate.)
Write-LfFile $sgbReg "e142 = exit 142`n"
$sgb142 = Invoke-SaSubgate '30'
Assert-Eq 'self-audit.test: sub-gate bounding a genuine fast exit 142 is a fail with its code, not a timeout' `
    'e142|fail|142' `
    "$($sgb142.operator_subgates.gates[0].name)|$($sgb142.operator_subgates.gates[0].status)|$($sgb142.operator_subgates.gates[0].exit_code)"

# Registry-wide cap: 64 entries run, the rest are NAMED, never silent.
$sgbLines = New-Object System.Text.StringBuilder
for ($i = 1; $i -le 70; $i++) { [void]$sgbLines.AppendLine("gate-$i = exit 0") }
Write-LfFile $sgbReg $sgbLines.ToString()
$sgbCap = Invoke-SaSubgate '30'
Assert-Eq 'self-audit.test: sub-gate bounding the registry cap runs exactly 64 gates' `
    64 @($sgbCap.operator_subgates.gates).Count
Assert-Eq 'self-audit.test: sub-gate bounding entries past the cap are COUNTED, never silently dropped' `
    6 $sgbCap.operator_subgates.dropped
$sgbCapMd = Invoke-SelfAudit @('--repo-root', $sgbFixture)
Assert-Contains 'self-audit.test: sub-gate bounding the cap is a NAMED skip line in the markdown' `
    $sgbCapMd 'registry capped at 64 gate(s); 6 further entr(y/ies) not run'
Remove-Item -LiteralPath $sgbFixture -Recurse -Force -ErrorAction SilentlyContinue

# --- knob arithmetic: an over-large budget must not WRAP -----------------------
# The bash twin computes `$(( KB * 1024 ))` in 64-bit signed arithmetic, where
# 18014398509481984 KB wraps the product to 0 and every note on disk lands "over
# budget" — the knob an operator typed to make the check QUIETER fires it on a
# 62-byte note instead. Both twins bound the accepted digit length so the two
# agree, and this fixture pins the PS side of that agreement.
$knobFixture = New-SaTmp
New-SaFixtureRepo $knobFixture
$knobMem = Join-Path $knobFixture 'memory'
New-Item -ItemType Directory -Path $knobMem -Force | Out-Null
Write-LfFile (Join-Path $knobMem 'project-tiny.md') "---`nmetadata:`n  type: project`n---`ntiny`n"
Write-LfFile (Join-Path $knobMem 'MEMORY.md') "project-tiny.md`n"

$knobBase = Invoke-SelfAudit @('--isolated', '--repo-root', $knobFixture, '--memory-dir', $knobMem, '--json') | ConvertFrom-Json
$knobFlag = Invoke-SelfAudit @('--isolated', '--repo-root', $knobFixture, '--memory-dir', $knobMem,
    '--project-note-warn-kb', '18014398509481984', '--json') | ConvertFrom-Json
# Same value through the local.env DATA path, which has no flag parsing in front
# of it — the knob must be validated where it is USED, not at the flag.
Write-LfFile (Join-Path $knobFixture 'local.env') "PROJECT_NOTE_BODY_WARN_KB=18014398509481984`n"
$knobEnv = Invoke-SelfAudit @('--repo-root', $knobFixture, '--memory-dir', $knobMem, '--json') | ConvertFrom-Json

Assert-Eq 'self-audit.test: body budget an overflowing knob (flag) raises NO gap on a tiny note' `
    0 @($knobFlag.gaps | Where-Object { $_.title -eq 'Project-type note body over budget' }).Count
Assert-Eq 'self-audit.test: body budget an overflowing knob (flag) leaves the memory pillar untouched' `
    "$($knobBase.pillars.'memory-hygiene'.score)" "$($knobFlag.pillars.'memory-hygiene'.score)"
Assert-Eq 'self-audit.test: body budget an overflowing knob via local.env raises NO gap either' `
    0 @($knobEnv.gaps | Where-Object { $_.title -eq 'Project-type note body over budget' }).Count
Remove-Item -LiteralPath $knobFixture -Recurse -Force -ErrorAction SilentlyContinue

# --- twin parity: mixed-case scan order ---------------------------------------
# The gap detail lists offenders in SCAN order. bash walks `find | LC_ALL=C sort`
# (ordinal, case-sensitive); this twin used `Sort-Object Name` (culture,
# case-INsensitive), so a store holding both `project-Beta…` and `project-alpha…`
# ordered them differently and the two twins stopped emitting identical details.
$mcFixture = New-SaTmp
New-SaFixtureRepo $mcFixture
$mcMem = Join-Path $mcFixture 'memory'
New-Item -ItemType Directory -Path $mcMem -Force | Out-Null
$mcBody = ("---`nmetadata:`n  type: project`n---`n" + (('x' * 50 + "`n") * 400))
# Deliberately NOT a case-only pair — a case-insensitive filesystem would
# collapse those into one file and the fixture would prove nothing.
foreach ($mcName in @('project-Beta.md', 'project-alpha.md')) {
    Write-LfFile (Join-Path $mcMem $mcName) $mcBody
}
Write-LfFile (Join-Path $mcMem 'MEMORY.md') "project-Beta.md project-alpha.md`n"
$mcOut = Invoke-SelfAudit @('--isolated', '--repo-root', $mcFixture, '--memory-dir', $mcMem, '--json') | ConvertFrom-Json
$mcDetail = @($mcOut.gaps | Where-Object { $_.title -eq 'Project-type note body over budget' })[0].detail
$mcOrder = (@(($mcDetail -split ',') | ForEach-Object {
    $t = $_.Trim(); $t = ($t -split '=')[0]; [System.IO.Path]::GetFileName($t)
} | Where-Object { $_ -like 'project-*' }) -join ' ')
# Byte order: uppercase sorts before lowercase, so Beta precedes alpha.
Assert-Eq 'self-audit.test: body budget offenders are listed in ORDINAL byte order, not culture order' `
    'project-Beta.md project-alpha.md' $mcOrder
Remove-Item -LiteralPath $mcFixture -Recurse -Force -ErrorAction SilentlyContinue
