#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/tiers.test.ps1 — test-tiering mechanism. Mirrors tests/tiers.test.sh.
#
# Verifies Get-TestTier / Test-TierShouldRun in tests/lib.ps1, the TEST_TIER
# wiring in tests/run.ps1 + the Makefile, the TIERS.md doc, and the
# marker-presence guard for the known clone/build-heavy files.
#
# SELF-TRIP GUARD: this file must never contain the literal slow marker as a
# column-0 comment line, or run.ps1 would classify THIS test as slow. The marker
# is assembled at runtime from non-matching halves.

# Build the canonical marker without emitting it at start-of-line in source.
$ttSlow   = 'sl' + 'ow'
$ttMarker = "# test-tier: $ttSlow"

$ttTmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ("tiers-" + [Guid]::NewGuid().ToString('N')))
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# Fixture 1: a column-0 marker → slow.
[System.IO.File]::WriteAllText((Join-Path $ttTmp 'slowfix.test.ps1'), "#Requires -Version 7`n$ttMarker`n_Pass 'x'`n", $utf8NoBom)
# Fixture 2: no marker → fast.
[System.IO.File]::WriteAllText((Join-Path $ttTmp 'fastfix.test.ps1'), "#Requires -Version 7`n# an ordinary fast test`n_Pass 'y'`n", $utf8NoBom)
# Fixture 3: marker only quoted + indented → must stay fast (the ^# anchor rejects both).
[System.IO.File]::WriteAllText((Join-Path $ttTmp 'quotedfix.test.ps1'), "#Requires -Version 7`n`$x = '$ttMarker'`n   $ttMarker`n", $utf8NoBom)
# Fixture 4: a column-0 marker on a CRLF line → still slow (the trailing-space
# class includes \r). Locks in cross-platform detection of CRLF-authored files.
[System.IO.File]::WriteAllText((Join-Path $ttTmp 'crlffix.test.ps1'), "#Requires -Version 7`r`n$ttMarker`r`n_Pass 'z'`r`n", $utf8NoBom)

Assert-Eq "Get-TestTier detects a column-0 slow marker" `
    'slow' (Get-TestTier -Path (Join-Path $ttTmp 'slowfix.test.ps1'))
Assert-Eq "Get-TestTier defaults an unmarked file to fast" `
    'fast' (Get-TestTier -Path (Join-Path $ttTmp 'fastfix.test.ps1'))
Assert-Eq "Get-TestTier ignores a quoted/indented marker (self-trip guard)" `
    'fast' (Get-TestTier -Path (Join-Path $ttTmp 'quotedfix.test.ps1'))
Assert-Eq "Get-TestTier detects a CRLF-terminated slow marker" `
    'slow' (Get-TestTier -Path (Join-Path $ttTmp 'crlffix.test.ps1'))

# --- Test-TierShouldRun honors $env:TEST_TIER (save/restore around mutation). ---
$ttHadTier = Test-Path Env:\TEST_TIER
$ttOrig    = $env:TEST_TIER

function _tt_rs([string]$p) { if (Test-TierShouldRun -Path $p) { 'run' } else { 'skip' } }

$env:TEST_TIER = 'fast'
Assert-Eq "fast tier RUNS a fast file" 'run'  (_tt_rs (Join-Path $ttTmp 'fastfix.test.ps1'))
Assert-Eq "fast tier SKIPS a slow file" 'skip' (_tt_rs (Join-Path $ttTmp 'slowfix.test.ps1'))

$env:TEST_TIER = 'full'
Assert-Eq "full tier RUNS a slow file" 'run' (_tt_rs (Join-Path $ttTmp 'slowfix.test.ps1'))

Remove-Item Env:\TEST_TIER -ErrorAction SilentlyContinue
Assert-Eq "default (unset) tier RUNS a slow file" 'run' (_tt_rs (Join-Path $ttTmp 'slowfix.test.ps1'))

$env:TEST_TIER = 'bogus'
Assert-Eq "unexpected tier value RUNS a slow file (no silent skip)" 'run' (_tt_rs (Join-Path $ttTmp 'slowfix.test.ps1'))

if ($ttHadTier) { $env:TEST_TIER = $ttOrig } else { Remove-Item Env:\TEST_TIER -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $ttTmp -ErrorAction SilentlyContinue

# --- Marker-presence guard: known clone/build-heavy files MUST stay slow.
# Both twins of each stem are checked so the marker can't drift off one side. ---
foreach ($ttStem in @('links.test', 'bootstrap.test')) {
    foreach ($ttExt in @('sh', 'ps1')) {
        Assert-Eq "slow-tier file $ttStem.$ttExt carries the marker" `
            'slow' (Get-TestTier -Path (Join-Path $env:REPO_ROOT "tests/$ttStem.$ttExt"))
    }
}

# --- Wiring guards: run.sh gate + Makefile target + the doc. ---
$ttRun = Get-Content -Raw -LiteralPath (Join-Path $env:REPO_ROOT 'tests/run.sh')
Assert-Contains "run.sh consults the tier gate before sourcing" $ttRun '_tier_should_run'

$ttMk = Get-Content -Raw -LiteralPath (Join-Path $env:REPO_ROOT 'Makefile')
Assert-Contains "Makefile defines a test-fast target" $ttMk 'test-fast:'
Assert-Contains "Makefile test-fast drives the fast tier" $ttMk 'TEST_TIER=fast'

Assert-File "tests/TIERS.md documents the tiers" (Join-Path $env:REPO_ROOT 'tests/TIERS.md')
