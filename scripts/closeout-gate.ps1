#Requires -Version 7
<#
.SYNOPSIS
    closeout-gate.ps1 — ONE fail-closed wrapper for the deterministic pre-write
    checks a closeout composes by hand before it writes a drafted durable
    artifact (a session log, a distilled lesson note) into the vault.
    PowerShell twin of scripts/closeout-gate.sh.

.DESCRIPTION
    WHY THIS EXISTS. capabilities/closeout.md states the pre-write contract in
    prose — the injection scan, the wikilink check, the machine-path scan, and
    the project-note budget must ALL pass (fail closed). Composing four separate
    commands by hand at write time is where one silently gets
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
                      Vault resolution precedence: -Vault flag, then
                      $env:OBSIDIAN_VAULT_PATH, then OBSIDIAN_VAULT_PATH read
                      from repo-root local.env as DATA (never imported) — the
                      same last-resort chain check-drift.ps1 -Auto uses for
                      render homes. Agent shells do not inherit local.env, so
                      without the file fallback the check silently SKIPped
                      every closeout on a machine whose vault IS configured.
      machine-paths   check-machine-paths.ps1 -Draft <draft>
                      No machine-specific absolute home path in the durable file.
      project-note-budget
                      check-project-note-budget.ps1 -MemoryDir <dir>
                      No `type: project` memory note over the per-note body
                      budget (PROJECT_NOTE_BODY_WARN_KB, default 16 KB).
                      Closeout is where project notes GROW, so it is where the
                      budget must bite — the self-audit's after-the-fact warn
                      arrives a session too late. Needs a memory store, and
                      follows the SAME surface contract as the wikilink check:
                      NONE configured is a NAMED SKIP, a CONFIGURED-but-missing
                      dir is a FAILURE. Resolution precedence: -MemoryDir flag,
                      then $env:CLAUDE_PRIMARY_MEMORY_DIR, then
                      CLAUDE_PRIMARY_MEMORY_DIR read from repo-root local.env
                      as DATA.

    FAIL-CLOSED CONTRACT, stated precisely because the two non-pass outcomes are
    easy to conflate:
      - A check that RUNS and reports a finding  -> FAIL (exit 1).
      - A check whose SCRIPT IS ABSENT           -> FAIL (exit 1). A gate that
        cannot run has proven nothing; treating it as a skip is the fail-open
        hole this wrapper exists to close.
      - A check whose TARGET SURFACE IS ABSENT   -> SKIP, named, exit unaffected.
        Two checks have such a surface — the wikilink check (the vault) and the
        project-note budget (the memory store) — and each skip is narrow:
        NOTHING configured at all (no flag, the env var unset/empty, AND no key
        in repo-root local.env).
      - A check whose surface IS CONFIGURED but BROKEN -> FAIL (exit 1), naming
        the path. A configured vault directory that does not exist is a
        misspelled or unsynced destination, not "no vault": the durable write it
        gates would land somewhere the operator never inspected.

    PRECEDENCE, and it is load-bearing, in this order:
      1. SCRIPT EXISTENCE. Evaluating anything else first would let a check
         that HAS an inapplicable surface report SKIP while its gate script is
         missing — an unrunnable gate laundered into a benign skip, and the gate
         could then PASS. Missing script wins, always.
      2. SURFACE BROKEN (a configured vault or memory dir that is absent) -> FAIL.
      3. SURFACE ABSENT (nothing configured) -> SKIP.

    -Vault defaults to $env:OBSIDIAN_VAULT_PATH, then to OBSIDIAN_VAULT_PATH
    from repo-root local.env; -MemoryDir defaults to
    $env:CLAUDE_PRIMARY_MEMORY_DIR, then to CLAUDE_PRIMARY_MEMORY_DIR from the
    same file ($env:AI_CONFIG_LOCAL_ENV overrides the file path — the same
    fixture convention as check-drift.ps1 / install). Nothing else is
    configurable: the check set IS the contract, so it is not
    caller-selectable.

    Test override: $env:CLOSEOUT_GATE_SCRIPTS_DIR points the wrapper at a fixture
    scripts/ dir (same convention as $env:SELF_AUDIT_CURRENTNESS_BIN in
    self-audit.ps1).

.PARAMETER Draft
    Path to the drafted file to gate. Required unless -List.

.PARAMETER Vault
    Vault root for the wikilink check. Defaults to $env:OBSIDIAN_VAULT_PATH.

.PARAMETER MemoryDir
    Memory store for the project-note budget check. Defaults to
    $env:CLAUDE_PRIMARY_MEMORY_DIR.

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
    [string]$MemoryDir = '',
    [switch]$List,
    [Alias('h')][switch]$Help,

    # POSIX-style --draft / --vault / --memory-dir / --list / --help so
    # bash-trained operators get muscle-memory parity with the .sh twin
    # (mirrors check-wikilinks.ps1).
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# An EXPLICIT empty value is a USAGE ERROR, never a fallback. Accepting it would
# send `-MemoryDir $someUnsetVar` down the env/local.env chain and, on a machine
# with nothing configured, out as the named SKIP: a caller that believed it
# pinned a store watches the budget check pass over nothing. $PSBoundParameters
# is what tells an explicitly-passed '' apart from the parameter default.
if ($PSBoundParameters.ContainsKey('MemoryDir') -and [string]::IsNullOrEmpty($MemoryDir)) {
    [Console]::Error.WriteLine('FAIL --memory-dir requires a non-empty value'); exit 2
}

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
        '--memory-dir' {
            if ($i + 1 -ge $Rest.Count) { [Console]::Error.WriteLine('FAIL --memory-dir requires a value'); exit 2 }
            if ([string]::IsNullOrEmpty($Rest[$i + 1])) {
                [Console]::Error.WriteLine('FAIL --memory-dir requires a non-empty value'); exit 2
            }
            $MemoryDir = $Rest[$i + 1]; $i += 2
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
if ([string]::IsNullOrEmpty($MemoryDir)) {
    $envMem = [Environment]::GetEnvironmentVariable('CLAUDE_PRIMARY_MEMORY_DIR')
    if (-not [string]::IsNullOrEmpty($envMem)) { $MemoryDir = $envMem }
}

$selfDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# Get-CgLocalEnvValue -Path -Key — read ONE KEY=VALUE from local.env as DATA,
# never imported into the process environment. Same parser as check-drift.ps1's
# Get-CdLocalEnvValue: strips an optional `export `, one matching outer quote
# pair, backslash escapes (the vault value carries spaces on real machines, in
# both the quoted and backslash-escaped spellings); last assignment wins; no
# $VAR expansion.
function Get-CgLocalEnvValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    # An unreadable (locked / access-denied) file must degrade to "no value"
    # like the bash twin's failed open — not crash the gate with an uncaught
    # exception (panel finding: ReadAllLines throws under $ErrorActionPreference
    # = 'Stop', turning a last-resort convenience read into a hard stop).
    try { $lines = [System.IO.File]::ReadAllLines($Path) } catch { return '' }
    $result = ''
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t.Length -eq 0 -or $t.StartsWith('#', [StringComparison]::Ordinal)) { continue }
        if ($t -match '^export\s+(.+)$') { $t = $matches[1] }
        if (-not $t.StartsWith("$Key=", [StringComparison]::Ordinal)) { continue }
        $v = $t.Substring($Key.Length + 1)
        if ($v.Length -ge 2) {
            $f = $v[0]; $l = $v[$v.Length - 1]
            if (($f -eq '"' -and $l -eq '"') -or ($f -eq "'" -and $l -eq "'")) {
                $v = $v.Substring(1, $v.Length - 2)
            } elseif ($v.Contains('\')) {
                $v = [regex]::Replace($v, '\\(.)', '$1')
            }
        }
        $result = $v
    }
    return $result
}

# Last-resort vault resolution: OBSIDIAN_VAULT_PATH from repo-root local.env,
# read as data (see Get-CgLocalEnvValue). Agent shells do not inherit
# local.env, so on a configured machine the env var is typically unset —
# without this the wikilink check SKIPped every closeout while the operator
# believed it ran. $env:AI_CONFIG_LOCAL_ENV points tests at a synthetic
# local.env (same convention as check-drift.ps1 -Auto); the flag and the env
# var still win.
$cgLocalEnv = if ($env:AI_CONFIG_LOCAL_ENV) { $env:AI_CONFIG_LOCAL_ENV } else { Join-Path (Split-Path -Parent $selfDir) 'local.env' }
if ([string]::IsNullOrEmpty($Vault)) {
    $Vault = Get-CgLocalEnvValue -Path $cgLocalEnv -Key 'OBSIDIAN_VAULT_PATH'
}
# Same last-resort chain for the project-note budget's memory store: the pin an
# operator records once in local.env is invisible to an agent shell, so without
# this the budget check SKIPped on exactly the machines that have a store.
if ([string]::IsNullOrEmpty($MemoryDir)) {
    $MemoryDir = Get-CgLocalEnvValue -Path $cgLocalEnv -Key 'CLAUDE_PRIMARY_MEMORY_DIR'
}
$scriptsDir = $selfDir
$envScripts = [Environment]::GetEnvironmentVariable('CLOSEOUT_GATE_SCRIPTS_DIR')
if (-not [string]::IsNullOrEmpty($envScripts)) { $scriptsDir = $envScripts }

# The check set, in the order closeout.md lists them. ONE declaration consumed by
# both -List and the runner, so the two can never disagree about what the gate
# is. `target` is what -List prints, so the preflight names the right subject per
# check (the draft for the draft-scanners, the memory store for the budget).
$checks = @(
    [ordered]@{ name = 'injection-scan'; script = 'check-memory-drift.ps1';  mode = '-InjectionScan'; bashMode = '--injection-scan'; target = '<draft>' },
    [ordered]@{ name = 'wikilinks';      script = 'check-wikilinks.ps1';     mode = '-Draft';         bashMode = '--draft';          target = '<draft>' },
    [ordered]@{ name = 'machine-paths';  script = 'check-machine-paths.ps1'; mode = '-Draft';         bashMode = '--draft';          target = '<draft>' },
    [ordered]@{ name = 'project-note-budget'; script = 'check-project-note-budget.ps1'; mode = '-MemoryDir'; bashMode = '--memory-dir'; target = '<memory dir>' }
)

# Get-GateSkipReason — a named reason when the check's TARGET SURFACE is absent
# (an inapplicable check), else ''. Absence of the SCRIPT, and a CONFIGURED-but-
# broken surface, are different, failing cases.
function Get-GateSkipReason {
    param([string]$Name)
    if ($Name -eq 'wikilinks') {
        if ([string]::IsNullOrEmpty($Vault)) {
            return 'no vault configured (--vault / $OBSIDIAN_VAULT_PATH / local.env OBSIDIAN_VAULT_PATH all unset) — no wikilink target surface to resolve against'
        }
    }
    if ($Name -eq 'project-note-budget') {
        if ([string]::IsNullOrEmpty($MemoryDir)) {
            return 'no memory dir configured (--memory-dir / $CLAUDE_PRIMARY_MEMORY_DIR / local.env CLAUDE_PRIMARY_MEMORY_DIR all unset) — no project-note surface to scan'
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
    if ($Name -eq 'project-note-budget') {
        if ((-not [string]::IsNullOrEmpty($MemoryDir)) -and
            (-not (Test-Path -LiteralPath $MemoryDir -PathType Container))) {
            return "configured memory dir does not exist: $MemoryDir"
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
            Write-Host ('- {0,-14} SKIP  {1} {2} {3} — {4}' -f $c.name, $c.script, $c.bashMode, $c.target, $reason)
        } else {
            Write-Host ('- {0,-14} RUN   {1} {2} {3}' -f $c.name, $c.script, $c.bashMode, $c.target)
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

    # The project-note budget scans the memory STORE, not the draft — its mode
    # flag's value is the resolved memory dir. Every other check takes the draft.
    if ($c.name -eq 'project-note-budget') {
        $callArgs = @($c.mode, $MemoryDir)
    } else {
        $callArgs = @($c.mode, $Draft)
        if ($c.name -eq 'wikilinks') { $callArgs += @('-Vault', $Vault) }
    }
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
