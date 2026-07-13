#Requires -Version 7
<#
.SYNOPSIS
    PowerShell port of check-machine-paths.sh — pre-drain machine-path scanner
    for the closeout session-log drain. Fails CLOSED on any machine-specific
    absolute home path (/Users/<name>/…, /home/<name>/…, C:\Users\<name>\…),
    BEFORE the drain writes the draft to the vault.

.DESCRIPTION
    The closeout drain composes a session-log body and writes it to
    30-Archive/Sessions/. It runs the vault audit BEFORE writing its own log, so
    the log's own body is not machine-path-scanned until the NEXT audit — the
    window a drafted log carrying a /Users/<name>/… path can slip into the
    cloud-synced vault. This check closes that window: it scans the drafted body
    at write time, the SAME way the vault audit's checkAgnostic
    (bin/memory-vault-audit.js) does, and blocks the write on any offending line.
    There is NO raw-evidence exemption — the whole file is scanned line-by-line.

    MATCH RULE — mirrors checkAgnostic's `machinePath` regex (that resolver
    lives in the operator's vault scaffolding; this is a pinned mirror kept
    honest by tests/machine-paths.test.ps1). Two refinements over a bare
    substring match: (1) require a real username segment after the home root, so
    a lone "Users"/"home" token in prose does not trip; (2) tell a filesystem
    path apart from a URL path — a URL path segment is preceded by an alphanumeric
    host char (or a dot, e.g. .com), a real absolute path begins at a boundary,
    so a home path is flagged only when NOT preceded by a URL host char. The
    Windows arm requires a real user-folder segment, not a bare drive-colon-slash.

    The regex reuses the JS `machinePath` source text — .NET's engine supports
    (?:…) and \s, so no structural translation is needed on the PS side (the
    bash twin rewrites \s to [:space:] for POSIX ERE). The engines are NOT
    bit-identical on whitespace: JS \s, .NET \s, and POSIX [[:space:]] disagree
    on exotic Unicode whitespace (e.g. U+0085 NEL, U+FEFF). The contract is
    ASCII-whitespace scope — real home paths are ASCII-shaped, so the divergence
    is an accepted trade-off, not a parity bug.

    Windows-native twin of scripts/check-machine-paths.sh — same flags, same exit
    codes, same output classes after the bash<->pwsh byte-parity normalization.

.PARAMETER Draft
    Path to the drafted session-log file to scan. Required.

.OUTPUTS
    PASS/FAIL lines matching the bash twin's emit shape.

.NOTES
    Exit codes:
        0 — no machine-specific absolute path in the draft
        1 — one or more offending lines (FAIL CLOSED — do not write)
        2 — usage error (missing/unreadable draft, bad args)
#>

[CmdletBinding()]
param(
    [string]$Draft = '',
    [Alias('h')][switch]$Help,

    # POSIX-style --draft / --help so bash-trained operators get muscle-memory
    # parity with the .sh twin (mirrors check-wikilinks.ps1).
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# POSIX-style flag passthrough via $Rest (mirror the bash `while [ $# -gt 0 ]` loop).
$i = 0
while ($i -lt $Rest.Count) {
    $arg = $Rest[$i]
    switch -CaseSensitive ($arg) {
        '--draft' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('FAIL --draft requires a value'); exit 2
            }
            $Draft = $Rest[$i + 1]; $i += 2
        }
        '-h'     { $Help = [switch]$true; $i += 1 }
        '--help' { $Help = [switch]$true; $i += 1 }
        default {
            [Console]::Error.WriteLine("FAIL unknown arg: $arg"); exit 2
        }
    }
}

function Write-Usage {
    @'
check-machine-paths.ps1 — pre-drain machine-path scanner (fail closed) for the
closeout session-log drain.

Usage:
  check-machine-paths.ps1 -Draft <path>
  check-machine-paths.ps1 -Help

Exit codes:
  0 — no machine-specific absolute path in the draft
  1 — one or more offending lines (FAIL CLOSED — do not write the draft)
  2 — usage error (missing/unreadable draft, bad args)
'@ | Write-Host
}

if ($Help.IsPresent) { Write-Usage; exit 0 }

# Draft is required and must be a readable file.
if ([string]::IsNullOrEmpty($Draft)) {
    [Console]::Error.WriteLine('FAIL no --draft given'); exit 2
}
if (-not (Test-Path -LiteralPath $Draft -PathType Leaf)) {
    [Console]::Error.WriteLine("FAIL draft file does not exist: $Draft"); exit 2
}
# Canonicalize BEFORE any .NET file API touches the path: .NET (OpenRead /
# ReadAllLines) resolves a relative path against the PROCESS working directory,
# which Set-Location does NOT move — so a valid relative -Draft passed from a
# PowerShell location that differs from the process CWD would false-block as
# "not readable" (exit 2). Resolve-Path resolves against the PowerShell location,
# i.e. the same base Test-Path just validated against. The resolved path feeds
# the .NET calls only; $Draft stays as given for output (byte-parity with the
# bash twin, which echoes the caller's path). Pinned by the relative-path case
# in tests/machine-paths.test.ps1.
$DraftResolved = (Resolve-Path -LiteralPath $Draft).ProviderPath
# Mirror bash `[ -r ]`: an existing-but-unreadable draft must FAIL with exit 2, not
# throw under $ErrorActionPreference='Stop'. Probe with a real read.
try {
    $probe = [System.IO.File]::OpenRead($DraftResolved); $probe.Close()
} catch {
    [Console]::Error.WriteLine("FAIL draft file not readable: $Draft"); exit 2
}

# The machine-path pattern — the JS `machinePath` source text reused. .NET
# supports (?:…) and \s, so no structural rewrite is needed here (the bash twin
# rewrites \s → [:space:]); the whitespace class is ASCII-scoped by contract
# (see .DESCRIPTION). Case-sensitive by default, matching checkAgnostic.
$rx = [regex]'(?:^|[^A-Za-z0-9.])/(?:Users|home)/[^/\s]+|[A-Za-z]:\\Users\\[^\\\s]+'

# Scan every line with a hand-kept counter so the offender report reads
# `<file>:<line>`. ReadAllLines splits on CR/LF; a final newline-less line is
# still returned, matching the bash `|| [ -n "$line" ]` tail.
$offenders = 0
$lineno = 0
foreach ($line in [System.IO.File]::ReadAllLines($DraftResolved)) {
    $lineno++
    if ($rx.IsMatch($line)) {
        [Console]::Error.WriteLine("FAIL machine-specific absolute path (keep the session log agnostic): ${Draft}:${lineno}")
        $offenders++
    }
}

if ($offenders -gt 0) {
    [Console]::Error.WriteLine("FAIL $offenders offending line(s) with a machine-specific absolute path in $Draft — replace each with an agnostic reference (a repo-relative, home-relative, or vault-relative path) before the drain writes")
    exit 1
}

Write-Host "PASS no machine-specific absolute paths in $Draft"
exit 0
