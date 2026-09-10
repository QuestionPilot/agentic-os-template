#Requires -Version 7
# tests/audit-systems.test.ps1 — PowerShell twin for the Audit Systems example.
#
# This extracts and executes the exact fenced Bash example from the document.
# Each result uses a minimal PATH and a runtime-created rg stub, so no real
# scanner, repository file, or live index can affect the result.

if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }

$asTmp = Join-Path ([IO.Path]::GetTempPath()) ("audit-systems-test-" + [guid]::NewGuid().ToString('N'))
$asExample = Join-Path $asTmp 'audit-example.sh'
$asDoc = Join-Path $env:REPO_ROOT 'verification' 'audit-systems.md'
$asBash = (Get-Command bash -ErrorAction SilentlyContinue).Source

if (-not $asBash) {
    _Skip 'audit systems: exact Bash example execution' 'bash is not available'
    return
}

New-Item -ItemType Directory -Path $asTmp -Force | Out-Null
$asDocText = [IO.File]::ReadAllText($asDoc)
$asFence = [regex]::Match($asDocText, '(?ms)^## Generic Example\r?\n\r?\n```bash\r?\n(.*?)^```\s*$')
if (-not $asFence.Success) {
    _Fail 'audit systems: Generic Example has an extractable bash fence'
    Remove-Item -LiteralPath $asTmp -Recurse -Force -ErrorAction SilentlyContinue
    return
}

$asUtf8NoBom = [Text.UTF8Encoding]::new($false)
# Git may check the Markdown out with CRLF, but Bash source needs LF. The
# normalized line ending preserves the exact fenced code while avoiding a
# checkout-specific false failure.
[IO.File]::WriteAllText($asExample, ($asFence.Groups[1].Value -replace "`r`n", "`n"), $asUtf8NoBom)

function Invoke-AuditSystemsExample {
    param([string]$CaseName, [string]$ScannerState)

    $fixture = Join-Path $asTmp $CaseName
    $bin = Join-Path $asTmp ($CaseName + '-bin')
    New-Item -ItemType Directory -Path $fixture, $bin -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $fixture 'README.md'), (Join-Path $fixture 'AGENTS.md') -Force | Out-Null
    if ($ScannerState -ne 'missing') {
        [IO.File]::WriteAllText((Join-Path $bin 'rg'), ("#!/bin/sh`nexit " + $ScannerState + "`n"), $asUtf8NoBom)
        & $asBash -c 'chmod +x "$1"' _ (Join-Path $bin 'rg')
        if ($LASTEXITCODE -ne 0) { throw 'could not mark the runtime rg stub executable' }
    }

    $savedPath = $env:PATH
    try {
        $env:PATH = $bin
        Push-Location $fixture
        try {
            $output = & $asBash $asExample 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
    } finally {
        $env:PATH = $savedPath
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join "`n") }
}

$match = Invoke-AuditSystemsExample 'match' '0'
Assert-Eq 'audit systems: an rg match exits 1' '1' "$($match.ExitCode)"
Assert-Contains 'audit systems: an rg match reports a failure' $match.Output 'FAIL likely secret pattern found'
Assert-NotContains 'audit systems: an rg match never reports a clean scan' $match.Output 'PASS secret pattern scan clean'

$clean = Invoke-AuditSystemsExample 'clean' '1'
Assert-Eq 'audit systems: only rg exit 1 is clean' '0' "$($clean.ExitCode)"
Assert-Contains 'audit systems: rg exit 1 reports a clean scan' $clean.Output 'PASS secret pattern scan clean'

$scannerError = Invoke-AuditSystemsExample 'error' '2'
Assert-Eq 'audit systems: an rg error exits 1' '1' "$($scannerError.ExitCode)"
Assert-Contains 'audit systems: an rg error names its exit status' $scannerError.Output 'FAIL secret pattern scan error (exit 2)'
Assert-NotContains 'audit systems: an rg error never reports a clean scan' $scannerError.Output 'PASS secret pattern scan clean'

$unknown = Invoke-AuditSystemsExample 'unknown' '126'
Assert-Eq 'audit systems: an unknown rg status exits 1' '1' "$($unknown.ExitCode)"
Assert-Contains 'audit systems: an unknown rg status is named' $unknown.Output 'FAIL secret pattern scan error (exit 126)'
Assert-NotContains 'audit systems: an unknown rg status never reports a clean scan' $unknown.Output 'PASS secret pattern scan clean'

$missing = Invoke-AuditSystemsExample 'missing' 'missing'
Assert-Eq 'audit systems: an absent rg exits 1' '1' "$($missing.ExitCode)"
Assert-Contains 'audit systems: an absent rg is a named failure' $missing.Output 'FAIL required scanner unavailable: rg'
Assert-NotContains 'audit systems: an absent rg never reports a clean scan' $missing.Output 'PASS secret pattern scan clean'

Remove-Item -LiteralPath $asTmp -Recurse -Force -ErrorAction SilentlyContinue
