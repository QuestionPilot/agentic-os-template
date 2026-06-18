#Requires -Version 7
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
Assert-Contains 'self-audit.test: capability ships to every spine harness' $SA_CONTENT 'harnesses: [claude, codex, hermes]'
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

# --- D1: deterministic PRIMARY memory-dir selection (with-MEMORY.md, not the
# alphabetical-first stray). Non-isolated so the CONFIG_DIR→MEMORY_DIR resolution
# runs; --config-dir pins config so the result is env-independent.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $cfg = Join-Path $fixture 'config'
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'aaa-stray' 'memory') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'zzz-primary' 'memory') -Force | Out-Null
    Write-LfFile (Join-Path $cfg 'projects' 'aaa-stray' 'memory' 'note.md') "stray`n"
    Write-LfFile (Join-Path $cfg 'projects' 'zzz-primary' 'memory' 'MEMORY.md') "# Memory Index`n`n- [Proj](project_real.md) — the operator's active project`n"
    Write-LfFile (Join-Path $cfg 'projects' 'zzz-primary' 'memory' 'project_real.md') "---`nname: project_real`n---`nreal project body`n"
    $savedOvp = $env:OBSIDIAN_VAULT_PATH
    $savedPmd = $env:CLAUDE_PRIMARY_MEMORY_DIR
    try {
        Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue
        $out = Invoke-SelfAudit @('--repo-root', $fixture, '--config-dir', $cfg, '--json')
        $p2 = Get-SaPillarScore $out 'memory-hygiene'
    } finally {
        if ($null -ne $savedOvp) { $env:OBSIDIAN_VAULT_PATH = $savedOvp } else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $savedPmd) { $env:CLAUDE_PRIMARY_MEMORY_DIR = $savedPmd } else { Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: D1 selector picks the primary memory dir (with MEMORY.md), not the alphabetical-first stray' '20' "$p2"
} else {
    _Skip 'self-audit.test: D1 primary-memory-dir test' 'jq not installed'
}

# --- D1b: explicit $CLAUDE_PRIMARY_MEMORY_DIR overrides the heuristic.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $cfg = Join-Path $fixture 'config'
    $pinned = Join-Path $fixture 'pinned-memory'
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'only' 'memory') -Force | Out-Null
    New-Item -ItemType Directory -Path $pinned -Force | Out-Null
    Write-LfFile (Join-Path $cfg 'projects' 'only' 'memory' 'note.md') "x`n"
    Write-LfFile (Join-Path $pinned 'MEMORY.md') "# Memory Index`n`n- [Proj](project_pinned.md) — pinned active project`n"
    Write-LfFile (Join-Path $pinned 'project_pinned.md') "---`nname: project_pinned`n---`npinned project body`n"
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
    Write-LfFile (Join-Path $good 'project_g.md') "---`nname: project_g`n---`nbody`n"
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

# --- D1d (Codex review): tie-break determinism — equal-count MEMORY.md dirs
# resolve to the alphabetically-first candidate.
if ($jqAvail) {
    $fixture = New-SaTmp
    New-SaFixtureRepo $fixture
    $cfg = Join-Path $fixture 'config'
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'aaa-tie' 'memory') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $cfg 'projects' 'bbb-tie' 'memory') -Force | Out-Null
    Write-LfFile (Join-Path $cfg 'projects' 'aaa-tie' 'memory' 'MEMORY.md') "# Memory Index`n`n- [A](project_a.md) — clean`n"
    Write-LfFile (Join-Path $cfg 'projects' 'aaa-tie' 'memory' 'project_a.md') "---`nname: project_a`n---`na`n"
    Write-LfFile (Join-Path $cfg 'projects' 'bbb-tie' 'memory' 'MEMORY.md') "# Memory Index`n`n- [B](project_b.md) — has orphan sibling`n"
    Write-LfFile (Join-Path $cfg 'projects' 'bbb-tie' 'memory' 'project_b.md') "---`nname: project_b`n---`nb`n"
    Write-LfFile (Join-Path $cfg 'projects' 'bbb-tie' 'memory' 'feedback_orphan.md') "orphan`n"
    $savedOvp = $env:OBSIDIAN_VAULT_PATH
    $savedPmd = $env:CLAUDE_PRIMARY_MEMORY_DIR
    try {
        Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue
        $out = Invoke-SelfAudit @('--repo-root', $fixture, '--config-dir', $cfg, '--json')
        $p2 = Get-SaPillarScore $out 'memory-hygiene'
    } finally {
        if ($null -ne $savedOvp) { $env:OBSIDIAN_VAULT_PATH = $savedOvp } else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $savedPmd) { $env:CLAUDE_PRIMARY_MEMORY_DIR = $savedPmd } else { Remove-Item Env:CLAUDE_PRIMARY_MEMORY_DIR -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'self-audit.test: D1d equal-count MEMORY.md dirs tie-break to the alphabetical-first deterministically' '20' "$p2"
} else {
    _Skip 'self-audit.test: D1d tie-break test' 'jq not installed'
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

# --- Read-only contract regression guard.
$SA_CAP_CONTENT = Get-Content -LiteralPath (Join-Path $env:REPO_ROOT 'capabilities' 'self-audit.md') -Raw
$SA_VER_CONTENT = Get-Content -LiteralPath (Join-Path $env:REPO_ROOT 'verification' 'self-audit.md') -Raw
Assert-Contains 'self-audit.test: capability spec documents --save as the only write path (Codex B-1)' $SA_CAP_CONTENT '--save'
Assert-Contains 'self-audit.test: verification recipe documents --save as the only write path (Codex B-1)' $SA_VER_CONTENT '--save'
