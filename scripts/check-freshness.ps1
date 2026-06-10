#Requires -Version 7
<#
.SYNOPSIS
    PowerShell twin of check-freshness.sh — install-vs-source freshness signal.

.DESCRIPTION
    Windows-native port of scripts/check-freshness.sh.

    check-drift answers "has an installed GENERATED file been hand-edited since
    install?" (tamper detection vs the install's own build-time manifest; never
    reads the repo). This script answers the ORTHOGONAL question: "has a SOURCE
    file changed in the repo since this install was rendered?" — i.e. is the
    operator's installed config built from STALE sources and in need of an
    install re-render? A hook/capability fix can merge to main and then sit
    silently un-activated on the operator's machine because install was never
    re-run; check-drift passes the whole time. This is the missing freshness
    signal.

    Mechanism: the manifest's `.sources{}` map records a SHA256 of every source
    file AT INSTALL TIME. We re-hash each in the current repo and compare. Any
    mismatch — or a source file removed / renamed since install — means stale.

    SOFT signal, never a gate. Deliberately NOT part of `make verify` (CI has no
    install; a dev machine that hasn't re-installed is not a repo defect). The
    SessionStart framework-surface hook runs it and surfaces a one-line nudge.

.PARAMETER Manifest
    Directory containing .build-manifest.json — the install (e.g.
    $CLAUDE_CONFIG_DIR or $CODEX_HOME). REQUIRED.

.PARAMETER Repo
    The agentic-os-template source checkout to hash against. Defaults to this script's own
    repo root (scripts/..), the checkout the install was rendered from.

.PARAMETER List
    Machine mode: print ONLY the stale source paths, one per line (nothing when
    fresh). Default mode prints a human-readable PASS / STALE / SKIP summary.

.NOTES
    Exit codes (BOTH modes), parity with the bash twin:
      0  fresh  — every manifest source matches the repo
      1  stale  — at least one source changed / was removed since install
      2  skip   — could not determine (no manifest / no sources map / repo
                  missing). Callers treat exit 2 as "say nothing".

    POSIX-style --manifest / --repo / --list flags pass through $Rest so
    bash-trained operators get muscle-memory parity with check-freshness.sh.
    Mirrors check-drift.ps1's parser.

    Per [[reference_stat_bsd_vs_gnu]]: hashing uses Get-FileHash (.NET SHA256),
    platform-portable; lowercased to match the bash twin's hex casing and the
    manifest's recorded (lowercase) hashes.

    Per [[feedback_powershell_set_content_crlf]]: output goes to the success /
    error streams (not Set-Content), so no CRLF/BOM byte-significance concern.
#>

[CmdletBinding()]
param(
    [string]$Manifest = '',
    [string]$Repo = '',
    [switch]$List,
    [Alias('h')][switch]$Help,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$global:LASTEXITCODE = 0

# POSIX-style flag pass-through (mirror the bash twin's `while [ $# -gt 0 ]`).
$i = 0
while ($i -lt $Rest.Count) {
    $arg = $Rest[$i]
    switch -CaseSensitive ($arg) {
        '--manifest' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('check-freshness: --manifest needs a target directory')
                exit 2
            }
            $Manifest = $Rest[$i + 1]; $i += 2
        }
        '--repo' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('check-freshness: --repo needs a directory')
                exit 2
            }
            $Repo = $Rest[$i + 1]; $i += 2
        }
        '--list' { $List = [switch]$true; $i += 1 }
        default {
            [Console]::Error.WriteLine("check-freshness: unknown argument: $arg")
            exit 2
        }
    }
}

# skip <reason> — emit the reason (human mode only) and exit 2 (indeterminate).
function Skip-Fresh([string]$reason) {
    if (-not $List) { [Console]::Error.WriteLine("SKIP $reason") }
    exit 2
}

# Source repo: explicit -Repo / --repo wins; else derive from this script's
# location. scripts/check-freshness.ps1 → scripts/.. = the agentic-os-template checkout.
if ($Repo) {
    $repoRoot = $Repo
} else {
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..') -ErrorAction SilentlyContinue).Path
}

if (-not $Manifest) { Skip-Fresh 'no --manifest <install-dir> given' }
$manifestPath = Join-Path $Manifest '.build-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Skip-Fresh "no .build-manifest.json in $Manifest"
}
if (-not $repoRoot -or -not (Test-Path -LiteralPath $repoRoot -PathType Container)) {
    $shown = if ($repoRoot) { $repoRoot } else { '<unresolved>' }
    Skip-Fresh "source repo not found: $shown"
}

try {
    $manifestObj = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
} catch {
    Skip-Fresh 'manifest is not valid JSON'
}
if (-not ($manifestObj.PSObject.Properties.Name -contains 'sources') -or
    $null -eq $manifestObj.sources -or
    $manifestObj.sources -isnot [pscustomobject]) {
    Skip-Fresh 'manifest has no sources map'
}

$sources = $manifestObj.sources.PSObject.Properties
$total = @($sources).Count

# Compare each recorded source hash against the current repo file. A removed /
# renamed source counts as stale (the install was rendered from a tree that no
# longer matches the repo). Get-FileHash returns UPPERCASE hex; lowercase to
# match the bash twin + the manifest's recorded hashes.
$stale = [System.Collections.Generic.List[string]]::new()
foreach ($p in $sources) {
    $rel = $p.Name
    $want = $p.Value
    if (-not $rel) { continue }
    $src = Join-Path $repoRoot $rel
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        $stale.Add($rel); continue
    }
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $src).Hash.ToLower()
    if ($got -ne $want) {
        $stale.Add($rel)
    }
}

$n = $stale.Count
if ($n -eq 0) {
    if (-not $List) {
        [Console]::Out.WriteLine("PASS install is current ($total source files match)")
    }
    exit 0
}

if ($List) {
    foreach ($s in $stale) { [Console]::Out.WriteLine($s) }
} else {
    [Console]::Out.WriteLine("STALE $n of $total source file(s) changed since install — re-run scripts/install.sh:")
    foreach ($s in $stale) { [Console]::Out.WriteLine("  $s") }
}
exit 1
