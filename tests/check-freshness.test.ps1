#!/usr/bin/env pwsh
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/check-freshness.test.ps1 — PowerShell twin of tests/check-freshness.test.sh.
#
# Unit acceptance for scripts/check-freshness.ps1: fresh→0, changed→1, removed→1,
# multi-stale count, the --list machine mode, and the fail-SOFT skip contract
# (exit 2) for no-manifest / no-sources-map / invalid-JSON / bad-arg.
#
# Dot-sourced by tests/run.ps1; uses Assert-* from tests/lib.ps1.
#
# (The bash twin's "no jq" skip case has no PS analogue — check-freshness.ps1
# reads the manifest via ConvertFrom-Json, no jq dependency — so the equivalent
# fail-soft path here is an invalid-JSON manifest.)

$CF = Join-Path $env:REPO_ROOT 'scripts' 'check-freshness.ps1'
Assert-File 'check-freshness.ps1 present' $CF

# New-CfFixture <dir> — build <dir>/install/.build-manifest.json recording the
# CURRENT SHA256 of <dir>/repo/a.txt + <dir>/repo/sub/b.txt (a FRESH state).
function New-CfFixture([string]$d) {
    New-Item -ItemType Directory -Path (Join-Path $d 'install') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $d 'repo/sub') -Force | Out-Null
    $a = Join-Path $d 'repo/a.txt'
    $b = Join-Path $d 'repo/sub/b.txt'
    [IO.File]::WriteAllText($a, "alpha`n")
    [IO.File]::WriteAllText($b, "beta`n")
    $ha = (Get-FileHash -Algorithm SHA256 -LiteralPath $a).Hash.ToLower()
    $hb = (Get-FileHash -Algorithm SHA256 -LiteralPath $b).Hash.ToLower()
    $m = [ordered]@{ harness = 'claude'; sources = [ordered]@{ 'a.txt' = $ha; 'sub/b.txt' = $hb } }
    [IO.File]::WriteAllText((Join-Path $d 'install/.build-manifest.json'), ($m | ConvertTo-Json -Depth 5))
}

function New-CfTmp {
    $p = Join-Path ([IO.Path]::GetTempPath()) ('check-freshness-' + [Guid]::NewGuid().Guid.Substring(0, 8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

# --- fresh -----------------------------------------------------------------
$D1 = New-CfTmp; New-CfFixture $D1
$o = (& pwsh -NoProfile -File $CF --manifest (Join-Path $D1 'install') --repo (Join-Path $D1 'repo') 2>$null | Out-String)
$rc = $LASTEXITCODE
Assert-Eq       'check-freshness: fresh exits 0'          '0' "$rc"
Assert-Contains 'check-freshness: fresh prints PASS'      $o  'PASS install is current'
$o = (& pwsh -NoProfile -File $CF --manifest (Join-Path $D1 'install') --repo (Join-Path $D1 'repo') --list 2>$null | Out-String)
$rc = $LASTEXITCODE
Assert-Eq       'check-freshness: fresh --list exits 0'   '0' "$rc"
Assert-Eq       'check-freshness: fresh --list is empty'  ''  ($o.Trim())
Remove-Item -Recurse -Force $D1

# --- changed source --------------------------------------------------------
$D2 = New-CfTmp; New-CfFixture $D2
[IO.File]::WriteAllText((Join-Path $D2 'repo/a.txt'), "CHANGED`n")
$o = (& pwsh -NoProfile -File $CF --manifest (Join-Path $D2 'install') --repo (Join-Path $D2 'repo') 2>$null | Out-String)
$rc = $LASTEXITCODE
Assert-Eq       'check-freshness: changed exits 1'        '1' "$rc"
Assert-Contains 'check-freshness: changed prints STALE n/total' $o 'STALE 1 of 2'
Assert-Contains 'check-freshness: changed names the file' $o  'a.txt'
$o = (& pwsh -NoProfile -File $CF --manifest (Join-Path $D2 'install') --repo (Join-Path $D2 'repo') --list 2>$null | Out-String)
$rc = $LASTEXITCODE
Assert-Eq       'check-freshness: changed --list exits 1' '1' "$rc"
Assert-Eq       'check-freshness: changed --list prints just the path' 'a.txt' ($o.Trim())
Remove-Item -Recurse -Force $D2

# --- removed source --------------------------------------------------------
$D3 = New-CfTmp; New-CfFixture $D3
Remove-Item -Force (Join-Path $D3 'repo/sub/b.txt')
$o = (& pwsh -NoProfile -File $CF --manifest (Join-Path $D3 'install') --repo (Join-Path $D3 'repo') --list 2>$null | Out-String)
$rc = $LASTEXITCODE
Assert-Eq       'check-freshness: removed source exits 1' '1' "$rc"
Assert-Eq       'check-freshness: removed source listed'  'sub/b.txt' ($o.Trim())
Remove-Item -Recurse -Force $D3

# --- both stale → count = 2 ------------------------------------------------
$D4 = New-CfTmp; New-CfFixture $D4
[IO.File]::WriteAllText((Join-Path $D4 'repo/a.txt'), "x`n")
[IO.File]::WriteAllText((Join-Path $D4 'repo/sub/b.txt'), "y`n")
$o = (& pwsh -NoProfile -File $CF --manifest (Join-Path $D4 'install') --repo (Join-Path $D4 'repo') 2>$null | Out-String)
Assert-Contains 'check-freshness: both-stale count is 2 of 2' $o 'STALE 2 of 2'
$lst = (& pwsh -NoProfile -File $CF --manifest (Join-Path $D4 'install') --repo (Join-Path $D4 'repo') --list 2>$null | Out-String)
$n = @($lst -split "`n" | Where-Object { $_.Trim() -ne '' }).Count
Assert-Eq       'check-freshness: both-stale --list has 2 lines' '2' "$n"
Remove-Item -Recurse -Force $D4

# --- skip: no manifest (fail-soft, exit 2) ---------------------------------
$D5 = New-CfTmp; New-CfFixture $D5
Assert-Exit     'check-freshness: missing manifest exits 2 (skip)' 2 -- pwsh -NoProfile -File $CF --manifest (Join-Path $D5 'nope') --repo (Join-Path $D5 'repo')
$o = (& pwsh -NoProfile -File $CF --manifest (Join-Path $D5 'nope') --repo (Join-Path $D5 'repo') --list 2>$null | Out-String)
$rc = $LASTEXITCODE
Assert-Eq       'check-freshness: missing manifest --list exits 2' '2' "$rc"
Assert-Eq       'check-freshness: missing manifest --list silent on stdout' '' ($o.Trim())
Remove-Item -Recurse -Force $D5

# --- skip: manifest with no sources map (exit 2) ---------------------------
$D6 = New-CfTmp; New-CfFixture $D6
[IO.File]::WriteAllText((Join-Path $D6 'install/.build-manifest.json'), '{"harness":"claude"}')
Assert-Exit     'check-freshness: no sources map exits 2 (skip)' 2 -- pwsh -NoProfile -File $CF --manifest (Join-Path $D6 'install') --repo (Join-Path $D6 'repo')
Remove-Item -Recurse -Force $D6

# --- skip: invalid-JSON manifest (PS fail-soft, exit 2) --------------------
$D7 = New-CfTmp; New-CfFixture $D7
[IO.File]::WriteAllText((Join-Path $D7 'install/.build-manifest.json'), 'not valid json {{{')
Assert-Exit     'check-freshness: invalid-JSON manifest exits 2 (skip)' 2 -- pwsh -NoProfile -File $CF --manifest (Join-Path $D7 'install') --repo (Join-Path $D7 'repo')
Remove-Item -Recurse -Force $D7

# --- bad arg → exit 2 ------------------------------------------------------
Assert-Exit     'check-freshness: unknown argument exits 2' 2 -- pwsh -NoProfile -File $CF --bogus

# NOTE: the bash twin's "value-less --manifest/--repo must not spin" regression
# (Codex adversarial #1 — bash leaves $# unchanged when `shift 2` exceeds $#)
# has NO PowerShell analogue. PS binds --manifest/--repo to the typed [string]
# params, and a value-less flag fails at PARAMETER BINDING before the script
# body runs — no parse loop exists to spin. (Same divergence class as the
# bash "no jq" vs PS "invalid-JSON" skip case above.)
