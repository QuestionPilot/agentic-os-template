#Requires -Version 7
<#
.SYNOPSIS
    recall-report.ps1 — read-only, deterministic ROLLING COUNT of recorded
    recall failures across the latest N meaningful session logs.
    PowerShell twin of scripts/recall-report.sh.

.DESCRIPTION
    WHY THIS EXISTS. capabilities/closeout.md's Q1a asks every closeout to
    record whether a rule that WAS available at orient failed to fire, and to
    classify the miss. Those records accumulate in the durable session logs and
    are then never read: nobody can say whether recall is getting better or
    worse, so "the memory system works" is an assertion, not an observation.
    This script turns the already-written records into a number.

    WHAT IT IS NOT. This is INFORMATIONAL. It is a rolling COUNT and a rolling
    RATE, not a score, a grade, a threshold, or a gate. There is deliberately no
    pass/fail verdict and no target number: the sample is small, the denominator
    is a proxy, and a metric that grades the operator's own honesty about their
    misses is a metric that stops being recorded honestly. Exit status reports
    whether the REPORT could be produced — never whether the number is "good".

    THE "MEANINGFUL SESSION LOG" MARKER, and why this one.
      Marker: a line that is exactly `## Issues this session`.
    The denominator has to be "sessions that ran a real closeout", because only
    a real closeout writes a Q1a record at all — counting every file in the
    archive would silently deflate the rate with logs that never had the
    opportunity to record a miss. Two markers were candidates, both from the
    session-summary template (`80-Templates/session-summary.md` in the vault):
      `## TL;DR`              — present in essentially every file, including
                                thin or aborted logs. Too permissive: it selects
                                "a file exists", not "a closeout ran".
      `## Issues this session` — the template's work-content section. CHOSEN.
    On the corpus this was calibrated against, the two markers differed by five
    files, and every file the stricter marker excluded was a hand-shaped log
    that had dropped the template's section structure. The stricter marker is
    also the more stable string: `TL;DR` is generic prose that could plausibly
    appear as a heading in a non-session note dropped into the same folder,
    while `## Issues this session` is template-specific.
    HONEST LIMITATION: this therefore measures TEMPLATE-CONFORMANT closeout
    logs, not "meaningful sessions" in some deeper sense. A closeout that used a
    different heading is invisible to the denominator AND to the numerator, so
    it cannot skew the rate in either direction — but it does shrink the sample.

    THE EXTRACTION CONTRACT, biased hard toward UNDER-reporting.
    A recall-failure RECORD is a line that begins with the bold record marker:

        **Recall failure, class not-loaded:** <prose>
        **Recall failure, class loaded-but-ignored:** <prose>

    Only `^\*\*Recall failure` at the start of a line is a record at all. Prose
    ABOUT recall failures is not a record, and the corpus is full of prose that
    a looser scanner reads as one — negations ("Recall failure: none"),
    bulleted older formats, reversed word order, parenthetical classes,
    headings, and a bare class token used as a noun mid-sentence. Every one of
    those shapes is pinned as a restraint fixture in
    tests/recall-report.test.ps1. The cost of the strictness is real (older
    bulleted records are NOT counted, so early windows under-report); the cost
    of the alternative is a number nobody trusts.

    A record whose class token is not one of the two known classes is NOT
    guessed at. It lands in a separate `unclassified` informational count, so a
    typo or a newly-invented class is visible as "something was recorded here
    that this scanner does not understand" rather than being silently binned
    into a class it may not belong to, or silently dropped.

    ORDERING. Session-log filenames are `YYYY-MM-DD-HHMMSS-<host>-<id>.md`, so
    an ORDINAL (byte-wise) lexicographic sort IS chronological order. The window
    is the LAST N of that sort. No mtime is consulted: a vault that syncs
    through cloud storage rewrites mtimes on files whose content never changed.
    The sort is [StringComparer]::Ordinal — the PS equivalent of the bash twin's
    LC_ALL=C sort. A culture-aware sort would reorder differently on some hosts.

.PARAMETER SessionsDir
    Directory of session logs to scan. Default: <vault>/30-Archive/Sessions,
    where <vault> is $env:OBSIDIAN_VAULT_PATH, falling back to the repo-root
    local.env OBSIDIAN_VAULT_PATH key.
    RESOLUTION ORDER: parameter > ambient env > local.env. (Documented
    divergence: self-audit's house order puts local.env ahead of ambient env.
    Here the ambient env wins, because this script is expected to be run ad hoc
    against a chosen vault by setting the variable, and a stale local.env
    silently overriding that is the surprising outcome. The parameter beats
    both.)

.PARAMETER Window
    How many of the newest meaningful logs to scan (default 20). Positive int.

.PARAMETER List
    Machine mode: tab-separated records, for self-audit.

.PARAMETER Isolated
    No ambient-env / local.env fallbacks (tests).

.NOTES
    -List record shape (tab-separated, stable field order):
      counts<TAB>window<TAB>considered<TAB>meaningful_total<TAB>scanned<TAB>not_loaded<TAB>loaded_but_ignored<TAB>unclassified
      record<TAB>class<TAB>file:line
    Exactly one `counts` record is emitted, first, whenever a report was
    produced. Its ABSENCE (with exit 0) is how a caller detects a named skip.

    Exit codes:
      0  report produced, OR a NAMED skip (reason on stderr as `SKIP <reason>`,
         and in human mode also on stdout). A skip is never a silent zero-count
         report: the counts block is omitted entirely rather than printed as
         zeros. Skips: no sessions dir configured at all; zero meaningful logs.
      2  usage error (bad flag, bad -Window) or SCAN error (fail closed, loud).
         A scan error is a CONFIGURED sessions dir that does not exist or cannot
         be read — a misspelled or unsynced path, whose zero-count report would
         be indistinguishable from a genuinely clean window.
         DOCUMENTED TWIN DIVERGENCE: a value-less `--window` or `--sessions-dir`
         is claimed by PowerShell's parameter binder BEFORE the script body can
         run (one leading `-` is stripped and the rest prefix-matches a declared
         parameter), so the refusal is the binder's own non-zero exit (observed
         1), not this script's 2. Still loud, still non-zero — the property that
         matters; tests/recall-report.test.ps1 asserts the non-zero refusal.

    Read-only: this script never writes, moves, or edits anything it scans.

    Tests: tests/recall-report.test.ps1 (+ the .sh twin).
#>

[CmdletBinding()]
param(
    [string]$SessionsDir = '',
    [string]$Window = '20',
    [switch]$List,
    [switch]$Isolated,
    [Alias('h')][switch]$Help,

    # POSIX-style --sessions-dir / --window / --list / --isolated / --help so
    # bash-trained operators get muscle-memory parity with the .sh twin
    # (mirrors closeout-gate.ps1 / check-wikilinks.ps1).
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$i = 0
while ($i -lt $Rest.Count) {
    $arg = $Rest[$i]
    switch -CaseSensitive ($arg) {
        '--sessions-dir' {
            if ($i + 1 -ge $Rest.Count) { [Console]::Error.WriteLine('recall-report: --sessions-dir needs a path'); exit 2 }
            $SessionsDir = $Rest[$i + 1]; $i += 2
        }
        '--window' {
            if ($i + 1 -ge $Rest.Count) { [Console]::Error.WriteLine('recall-report: --window needs a value'); exit 2 }
            $Window = $Rest[$i + 1]; $i += 2
        }
        '--list'     { $List = [switch]$true; $i += 1 }
        '--isolated' { $Isolated = [switch]$true; $i += 1 }
        '-h'         { $Help = [switch]$true; $i += 1 }
        '--help'     { $Help = [switch]$true; $i += 1 }
        default      { [Console]::Error.WriteLine("recall-report: unknown arg: $arg"); exit 2 }
    }
}

if ($Help.IsPresent) {
    Get-Help -Full $PSCommandPath | Out-String | Write-Host
    exit 0
}

# --Window validation mirrors the bash twin exactly: digits only, and > 0.
if ($Window -notmatch '^[0-9]+$') {
    [Console]::Error.WriteLine("recall-report: --window must be a positive integer, got: $Window"); exit 2
}
$WindowN = [int]$Window
if ($WindowN -le 0) {
    [Console]::Error.WriteLine("recall-report: --window must be a positive integer, got: $Window"); exit 2
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$repoRoot = Split-Path -Parent $scriptDir

$SESSIONS_REL = '30-Archive/Sessions'
# Line-anchored, exact heading (trailing whitespace tolerated).
$MEANINGFUL_RE = '^##[ ]Issues this session[ \t]*$'
# ONLY a line starting with this is a recall-failure record.
$RECORD_RE = '^\*\*Recall failure'

# Get-RrLocalEnvValue — read ONE key from local.env as DATA, without importing
# the whole file. Byte-parity with self-audit.ps1's Get-SaLocalEnvValue and with
# the bash twin's _rr_localenv_get: importing would push EVERY key (incl. a
# hostile PATH=) into the process env.
function Get-RrLocalEnvValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $pat = '^(?:export\s+)?' + [regex]::Escape($Key) + '=(.*)$'
    $result = ''
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $t = $line.Trim()
        if ($t.Length -eq 0 -or $t.StartsWith('#', [StringComparison]::Ordinal)) { continue }
        if ($t -match $pat) {
            $v = $matches[1]
            if ($v.Length -ge 2) {
                $f = $v[0]; $l = $v[$v.Length - 1]
                if (($f -ceq '"' -and $l -ceq '"') -or ($f -ceq "'" -and $l -ceq "'")) {
                    $v = $v.Substring(1, $v.Length - 2)
                } elseif ($v.Contains([char]'\')) {
                    $v = [System.Text.RegularExpressions.Regex]::Replace($v, '\\(.)', '$1')
                }
            }
            $result = $v  # last assignment wins
        }
    }
    return $result
}

# Write-RrSkip — a NAMED skip. Never a silent zero-count report: the counts
# block is omitted entirely, so no caller can mistake "could not measure" for
# "measured, and it was zero".
function Write-RrSkip {
    param([string]$Reason)
    [Console]::Error.WriteLine("SKIP $Reason")
    if (-not $List.IsPresent) {
        Write-Host '# recall-report — INFORMATIONAL rolling recall-failure count'
        Write-Host ''
        Write-Host "SKIP — $Reason"
        Write-Host ''
        Write-Host 'No counts are reported. This is an indeterminate result, NOT a clean zero.'
    }
    exit 0
}

# --- resolve the sessions dir -------------------------------------------------
$sessionsSrc = ''
if (-not [string]::IsNullOrEmpty($SessionsDir)) {
    $sessionsSrc = '--sessions-dir flag'
} elseif (-not $Isolated.IsPresent) {
    $vault = ''
    $envVault = [Environment]::GetEnvironmentVariable('OBSIDIAN_VAULT_PATH')
    if (-not [string]::IsNullOrEmpty($envVault)) {
        $vault = $envVault; $sessionsSrc = '$OBSIDIAN_VAULT_PATH'
    } else {
        $vault = Get-RrLocalEnvValue -Path (Join-Path $repoRoot 'local.env') -Key 'OBSIDIAN_VAULT_PATH'
        if (-not [string]::IsNullOrEmpty($vault)) { $sessionsSrc = 'local.env OBSIDIAN_VAULT_PATH' }
    }
    if (-not [string]::IsNullOrEmpty($vault)) {
        $vault = $vault.TrimEnd('/', '\')
        $SessionsDir = Join-Path $vault $SESSIONS_REL
    }
}

if ([string]::IsNullOrEmpty($SessionsDir)) {
    Write-RrSkip 'no sessions directory configured (no --sessions-dir, no $OBSIDIAN_VAULT_PATH, no local.env OBSIDIAN_VAULT_PATH) — nothing to scan'
}

# A CONFIGURED but broken surface is a SCAN ERROR, not a skip. Same reasoning as
# closeout-gate's configured-but-nonexistent vault: a misspelled or unsynced
# path would otherwise report a clean zero that looks exactly like a clean
# window.
if (-not (Test-Path -LiteralPath $SessionsDir -PathType Container)) {
    [Console]::Error.WriteLine("recall-report: SCAN ERROR — configured sessions directory does not exist: $SessionsDir")
    exit 2
}
try {
    [void][System.IO.Directory]::GetFiles($SessionsDir, '*.md')
} catch {
    [Console]::Error.WriteLine("recall-report: SCAN ERROR — configured sessions directory is not readable: $SessionsDir")
    exit 2
}

# --- select the window --------------------------------------------------------
# Ordinal sort throughout — the PS equivalent of the bash twin's LC_ALL=C sort.
$allFiles = [string[]]([System.IO.Directory]::GetFiles($SessionsDir, '*.md'))
[Array]::Sort($allFiles, [StringComparer]::Ordinal)
$considered = $allFiles.Count
if ($considered -eq 0) {
    Write-RrSkip "no .md files in $SessionsDir — nothing to scan"
}

$meaningful = [System.Collections.Generic.List[string]]::new()
foreach ($f in $allFiles) {
    # One read per file, one pass over its lines — no per-line subprocess.
    # An unreadable file fails LOUD (same contract as the bash twin's grep
    # rc>=2 check): silently skipping it would understate the denominator —
    # the same false-clean shape as a misspelled dir.
    try { $lines = [System.IO.File]::ReadAllLines($f) } catch {
        [Console]::Error.WriteLine("recall-report: SCAN ERROR — a session log could not be read: $f")
        exit 2
    }
    foreach ($ln in $lines) {
        if ($ln -cmatch $MEANINGFUL_RE) { $meaningful.Add($f); break }
    }
}
$meaningfulTotal = $meaningful.Count
if ($meaningfulTotal -eq 0) {
    Write-RrSkip ("no meaningful session logs found in $SessionsDir ($considered file(s) considered; " +
                  "none carry the marker '## Issues this session') — indeterminate, not a clean zero")
}

$start = 0
if ($meaningfulTotal -gt $WindowN) { $start = $meaningfulTotal - $WindowN }
$scannedFiles = $meaningful.GetRange($start, $meaningfulTotal - $start)
$scanned = $scannedFiles.Count

# --- extract ------------------------------------------------------------------
# Class resolution: the token immediately after `, class ` must be a KNOWN class
# and must end at a non-class character, so `loaded-but-ignored + no act-time
# gate` still resolves to `loaded-but-ignored` while a longer unknown token
# (e.g. `not-loaded-ish`) does NOT masquerade as a known one.
$reNotLoaded = '^\*\*Recall failure, class not-loaded([^A-Za-z0-9-]|$)'
$reIgnored   = '^\*\*Recall failure, class loaded-but-ignored([^A-Za-z0-9-]|$)'

$nNotLoaded = 0
$nIgnored = 0
$nUnclassified = 0
$records = [System.Collections.Generic.List[string]]::new()

foreach ($f in $scannedFiles) {
    # Same loud-read contract as the meaningful pass — never a silently
    # understated count.
    try { $lines = [System.IO.File]::ReadAllLines($f) } catch {
        [Console]::Error.WriteLine("recall-report: SCAN ERROR — a session log could not be read: $f")
        exit 2
    }
    for ($k = 0; $k -lt $lines.Count; $k++) {
        $ln = $lines[$k]
        if ($ln -cnotmatch $RECORD_RE) { continue }
        $cls = 'unclassified'
        if ($ln -cmatch $reNotLoaded)      { $cls = 'not-loaded' }
        elseif ($ln -cmatch $reIgnored)    { $cls = 'loaded-but-ignored' }
        switch ($cls) {
            'not-loaded'         { $nNotLoaded++ }
            'loaded-but-ignored' { $nIgnored++ }
            default              { $nUnclassified++ }
        }
        $records.Add(($cls + "`t" + $f + ':' + ($k + 1)))
    }
}

$classifiedTotal = $nNotLoaded + $nIgnored
# InvariantCulture on the rate format: a comma-decimal culture would print
# "0,15" and every downstream numeric parse would break (the PS equivalent of
# the bash twin's LC_ALL=C awk).
$rate = if ($scanned -gt 0) {
    ([double]$classifiedTotal / [double]$scanned).ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture)
} else {
    '0.00'
}

# --- report -------------------------------------------------------------------
if ($List.IsPresent) {
    Write-Host (@('counts', $WindowN, $considered, $meaningfulTotal, $scanned,
                  $nNotLoaded, $nIgnored, $nUnclassified) -join "`t")
    foreach ($r in $records) { Write-Host ("record`t" + $r) }
    exit 0
}

Write-Host '# recall-report — INFORMATIONAL rolling recall-failure count'
Write-Host ''
$srcLabel = if ($sessionsSrc -ne '') { $sessionsSrc } else { 'resolved' }
Write-Host ('sessions dir:            {0} ({1})' -f $SessionsDir, $srcLabel)
Write-Host 'meaningful marker:       ## Issues this session'
Write-Host ('window:                  {0}' -f $WindowN)
Write-Host ('files considered:        {0}' -f $considered)
Write-Host ('meaningful logs found:   {0}' -f $meaningfulTotal)
Write-Host ('meaningful logs scanned: {0} (the newest {0} of them, by filename order)' -f $scanned)
Write-Host ''
Write-Host 'recall-failure records in window:'
Write-Host ('- not-loaded:          {0}' -f $nNotLoaded)
Write-Host ('- loaded-but-ignored:  {0}' -f $nIgnored)
Write-Host ('- classified total:    {0}' -f $classifiedTotal)
Write-Host ('- unclassified recall-failure mentions (informational, NOT assigned a class): {0}' -f $nUnclassified)
Write-Host ''
Write-Host ('rate: {0} recall-failure records per meaningful session scanned ({1} / {2})' -f $rate, $classifiedTotal, $scanned)

if ($records.Count -gt 0) {
    Write-Host ''
    Write-Host 'records:'
    foreach ($r in $records) { Write-Host ('- ' + $r.Replace("`t", ' ')) }
}

Write-Host ''
Write-Host 'INFORMATIONAL — this is a rolling rate, not a scored or graded metric.'
Write-Host 'Nothing here passes, fails, or grades anything, and there is no target'
Write-Host 'number. The extractor is deliberately strict (only line-leading'
Write-Host '`**Recall failure, class <X>` records count), so the true count can only'
Write-Host 'be HIGHER than what is reported here, never lower.'
exit 0
