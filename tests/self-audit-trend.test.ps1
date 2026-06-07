#Requires -Version 7
# tests/self-audit-trend.test.ps1 — Windows-native twin of
# tests/self-audit-trend.test.sh.
#
# Score-history persistence + trend view for the self-audit capability. self-audit
# gains a trend view across runs without writing into the framework tree: history
# persists in an operator-local JSONL store keyed off $env:CLAUDE_CONFIG_DIR.
# These tests exercise scripts/self-audit-history.ps1 (append/read) against a TEMP
# store only — never the operator's real store — and assert the capability prose
# documents the behavior.
#
# Mirrors tests/self-audit-trend.test.sh 1:1 — same fixtures, same assertions,
# same AC count. tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters
# in scope.

$HIST_PS = Join-Path $env:REPO_ROOT 'scripts' 'self-audit-history.ps1'
$HIST_SH = Join-Path $env:REPO_ROOT 'scripts' 'self-audit-history.sh'
$SA_PS   = Join-Path $env:REPO_ROOT 'scripts' 'self-audit.ps1'

# --- the helper script ships (and the bash twin exists) ----------------------
Assert-File 'scripts/self-audit-history.ps1 exists' $HIST_PS
# Parity placeholder for the bash twin's "is executable" assertion — the +x bit
# is a Unix concept (PS scripts run via `pwsh -File`), so we assert PRESENCE of
# the.sh twin instead, keeping the per-file assertion count aligned.
Assert-File 'scripts/self-audit-history.sh twin exists' $HIST_SH
Assert-File 'scripts/self-audit-history.ps1 twin exists' $HIST_PS

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
function Write-LfFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# Helper: run a history subcommand, optional stdin, return stdout (LF-joined).
function Invoke-Hist {
    param([string[]]$Argv, [string]$StdinText = $null)
    if ($null -ne $StdinText) {
        $out = ($StdinText | & pwsh -NoProfile -File $HIST_PS @Argv 2>$null)
    } else {
        $out = (& pwsh -NoProfile -File $HIST_PS @Argv 2>$null)
    }
    if ($out -is [array]) { return ($out -join "`n") }
    return [string]$out
}

# --- append: a self-audit -Json scorecard writes one JSONL record ------------
function Test-AppendWritesRecord {
    if (-not (Test-Path -LiteralPath $SA_PS -PathType Leaf)) { _Skip 'append writes record' 'self-audit.ps1 missing'; return }
    $tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
    $store = Join-Path $tmp.FullName 'hist.jsonl'
    $fixture = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
    foreach ($d in @('capabilities', 'verification', 'harnesses/claude/capabilities', 'harnesses/codex/capabilities')) {
        New-Item -ItemType Directory -Path (Join-Path $fixture.FullName $d) -Force | Out-Null
    }
    $scorecard = (& pwsh -NoProfile -File $SA_PS --isolated --repo-root $fixture.FullName --json 2>$null)
    if ($scorecard -is [array]) { $scorecard = $scorecard -join "`n" }
    $scorecard | & pwsh -NoProfile -File $HIST_PS append $store 2>$null | Out-Null

    $lines = 0; $total = ''; $pillarsType = ''; $hasTs = $false
    if (Test-Path -LiteralPath $store -PathType Leaf) {
        $recLines = @([System.IO.File]::ReadAllLines($store) | Where-Object { $_ -match '\S' })
        $lines = $recLines.Count
        if ($lines -ge 1) {
            $rec = $recLines[-1] | ConvertFrom-Json
            $total = [string]$rec.total
            $pillarsType = if ($rec.pillars -is [pscustomobject]) { 'object' } else { '' }
            $hasTs = [bool]($rec.PSObject.Properties.Name -contains 'timestamp')
        }
    }
    Remove-Item -LiteralPath $tmp.FullName, $fixture.FullName -Recurse -Force -ErrorAction SilentlyContinue

    if ($lines -eq 1 -and $total -and $total -ne 'null' -and $pillarsType -eq 'object' -and $hasTs) {
        _Pass 'append writes one JSONL record with total + pillars + timestamp'
    } else {
        _Fail 'append writes one JSONL record with total + pillars + timestamp' `
            @("lines=[$lines] total=[$total] pillars=[$pillarsType] ts=[$hasTs]")
    }
}
Test-AppendWritesRecord

# --- append: each run appends (does not clobber) -----------------------------
function Test-AppendIsAppendOnly {
    $tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
    $store = Join-Path $tmp.FullName 'hist.jsonl'
    $sc = '{"date":"2026-05-30","total":95,"pillars":{"a":{"score":20},"b":{"score":15}},"gaps":[],"skipped":[]}'
    1..3 | ForEach-Object { $sc | & pwsh -NoProfile -File $HIST_PS append $store 2>$null | Out-Null }
    $lines = 0
    if (Test-Path -LiteralPath $store -PathType Leaf) {
        $lines = @([System.IO.File]::ReadAllLines($store) | Where-Object { $_ -match '\S' }).Count
    }
    Remove-Item -LiteralPath $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'append is append-only: 3 runs -> 3 records' '3' ([string]$lines)
}
Test-AppendIsAppendOnly

# --- append: malformed stdin is REFUSED (no junk record) ---------------------
function Test-AppendRefusesMalformed {
    $tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
    $store = Join-Path $tmp.FullName 'hist.jsonl'
    '{"error":"jq required for --json"}' | & pwsh -NoProfile -File $HIST_PS append $store *>$null
    $rc = $LASTEXITCODE
    $exists = Test-Path -LiteralPath $store -PathType Leaf
    Remove-Item -LiteralPath $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
    if ($rc -ne 0 -and -not $exists) {
        _Pass 'append refuses a malformed scorecard and writes no record'
    } else {
        _Fail 'append refuses a malformed scorecard and writes no record' `
            @("expected non-zero exit + no store, got rc=[$rc] store_exists=[$exists]")
    }
}
Test-AppendRefusesMalformed

# --- trend: per-pillar table over the last N records, with deltas ------------
function Set-SaSeedStore {
    param([string]$Store)
    $content = @(
        '{"timestamp":"2026-05-28T10:00:00Z","total":90,"overall":90,"pillars":{"cross-layer-handoffs":20,"memory-hygiene":18,"folder-hygiene":20,"verification-coverage":12,"closeout-spine-discipline":20}}'
        '{"timestamp":"2026-05-29T10:00:00Z","total":94,"overall":94,"pillars":{"cross-layer-handoffs":20,"memory-hygiene":20,"folder-hygiene":20,"verification-coverage":14,"closeout-spine-discipline":20}}'
        '{"timestamp":"2026-05-30T10:00:00Z","total":100,"overall":100,"pillars":{"cross-layer-handoffs":20,"memory-hygiene":20,"folder-hygiene":20,"verification-coverage":20,"closeout-spine-discipline":20}}'
    ) -join "`n"
    Write-LfFile $Store ($content + "`n")
}

function Test-TrendTable {
    $tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
    $store = Join-Path $tmp.FullName 'hist.jsonl'
    Set-SaSeedStore $store
    $out = Invoke-Hist @('trend', $store, '5')
    Remove-Item -LiteralPath $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue

    Assert-Contains 'trend heading names the run count' $out 'last 3 run(s)'
    Assert-Contains 'trend has a Pillar header column' $out '| Pillar |'
    Assert-Contains 'trend shows the verification-coverage pillar row' $out '| verification-coverage |'
    Assert-Contains 'trend shows the Total row' $out '| **Total** |'
    Assert-Contains 'trend shows the Total delta latest-vs-prior (+6)' $out '| 90 | 94 | 100 | +6 |'
    Assert-Contains 'trend shows a per-pillar delta (verification-coverage +6)' $out '| verification-coverage | 12 | 14 | 20 | +6 |'
    Assert-Contains 'trend shows a flat-pillar delta as 0' $out '| cross-layer-handoffs | 20 | 20 | 20 | 0 |'
}
Test-TrendTable

# --- trend: N caps the window to the most recent records ---------------------
function Test-TrendRespectsN {
    $tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
    $store = Join-Path $tmp.FullName 'hist.jsonl'
    Set-SaSeedStore $store
    $out = Invoke-Hist @('trend', $store, '2')
    Remove-Item -LiteralPath $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Contains 'trend N=2 names 2 runs' $out 'last 2 run(s)'
    Assert-Contains 'trend N=2 keeps the two newest totals' $out '| 94 | 100 | +6 |'
    Assert-NotContains 'trend N=2 drops the oldest total column' $out '| 90 | 94 | 100 |'
}
Test-TrendRespectsN

# --- bash<->pwsh byte-parity: trend output on the same seeded store ----------
# Codex confirmation flagged that no test locks the twin
# byte-parity the design requires. Run BOTH twins on an identical store and diff
# after LF-normalizing the PS output (its only legitimate divergence). Mirrors
# the bash twin's _test_trend_twin_byte_parity; gated on bash being present.
function Test-TrendTwinByteParity {
    if (-not (Get-Command bash -ErrorAction SilentlyContinue)) { _Skip 'trend twin byte-parity' 'bash not installed'; return }
    if (-not (Test-Path -LiteralPath $HIST_SH -PathType Leaf)) { _Skip 'trend twin byte-parity' 'sh twin missing'; return }
    $tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
    $store = Join-Path $tmp.FullName 'hist.jsonl'
    Set-SaSeedStore $store
    $bOut = (& bash $HIST_SH trend $store 5 2>$null)
    if ($bOut -is [array]) { $bOut = $bOut -join "`n" }
    $pOut = (& pwsh -NoProfile -File $HIST_PS trend $store 5 2>$null)
    if ($pOut -is [array]) { $pOut = $pOut -join "`n" }
    # Normalize both to LF-only, trailing-newline-insensitive, for the compare.
    $bN = ($bOut -replace "`r", '').TrimEnd("`n")
    $pN = ($pOut -replace "`r", '').TrimEnd("`n")
    Remove-Item -LiteralPath $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
    if ($bN -ceq $pN) {
        _Pass 'trend output is byte-identical bash<->pwsh on a seeded store'
    } else {
        _Fail 'trend output is byte-identical bash<->pwsh on a seeded store' `
            @('bash and pwsh trend output diverge (LF-normalized)')
    }
}
Test-TrendTwinByteParity

# --- bash<->pwsh byte-parity: append record (modulo generated timestamp) -----
function Test-AppendTwinRecordParity {
    if (-not (Get-Command bash -ErrorAction SilentlyContinue)) { _Skip 'append twin record parity' 'bash not installed'; return }
    if (-not (Test-Path -LiteralPath $HIST_SH -PathType Leaf)) { _Skip 'append twin record parity' 'sh twin missing'; return }
    $tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
    $sc = '{"date":"2026-05-30","total":83,"pillars":{"cross-layer-handoffs":{"score":20},"memory-hygiene":{"score":16},"folder-hygiene":{"score":12},"verification-coverage":{"score":15},"closeout-spine-discipline":{"score":20}},"gaps":[],"skipped":[]}'
    $bStore = Join-Path $tmp.FullName 'b.jsonl'
    $pStore = Join-Path $tmp.FullName 'p.jsonl'
    $sc | & bash $HIST_SH append $bStore 2>$null | Out-Null
    $sc | & pwsh -NoProfile -File $HIST_PS append $pStore 2>$null | Out-Null
    $maskRe = '"timestamp":"[^"]*"'
    $bRec = (([System.IO.File]::ReadAllText($bStore)) -replace "`r", '' -replace $maskRe, '"timestamp":"<TS>"').TrimEnd("`n")
    $pRec = (([System.IO.File]::ReadAllText($pStore)) -replace "`r", '' -replace $maskRe, '"timestamp":"<TS>"').TrimEnd("`n")
    Remove-Item -LiteralPath $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'append record is byte-identical bash<->pwsh modulo timestamp' $bRec $pRec
}
Test-AppendTwinRecordParity

# --- append: store is written no-BOM + LF-only (no CRLF, no BOM) -------------
function Test-AppendStoreNoBomLf {
    $tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
    $store = Join-Path $tmp.FullName 'hist.jsonl'
    $sc = '{"date":"2026-05-30","total":77,"pillars":{"a":{"score":20}},"gaps":[],"skipped":[]}'
    $sc | & pwsh -NoProfile -File $HIST_PS append $store 2>$null | Out-Null
    $bytes = [System.IO.File]::ReadAllBytes($store)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $crCount = @($bytes | Where-Object { $_ -eq 0x0D }).Count
    Remove-Item -LiteralPath $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $hasBom -and $crCount -eq 0) {
        _Pass 'append store has no UTF-8 BOM and LF-only line endings'
    } else {
        _Fail 'append store has no UTF-8 BOM and LF-only line endings' `
            @("hasBom=[$hasBom] cr_count=[$crCount]")
    }
}
Test-AppendStoreNoBomLf

# --- trend: ordinal pillar-key order matches jq keys (case/punctuation) ------
# Codex confirmation: PS must sort pillar keys by Unicode codepoint (jq `keys`),
# not culture collation. Seed a store with mixed-case + underscore keys where the
# two orderings diverge, and assert the PS table order matches jq's codepoint
# order. (jq orders Beta,Zebra,_under,apple; collation would give _under,apple,…)
function Test-TrendOrdinalKeyOrder {
    $tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
    $store = Join-Path $tmp.FullName 'hist.jsonl'
    Write-LfFile $store '{"timestamp":"2026-05-30T10:00:00Z","total":4,"overall":4,"pillars":{"apple":1,"Beta":1,"_under":1,"Zebra":1}}'
    # jq is the source of truth for the expected codepoint order if available;
    # else fall back to the known ordinal order for these four keys.
    $expected = 'Beta,Zebra,_under,apple'
    if (Get-Command jq -ErrorAction SilentlyContinue) {
        $expected = (& jq -r '.pillars | keys | join(",")' $store 2>$null)
        if ($expected -is [array]) { $expected = $expected -join '' }
    }
    $out = (& pwsh -NoProfile -File $HIST_PS trend $store 1 2>$null)
    if ($out -is [array]) { $out = $out -join "`n" }
    $rows = @(($out -split "`n") | Where-Object { $_ -match '^\| (apple|Beta|_under|Zebra) ' } |
        ForEach-Object { ($_ -replace '^\| ([^ ]+) .*', '$1') })
    $actual = ($rows -join ',')
    Remove-Item -LiteralPath $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq 'trend pwsh key order matches jq codepoint keys (ordinal, not collation)' `
        $expected $actual
}
Test-TrendOrdinalKeyOrder

# --- trend: empty / absent store degrades gracefully (no crash) --------------
function Test-TrendNoHistory {
    $tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
    $store = Join-Path $tmp.FullName 'nope.jsonl'
    $out = & pwsh -NoProfile -File $HIST_PS trend $store 2>$null
    $rc = $LASTEXITCODE
    if ($out -is [array]) { $out = $out -join "`n" }
    Remove-Item -LiteralPath $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
    if ($rc -eq 0 -and ([string]$out).Contains('no history yet')) {
        _Pass 'trend degrades gracefully when the store is absent'
    } else {
        _Fail 'trend degrades gracefully when the store is absent' @("rc=[$rc] out=[$out]")
    }
}
Test-TrendNoHistory

# --- the store path default is operator-local (.gitignore'd) -----------------
$gitignoreContent = ''
$gitignorePath = Join-Path $env:REPO_ROOT '.gitignore'
if (Test-Path -LiteralPath $gitignorePath -PathType Leaf) {
    $gitignoreContent = [System.IO.File]::ReadAllText($gitignorePath)
}
Assert-Contains 'self-audit-history.jsonl is gitignored (operator-local store)' `
    $gitignoreContent 'self-audit-history.jsonl'

# --- the capability documents the trend behavior -----------------------------
$saTrendCap = ''
$saPath = Join-Path $env:REPO_ROOT 'capabilities' 'self-audit.md'
if (Test-Path -LiteralPath $saPath -PathType Leaf) {
    $saTrendCap = [System.IO.File]::ReadAllText($saPath)
}
Assert-Contains 'capability documents the history store filename' $saTrendCap 'self-audit-history.jsonl'
Assert-Contains 'capability documents the trend subcommand' $saTrendCap 'self-audit-history.sh'
Assert-Contains 'capability documents appending a record after each run' $saTrendCap 'append'
Assert-Contains 'capability documents the trend view' $saTrendCap 'trend'
