#!/usr/bin/env pwsh
# Report Codex project trust rows from CODEX_HOME/config.toml. The checker is
# read-only and fails instead of treating a missing parser or bad TOML as zero.
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'
# PowerShell 7.3+ can turn a nonzero native exit into a terminating error when
# this preference is true. The interpreter probe intentionally receives such
# exits while trying candidates, and the checker must preserve its own exit 2.
if ($PSVersionTable.PSVersion -ge [version]'7.3') {
    $PSNativeCommandUseErrorActionPreference = $false
}
$scriptDir = Split-Path -Parent $PSCommandPath
$pythonCandidates = @(
    @{ Command = 'python3'; Args = @() },
    @{ Command = 'python3.14'; Args = @() },
    @{ Command = 'python3.13'; Args = @() },
    @{ Command = 'python3.12'; Args = @() },
    @{ Command = 'python3.11'; Args = @() },
    @{ Command = 'python'; Args = @() },
    @{ Command = 'py'; Args = @('-3.14') },
    @{ Command = 'py'; Args = @('-3.13') },
    @{ Command = 'py'; Args = @('-3.12') },
    @{ Command = 'py'; Args = @('-3.11') }
)

foreach ($candidate in $pythonCandidates) {
    if (-not (Get-Command $candidate.Command -ErrorAction SilentlyContinue)) { continue }
    & $candidate.Command @($candidate.Args) -c 'import tomllib' *> $null
    if ($LASTEXITCODE -ne 0) { continue }
    & $candidate.Command @($candidate.Args) (Join-Path $scriptDir 'check-codex-trust.py') @Arguments
    exit $LASTEXITCODE
}

[Console]::Error.WriteLine('FAIL check-codex-trust: Python 3.11+ with tomllib is required')
exit 2
