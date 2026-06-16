#Requires -Version 7
<#
.SYNOPSIS
    PowerShell port of check-wikilinks.sh — pre-drain wikilink validator for the
    closeout session-log drain. Fails CLOSED on any [[wikilink]] that does not
    resolve against the vault, BEFORE the drain writes the draft.

.DESCRIPTION
    The closeout drain composes a session-log body and writes it to
    30-Archive/Sessions/. It runs the vault audit BEFORE writing its own log, so
    the log's own links are not validated until the NEXT audit — the window a
    bare-basename subfolder link once slipped through (<TEAM>-290). This check closes
    that window: it resolves the drafted body's wikilinks at write time, the SAME
    way the vault audit's checkWikilinks (bin/memory-vault-audit.js) does, and
    blocks the write on any miss.

    RESOLUTION RULE — mirrors checkWikilinks EXACTLY (that resolver lives in the
    operator's vault, not this repo, so the harness-neutral framework cannot
    import it; this is a pinned mirror kept honest by tests/wikilinks.test.ps1):
    build a target set of every vault *.md/*.base note's vault-relative path
    (forward slashes) AND that path with the .md/.base extension stripped (skip
    .git node_modules .venv .claude .agents .codex). A target — the wikilink text
    up to the first `|` (alias) or `#` (heading), trimmed — resolves iff the set
    contains it, OR it + ".md", OR it + ".base". A full vault-relative path (±ext)
    resolves; a BARE name resolves only for a vault-ROOT note, never a subdirectory
    note by basename.

    Backticked memory-store names (project_*/feedback_*/reference_*) carry no
    [[ ]], so the extractor never sees them — no false positives. A memory-store
    name wrongly written as [[project_x]] correctly fails (it is not a vault note).

    Windows-native twin of scripts/check-wikilinks.sh — same flags, same exit
    codes, same output classes after the bash<->pwsh byte-parity normalization.

.PARAMETER Draft
    Path to the drafted session-log file whose wikilinks are validated. Required.

.PARAMETER Vault
    Path to the vault root to resolve against. If omitted, derived from
    $env:OBSIDIAN_VAULT_PATH.

.OUTPUTS
    PASS/FAIL lines matching the bash twin's emit shape.

.NOTES
    Exit codes:
        0 — every wikilink resolves (or the draft has none)
        1 — one or more wikilinks do not resolve (FAIL CLOSED — do not write)
        2 — usage error (missing/unreadable draft, missing/unresolvable vault, bad args)
#>

[CmdletBinding()]
param(
    [string]$Draft = '',
    [string]$Vault = '',
    [Alias('h')][switch]$Help,

    # POSIX-style --draft / --vault / --help so bash-trained operators get
    # muscle-memory parity with the .sh twin (mirrors check-distillation-completeness.ps1).
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
        '--vault' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('FAIL --vault requires a value'); exit 2
            }
            $Vault = $Rest[$i + 1]; $i += 2
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
check-wikilinks.ps1 — pre-drain wikilink validator (fail closed) for the closeout
session-log drain.

Usage:
  check-wikilinks.ps1 -Draft <path> [-Vault <path>]
  check-wikilinks.ps1 -Draft <path>      (derives Vault from OBSIDIAN_VAULT_PATH)
  check-wikilinks.ps1 -Help

Exit codes:
  0 — every wikilink in the draft resolves (or the draft has none)
  1 — one or more wikilinks do not resolve (FAIL CLOSED — do not write the draft)
  2 — usage error (missing/unreadable draft, missing/unresolvable vault, bad args)
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
# Mirror bash `[ -r ]`: an existing-but-unreadable draft must FAIL with exit 2, not
# throw a raw exception under $ErrorActionPreference='Stop' (which would break the
# documented output class + bash/PS parity). Probe with a real read.
try {
    $probe = [System.IO.File]::OpenRead($Draft); $probe.Close()
} catch {
    [Console]::Error.WriteLine("FAIL draft file not readable: $Draft"); exit 2
}

# Resolve the vault — explicit flag, else OBSIDIAN_VAULT_PATH. Strip trailing slash.
if ([string]::IsNullOrEmpty($Vault)) {
    $Vault = $env:OBSIDIAN_VAULT_PATH
    if ([string]::IsNullOrEmpty($Vault)) {
        [Console]::Error.WriteLine('FAIL no --vault given and OBSIDIAN_VAULT_PATH unset'); exit 2
    }
}
$Vault = $Vault.TrimEnd('/', '\')
if (-not (Test-Path -LiteralPath $Vault -PathType Container)) {
    [Console]::Error.WriteLine("FAIL vault dir does not exist: $Vault"); exit 2
}

# Build the target set, mirroring checkWikilinks: every *.md/*.base note's
# vault-relative path (forward slashes) AND its single-extension-stripped form.
# Enumerate then filter out the skip dirs by path segment (the audit prunes them
# during walk; filtering after gives the identical file SET). Ordinal HashSet =
# case-sensitive membership, matching the JS Set and bash `grep -Fxq`/`LC_ALL=C`.
$skip = @('.git', 'node_modules', '.venv', '.claude', '.agents', '.codex')
$targets = [System.Collections.Generic.HashSet[string]]::new()
$noextPaths = [System.Collections.Generic.List[string]]::new()
$vaultPrefix = $Vault + [System.IO.Path]::DirectorySeparatorChar
Get-ChildItem -LiteralPath $Vault -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -eq '.md' -or $_.Extension -eq '.base' } |
    ForEach-Object {
        $rel = $_.FullName
        if ($rel.StartsWith($vaultPrefix)) { $rel = $rel.Substring($vaultPrefix.Length) }
        $rel = $rel.Replace('\', '/')
        $segs = $rel.Split('/')
        foreach ($s in $segs) { if ($skip -contains $s) { return } }
        [void]$targets.Add($rel)
        if ($rel -clike '*.md') { $noext = $rel.Substring(0, $rel.Length - 3) }
        elseif ($rel -clike '*.base') { $noext = $rel.Substring(0, $rel.Length - 5) }
        else { $noext = $rel }
        [void]$targets.Add($noext)
        $noextPaths.Add($noext)
    }

function Test-Resolves {
    param([string]$T)
    return ($targets.Contains($T) -or $targets.Contains("$T.md") -or $targets.Contains("$T.base"))
}

# Suggest-FullPath <target> — if exactly one vault note has basename == target,
# return its extension-stripped full vault-relative path. Silent on 0 / multiple.
function Suggest-FullPath {
    param([string]$T)
    $matches = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $noextPaths) {
        $base = $p.Substring($p.LastIndexOf('/') + 1)
        if ($base -ceq $T) { if (-not $matches.Contains($p)) { $matches.Add($p) } }
    }
    if ($matches.Count -eq 1) { return $matches[0] }
    return ''
}

# Extract distinct wikilink targets. Read LINE BY LINE (matching grep's line-based
# extraction — a wikilink cannot span a newline in either twin). Per line, find
# every [[...]] (inner has no `]`), cut alias `|` / heading `#`, trim.
$rx = [regex]'\[\[[^\]]+\]\]'
$distinctSet = [System.Collections.Generic.HashSet[string]]::new()
foreach ($line in [System.IO.File]::ReadAllLines($Draft)) {
    foreach ($m in $rx.Matches($line)) {
        $inner = $m.Value.Substring(2, $m.Value.Length - 4)
        $t = $inner.Split('|')[0].Split('#')[0].Trim()
        # Keep an empty target verbatim — no display sentinel (it could collide
        # with a real note named "(empty)" and diverge from the reference). "" is
        # carried through resolution (matches no note → fails closed) and rendered
        # as "(empty)" only at print time.
        [void]$distinctSet.Add($t)
    }
}
$distinct = @($distinctSet) | Sort-Object -CaseSensitive
$total = $distinct.Count

# Report DISTINCT unresolved targets, not one per occurrence as the reference's
# broken[] does — the pass/fail VERDICT is identical (the gate blocks iff ANY
# target is unresolved); only the repeat-count of an identical link differs.
$unresolved = [System.Collections.Generic.List[string]]::new()
foreach ($t in $distinct) {
    if (-not (Test-Resolves $t)) { $unresolved.Add($t) }
}

if ($unresolved.Count -gt 0) {
    foreach ($t in $unresolved) {
        $disp = if ($t -eq '') { '(empty)' } else { $t }
        [Console]::Error.WriteLine("FAIL unresolved wikilink: $Draft -> $disp")
        if ($t -ne '') {
            $sugg = Suggest-FullPath $t
            if ($sugg -ne '') {
                [Console]::Error.WriteLine("       did you mean the full path: [[$sugg]] ?")
            }
        }
    }
    [Console]::Error.WriteLine("FAIL $($unresolved.Count) of $total wikilink target(s) unresolved in $Draft — fix to full vault-relative paths before the drain writes (capabilities/closeout.md → Full-path wikilinks)")
    exit 1
}

Write-Host "PASS all $total wikilink target(s) resolve against vault: $Draft"
exit 0
