#Requires -Version 7
<#
.SYNOPSIS
    closeout-gate.ps1 — ONE fail-closed wrapper for the deterministic pre-write
    checks a closeout composes by hand before it writes a drafted durable
    artifact (a session log, a distilled lesson note) into the vault.
    PowerShell twin of scripts/closeout-gate.sh.

.DESCRIPTION
    WHY THIS EXISTS. capabilities/closeout.md §6 states the contract in prose:
    "all three pre-write gates must pass (fail closed)" — the injection scan
    (§5), the wikilink check (§4), and the machine-path scan (§4). Composing
    three commands by hand at write time is exactly where one silently gets
    dropped: a skipped gate looks identical to a passed one in a transcript, and
    the miss only surfaces on the NEXT vault audit — after the artifact already
    landed. This wrapper makes the SET the unit: one invocation, one verdict,
    and a MISSING gate script is a FAILURE, not a skip.

    The checks it runs, in the order closeout.md §6 lists them:

      injection-scan  check-memory-drift.ps1 -InjectionScan <draft>
                      Bare line-leading prompt-injection directives copied
                      verbatim from untrusted tool/web output into a trusted
                      section.
      wikilinks       check-wikilinks.ps1 -Draft <draft> [-Vault <vault>]
                      Every [[wikilink]] resolves the way the vault audit
                      resolves it. Needs a vault: with NONE CONFIGURED at all
                      this is a NAMED SKIP (an inapplicable surface, not a
                      missing gate). A vault that IS configured but whose
                      directory does not exist is a FAILURE — see the contract.
      machine-paths   check-machine-paths.ps1 -Draft <draft>
                      No machine-specific absolute home path in the durable file.

    FAIL-CLOSED CONTRACT, stated precisely because the two non-pass outcomes are
    easy to conflate:
      - A check that RUNS and reports a finding  -> FAIL (exit 1).
      - A check whose SCRIPT IS ABSENT           -> FAIL (exit 1). A gate that
        cannot run has proven nothing; treating it as a skip is the fail-open
        hole this wrapper exists to close.
      - A check whose TARGET SURFACE IS ABSENT   -> SKIP, named, exit unaffected.
        Only the wikilink check has such a surface (the vault), and the skip is
        narrow: NO vault configured at all (no -Vault AND
        $env:OBSIDIAN_VAULT_PATH unset/empty).
      - A check whose surface IS CONFIGURED but BROKEN -> FAIL (exit 1), naming
        the path. A configured vault directory that does not exist is a
        misspelled or unsynced destination, not "no vault": the durable write it
        gates would land somewhere the operator never inspected.

    PRECEDENCE, and it is load-bearing, in this order:
      1. SCRIPT EXISTENCE. Evaluating anything else first would let the one
         check that HAS an inapplicable surface (wikilinks) report SKIP while
         its gate script is missing — an unrunnable gate laundered into a benign
         skip, and the gate could then PASS. Missing script wins, always.
      2. SURFACE BROKEN (configured vault that does not exist) -> FAIL.
      3. SURFACE ABSENT (nothing configured) -> SKIP.

    -Vault defaults to $env:OBSIDIAN_VAULT_PATH. Nothing else is configurable:
    the check set IS the contract, so it is not caller-selectable.

    Test override: $env:CLOSEOUT_GATE_SCRIPTS_DIR points the wrapper at a fixture
    scripts/ dir (same convention as $env:SELF_AUDIT_CURRENTNESS_BIN in
    self-audit.ps1).

.PARAMETER Draft
    Path to the drafted file to gate. Required unless -List.

.PARAMETER Vault
    Vault root for the wikilink check. Defaults to $env:OBSIDIAN_VAULT_PATH.

.PARAMETER List
    Print the check set and what each would do, then exit 0. Runs nothing.

.NOTES
    Exit codes:
        0 — every applicable check passed (skips do not fail the gate)
        1 — at least one check failed, or a configured check's script is missing
        2 — usage error (missing/unreadable draft, bad args)

    Tests: tests/closeout-gate.test.ps1 (+ the .sh twin).
#>

[CmdletBinding()]
param(
    [string]$Draft = '',
    [string]$Vault = '',
    [switch]$List,
    [Alias('h')][switch]$Help,

    # POSIX-style --draft / --vault / --list / --help so bash-trained operators
    # get muscle-memory parity with the .sh twin (mirrors check-wikilinks.ps1).
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$i = 0
while ($i -lt $Rest.Count) {
    $arg = $Rest[$i]
    switch -CaseSensitive ($arg) {
        '--draft' {
            if ($i + 1 -ge $Rest.Count) { [Console]::Error.WriteLine('FAIL --draft requires a value'); exit 2 }
            $Draft = $Rest[$i + 1]; $i += 2
        }
        '--vault' {
            if ($i + 1 -ge $Rest.Count) { [Console]::Error.WriteLine('FAIL --vault requires a value'); exit 2 }
            $Vault = $Rest[$i + 1]; $i += 2
        }
        '--list' { $List = [switch]$true; $i += 1 }
        '-h'     { $Help = [switch]$true; $i += 1 }
        '--help' { $Help = [switch]$true; $i += 1 }
        default  { [Console]::Error.WriteLine("FAIL unknown arg: $arg"); exit 2 }
    }
}

if ($Help.IsPresent) {
    Get-Help -Full $PSCommandPath | Out-String | Write-Host
    exit 0
}

if ([string]::IsNullOrEmpty($Vault)) {
    $envVault = [Environment]::GetEnvironmentVariable('OBSIDIAN_VAULT_PATH')
    if (-not [string]::IsNullOrEmpty($envVault)) { $Vault = $envVault }
}

$selfDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$scriptsDir = $selfDir
$envScripts = [Environment]::GetEnvironmentVariable('CLOSEOUT_GATE_SCRIPTS_DIR')
if (-not [string]::IsNullOrEmpty($envScripts)) { $scriptsDir = $envScripts }

# The check set, in closeout.md §6 order. ONE declaration consumed by both -List
# and the runner, so the two can never disagree about what the gate is.
$checks = @(
    [ordered]@{ name = 'injection-scan'; script = 'check-memory-drift.ps1';  mode = '-InjectionScan'; bashMode = '--injection-scan' },
    [ordered]@{ name = 'wikilinks';      script = 'check-wikilinks.ps1';     mode = '-Draft';         bashMode = '--draft' },
    [ordered]@{ name = 'machine-paths';  script = 'check-machine-paths.ps1'; mode = '-Draft';         bashMode = '--draft' }
)

# Get-GateSkipReason — a named reason when the check's TARGET SURFACE is absent
# (an inapplicable check), else ''. Absence of the SCRIPT, and a CONFIGURED-but-
# broken surface, are different, failing cases.
function Get-GateSkipReason {
    param([string]$Name)
    if ($Name -eq 'wikilinks') {
        if ([string]::IsNullOrEmpty($Vault)) {
            return 'no vault configured (--vault / $OBSIDIAN_VAULT_PATH unset) — no wikilink target surface to resolve against'
        }
    }
    return ''
}

# Get-GateSurfaceFailReason — a named reason when the check's TARGET SURFACE is
# CONFIGURED but broken. A FAILURE, not a skip: a misspelled or unsynced vault
# path must block the durable write, not wave it through.
function Get-GateSurfaceFailReason {
    param([string]$Name)
    if ($Name -eq 'wikilinks') {
        if ((-not [string]::IsNullOrEmpty($Vault)) -and
            (-not (Test-Path -LiteralPath $Vault -PathType Container))) {
            return "configured vault does not exist: $Vault"
        }
    }
    return ''
}

if ($List.IsPresent) {
    Write-Host 'closeout-gate: pre-write checks (fail closed; a missing gate script FAILS, an inapplicable surface SKIPs)'
    foreach ($c in $checks) {
        # Script existence FIRST, broken surface SECOND, absent surface THIRD —
        # see the PRECEDENCE note in .DESCRIPTION.
        $reason = Get-GateSkipReason -Name $c.name
        $badSurface = Get-GateSurfaceFailReason -Name $c.name
        $path = Join-Path $scriptsDir $c.script
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Host ('- {0,-14} FAIL  gate script missing: {1}' -f $c.name, $path)
        } elseif ($badSurface -ne '') {
            Write-Host ('- {0,-14} FAIL  {1}' -f $c.name, $badSurface)
        } elseif ($reason -ne '') {
            Write-Host ('- {0,-14} SKIP  {1} {2} <draft> — {3}' -f $c.name, $c.script, $c.bashMode, $reason)
        } else {
            Write-Host ('- {0,-14} RUN   {1} {2} <draft>' -f $c.name, $c.script, $c.bashMode)
        }
    }
    exit 0
}

if ([string]::IsNullOrEmpty($Draft)) {
    [Console]::Error.WriteLine('FAIL no --draft given (use --list to see the check set)'); exit 2
}
if (-not (Test-Path -LiteralPath $Draft -PathType Leaf)) {
    [Console]::Error.WriteLine("FAIL draft not found or not a regular file: $Draft"); exit 2
}
try { [void][System.IO.File]::ReadAllBytes($Draft) } catch {
    [Console]::Error.WriteLine("FAIL draft is not readable: $Draft"); exit 2
}

$passed = 0
$skippedN = 0
$failedN = 0
$failedNames = @()

foreach ($c in $checks) {
    # SCRIPT EXISTENCE FIRST, surface applicability second (.DESCRIPTION
    # PRECEDENCE note). Reversing these lets a missing wikilink gate hide behind
    # "no vault configured" and the whole gate still PASS — fail-open.
    $path = Join-Path $scriptsDir $c.script
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        # FAIL CLOSED: an absent gate has proven nothing.
        Write-Host ('FAIL {0,-14} gate script missing: {1}' -f $c.name, $path)
        $failedN++
        $failedNames += $c.name
        continue
    }

    # A CONFIGURED but broken surface fails: the durable write this gates would
    # land at a path the operator never inspected.
    $badSurface = Get-GateSurfaceFailReason -Name $c.name
    if ($badSurface -ne '') {
        Write-Host ('FAIL {0,-14} {1}' -f $c.name, $badSurface)
        $failedN++
        $failedNames += $c.name
        continue
    }

    $reason = Get-GateSkipReason -Name $c.name
    if ($reason -ne '') {
        Write-Host ('SKIP {0,-14} {1}' -f $c.name, $reason)
        $skippedN++
        continue
    }

    $callArgs = @($c.mode, $Draft)
    if ($c.name -eq 'wikilinks') { $callArgs += @('-Vault', $Vault) }
    $out = (& pwsh -NoProfile -File $path @callArgs 2>&1 | Out-String)
    $rc = $LASTEXITCODE

    if ($rc -eq 0) {
        Write-Host ('PASS {0,-14} {1} {2}' -f $c.name, $c.script, $c.bashMode)
        $passed++
    } else {
        Write-Host ('FAIL {0,-14} {1} {2} exited {3}' -f $c.name, $c.script, $c.bashMode, $rc)
        # Echo the check's own output indented, so the operator can act without
        # re-running the underlying command by hand — the manual composition this
        # wrapper replaces.
        foreach ($l in ($out -split "`r?`n")) {
            if ($l -ne '') { Write-Host ('     | ' + $l) }
        }
        $failedN++
        $failedNames += $c.name
    }
}

if ($failedN -gt 0) {
    Write-Host ('GATE FAIL — {0} check(s) failed ({1}); {2} passed, {3} skipped. Do NOT write {4} — remediate and re-run.' -f `
        $failedN, ($failedNames -join ', '), $passed, $skippedN, $Draft)
    exit 1
}

Write-Host ('GATE PASS — {0} check(s) passed, {1} skipped. Safe to write {2}.' -f $passed, $skippedN, $Draft)
exit 0
