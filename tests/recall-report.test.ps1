#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/recall-report.test.ps1 — Windows-native twin of tests/recall-report.test.sh.
#
# The reporter is an INFORMATIONAL rolling count of the Q1a recall-failure
# records already written into the durable session logs. What is under test:
#
#   - EXTRACTION: both classes counted; unknown classes bucketed, never guessed
#   - RESTRAINT:  every prose shape observed in the real corpus that a looser
#                 scanner would miscount stays silent (§4 below)
#   - SELECTION:  the meaningful-log filter, and window trimming
#   - SKIPS:      named, never a silent zero-count report
#   - EXITS:      0 report/named-skip, 2 usage-or-scan error
#   - WIRING:     the self-audit informational key, and its score neutrality
#
# WHY THE RESTRAINT SECTION IS THE BULK OF THIS FILE. The extractor was written
# against the real ~320-log session archive BEFORE these tests existed, and the
# first cut over that corpus surfaced far more prose ABOUT recall failures than
# actual records: negations, an older bulleted format, reversed word order,
# parenthetical classes, a section heading, and a bare class token used as a
# noun mid-sentence. Each shape below is a paraphrase of a line that really
# appears there. Every restraint fixture is scanned ALONGSIDE one true-positive
# record, so a fixture can never pass vacuously by the scanner having gone
# silent altogether.
#
# Mirrors the .sh twin 1:1 — same fixtures, same assertions.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$RR_SCRIPT = Join-Path $env:REPO_ROOT 'scripts' 'recall-report.ps1'
Assert-File 'recall-report.test: scripts/recall-report.ps1 exists' $RR_SCRIPT

$RR_TAB = "`t"

function New-RrTempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('rr-test-' + [Guid]::NewGuid().Guid.Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function Write-RrFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, ($Content -replace "`r`n", "`n"), $utf8NoBom)
}

# New-RrLog — a MEANINGFUL session log (one carrying the `## Issues this
# session` marker) whose Lessons section holds the given body lines.
function New-RrLog {
    param([string]$Dir, [string]$Name, [string[]]$Body = @())
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("---`ntitle: fixture`n---`n`n# fixture session`n`n")
    [void]$sb.Append("## TL;DR`n`nfixture.`n`n")
    [void]$sb.Append("## Issues this session`n`n### FIX-1 — fixture`n`n")
    [void]$sb.Append("## Lessons (Q1a recall-failure record)`n`n")
    foreach ($l in $Body) { [void]$sb.Append($l + "`n`n") }
    Write-RrFile (Join-Path $Dir $Name) $sb.ToString()
}

# New-RrThinLog — a NON-meaningful log: same content, no `## Issues this
# session` marker. The denominator must exclude it, and so must the numerator.
function New-RrThinLog {
    param([string]$Dir, [string]$Name, [string[]]$Body = @())
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("---`ntitle: fixture`n---`n`n# thin session`n`n")
    [void]$sb.Append("## TL;DR`n`nfixture.`n`n")
    [void]$sb.Append("## Issues`n`nnot the template heading.`n`n")
    [void]$sb.Append("## Lessons (Q1a recall-failure record)`n`n")
    foreach ($l in $Body) { [void]$sb.Append($l + "`n`n") }
    Write-RrFile (Join-Path $Dir $Name) $sb.ToString()
}

# Invoke-Rr — run the reporter, capturing stdout+stderr as one string plus rc.
function Invoke-Rr {
    param([string[]]$Argv)
    $out = (& pwsh -NoProfile -File $RR_SCRIPT @Argv 2>&1 | Out-String)
    return [pscustomobject]@{ Out = $out; Rc = $LASTEXITCODE }
}

# Get-RrCounts — run --list and return just the counts record (or '').
function Get-RrCounts {
    param([string]$Dir, [string[]]$Extra = @())
    $argv = @('--sessions-dir', $Dir) + $Extra + @('--list')
    $out = (& pwsh -NoProfile -File $RR_SCRIPT @argv 2>$null | Out-String)
    foreach ($line in ($out -split "`r?`n")) {
        if ($line.StartsWith('counts', [StringComparison]::Ordinal)) { return $line }
    }
    return ''
}

function Get-RrExpect {
    param([int]$Window, [int]$Considered, [int]$Meaningful, [int]$Scanned,
          [int]$NotLoaded, [int]$Ignored, [int]$Unclassified)
    return (@('counts', $Window, $Considered, $Meaningful, $Scanned,
              $NotLoaded, $Ignored, $Unclassified) -join $RR_TAB)
}

$RR_TMP = New-RrTempDir

# The canonical true-positive records, in the exact shape closeout writes them.
$RR_TP_NOT_LOADED = '**Recall failure, class not-loaded:** the rule lived in a note that was never read at orient.'
$RR_TP_IGNORED    = '**Recall failure, class loaded-but-ignored:** the rule was in context at orient but did not fire.'

# === 1. POSITIVE CONTROLS — both classes are counted, and located.
$RR_BOTH = Join-Path $RR_TMP 'both'
New-RrLog $RR_BOTH '2026-01-01-000000-host-aaaaaaaa.md' @($RR_TP_NOT_LOADED)
New-RrLog $RR_BOTH '2026-01-02-000000-host-bbbbbbbb.md' @($RR_TP_IGNORED)
Assert-Eq 'recall-report.test: both classes are counted (1 not-loaded, 1 loaded-but-ignored)' `
    (Get-RrExpect 20 2 2 2 1 1 0) (Get-RrCounts $RR_BOTH)

$rrBothList = (Invoke-Rr @('--sessions-dir', $RR_BOTH, '--list')).Out
Assert-Contains 'recall-report.test: a not-loaded record is emitted with its file:line' `
    $rrBothList ("record${RR_TAB}not-loaded${RR_TAB}" + (Join-Path $RR_BOTH '2026-01-01-000000-host-aaaaaaaa.md') + ':')
Assert-Contains 'recall-report.test: a loaded-but-ignored record is emitted with its file:line' `
    $rrBothList ("record${RR_TAB}loaded-but-ignored${RR_TAB}" + (Join-Path $RR_BOTH '2026-01-02-000000-host-bbbbbbbb.md') + ':')

# Two records in ONE log are two records — the count is per RECORD, not per file.
$RR_TWO_IN_ONE = Join-Path $RR_TMP 'two-in-one'
New-RrLog $RR_TWO_IN_ONE '2026-01-01-000000-host-aaaaaaaa.md' @($RR_TP_NOT_LOADED, $RR_TP_IGNORED)
Assert-Eq 'recall-report.test: two records in one log are counted separately' `
    (Get-RrExpect 20 1 1 1 1 1 0) (Get-RrCounts $RR_TWO_IN_ONE)

# The human report states, in words, that it is not a scored metric. This is a
# CONTRACT of the driving issue (no premature scoring), not decoration.
$rrHuman = (Invoke-Rr @('--sessions-dir', $RR_BOTH)).Out
Assert-Contains 'recall-report.test: the human report declares itself INFORMATIONAL' $rrHuman 'INFORMATIONAL'
Assert-Contains 'recall-report.test: the human report denies being a scored/graded metric' `
    $rrHuman 'not a scored or graded metric'
Assert-Contains 'recall-report.test: the human report states the rolling rate' `
    $rrHuman 'rate: 1.00 recall-failure records per meaningful session scanned (2 / 2)'
Assert-Contains 'recall-report.test: the human report names the window' $rrHuman 'window:                  20'
Assert-Contains 'recall-report.test: the human report names how many files were considered' `
    $rrHuman 'files considered:        2'
Assert-Contains 'recall-report.test: the human report names the meaningful-log count scanned' `
    $rrHuman 'meaningful logs scanned: 2'

# === 2. UNKNOWN CLASSES are bucketed, never guessed into a known class.
$RR_UNK = Join-Path $RR_TMP 'unknown'
New-RrLog $RR_UNK '2026-01-01-000000-host-aaaaaaaa.md' @(
    $RR_TP_IGNORED,
    '**Recall failure, class wrong-shelf:** a class this scanner has never seen.',
    '**Recall failure:** a record with no class token at all.')
Assert-Eq 'recall-report.test: an unknown class goes to the unclassified bucket, not to a known class' `
    (Get-RrExpect 20 1 1 1 0 1 2) (Get-RrCounts $RR_UNK)

# A LONGER token that merely starts with a known class must NOT be read as that
# class — the class boundary is enforced, so `not-loaded-ish` is unclassified.
$RR_PREFIX = Join-Path $RR_TMP 'prefix'
New-RrLog $RR_PREFIX '2026-01-01-000000-host-aaaaaaaa.md' @(
    $RR_TP_IGNORED,
    '**Recall failure, class not-loaded-ish:** a near-miss token that must not be claimed.')
Assert-Eq 'recall-report.test: a class token that merely PREFIXES a known class is unclassified' `
    (Get-RrExpect 20 1 1 1 0 1 1) (Get-RrCounts $RR_PREFIX)

# A trailing qualifier after a KNOWN class still resolves to that class — this
# shape appears verbatim in the real corpus.
$RR_QUAL = Join-Path $RR_TMP 'qualified'
New-RrLog $RR_QUAL '2026-01-01-000000-host-aaaaaaaa.md' @(
    '**Recall failure, class loaded-but-ignored + no act-time gate.** the rule existed and the gate did not.')
Assert-Eq 'recall-report.test: a known class with a trailing qualifier still resolves to that class' `
    (Get-RrExpect 20 1 1 1 0 1 0) (Get-RrCounts $RR_QUAL)

# === 3. SELECTION — the meaningful filter and window trimming.
$RR_FILTER = Join-Path $RR_TMP 'filter'
New-RrLog     $RR_FILTER '2026-01-01-000000-host-aaaaaaaa.md' @($RR_TP_IGNORED)
New-RrThinLog $RR_FILTER '2026-01-02-000000-host-bbbbbbbb.md' @($RR_TP_NOT_LOADED)
Assert-Eq 'recall-report.test: a non-meaningful log is excluded from the denominator AND the count' `
    (Get-RrExpect 20 2 1 1 0 1 0) (Get-RrCounts $RR_FILTER)

# Window trimming: 5 meaningful logs, window 2 → only the NEWEST 2 scanned. The
# three older logs each carry a record, so a broken trim shows up as a higher
# count, not merely a different scanned tally.
$RR_WIN = Join-Path $RR_TMP 'window'
New-RrLog $RR_WIN '2026-01-01-000000-host-aaaaaaaa.md' @($RR_TP_NOT_LOADED)
New-RrLog $RR_WIN '2026-01-02-000000-host-bbbbbbbb.md' @($RR_TP_NOT_LOADED)
New-RrLog $RR_WIN '2026-01-03-000000-host-cccccccc.md' @($RR_TP_NOT_LOADED)
New-RrLog $RR_WIN '2026-01-04-000000-host-dddddddd.md' @($RR_TP_IGNORED)
New-RrLog $RR_WIN '2026-01-05-000000-host-eeeeeeee.md' @($RR_TP_IGNORED)
Assert-Eq 'recall-report.test: --window trims to the NEWEST N meaningful logs' `
    (Get-RrExpect 2 5 5 2 0 2 0) (Get-RrCounts $RR_WIN @('--window', '2'))
Assert-Eq 'recall-report.test: a window LARGER than the corpus scans everything, not N' `
    (Get-RrExpect 99 5 5 5 3 2 0) (Get-RrCounts $RR_WIN @('--window', '99'))
Assert-Eq 'recall-report.test: --window 1 scans exactly the newest log' `
    (Get-RrExpect 1 5 5 1 0 1 0) (Get-RrCounts $RR_WIN @('--window', '1'))

# Chronology comes from the FILENAME sort, not from mtime — a vault synced
# through cloud storage rewrites mtimes on files whose content never changed.
(Get-Item -LiteralPath (Join-Path $RR_WIN '2026-01-01-000000-host-aaaaaaaa.md')).LastWriteTime = Get-Date
Assert-Eq 'recall-report.test: window selection ignores mtime (filename order is the clock)' `
    (Get-RrExpect 2 5 5 2 0 2 0) (Get-RrCounts $RR_WIN @('--window', '2'))

# === 4. RESTRAINT — real-corpus prose shapes that must NOT be counted.
#
# Each fixture pairs ONE restraint line with ONE true-positive record and
# asserts the counts are EXACTLY the true positive's. The paired true positive
# is what makes the assertion non-vacuous: a scanner that had simply stopped
# matching anything would fail these, not pass them.
function Test-RrRestraint {
    param([string]$Slug, [string]$Label, [string]$Line)
    $dir = Join-Path $RR_TMP ('restraint-' + $Slug)
    New-RrLog $dir '2026-01-01-000000-host-aaaaaaaa.md' @($Line, $RR_TP_IGNORED)
    Assert-Eq ("recall-report.test: restraint — " + $Label) `
        (Get-RrExpect 20 1 1 1 0 1 0) (Get-RrCounts $dir)
}

Test-RrRestraint 'negation-none' `
    "a bulleted 'Recall failure: none' negation is not a record" `
    '- Recall failure: none — the vault decision and operations lesson were loaded and applied.'

Test-RrRestraint 'negation-no-action' `
    "a '[no-action] No recall failure occurred' line is not a record" `
    '- [no-action] No recall failure occurred; the existing session and review rules were loaded and applied.'

Test-RrRestraint 'negation-inline' `
    'a negation buried mid-sentence is not a record' `
    '- [no-action] No new operating rule was needed. Recall failure: none this session.'

Test-RrRestraint 'old-bulleted-classified' `
    'the OLDER bulleted classified format is deliberately not counted (documented under-report)' `
    '- [check] Recall failure, loaded-but-ignored: the lesson index already named the three-layer check.'

Test-RrRestraint 'reversed-order' `
    "a reversed '[loaded-but-ignored recall failure]' bracket tag is not a record" `
    '- [loaded-but-ignored recall failure] The known working-directory rule was in context but the first run ignored it.'

Test-RrRestraint 'prose-plural' `
    "prose describing misses as 'loaded-but-ignored recall failures' is not a record" `
    "- [inferred] The morning's discovery misses were loaded-but-ignored recall failures, not new rules."

Test-RrRestraint 'section-heading' `
    'the section HEADING that introduces records is not itself a record' `
    '## Lessons (Q1a recall-failure record)'

Test-RrRestraint 'parenthetical-class-agent' `
    "a bulleted parenthetical class '(Q1a, loaded-but-ignored)' is not a record" `
    '- [agent-summary] Recall failure (Q1a, loaded-but-ignored): the review rule was in context at orient but did not fire.'

Test-RrRestraint 'parenthetical-class-bare' `
    "a bulleted parenthetical class '(loaded-but-ignored)' is not a record" `
    '- Recall failure (loaded-but-ignored): the pipe-exit rule was violated twice by the same shape.'

Test-RrRestraint 'bare-class-token-in-prose' `
    "a bare class token used as a noun ('Surface class: not-loaded.') is not a record" `
    '- [inferred] Recall miss this session: the rule sat in a body that is not read at routing. Surface class: not-loaded.'

Test-RrRestraint 'unbolded-line-start' `
    "an UNBOLDED line-start 'Recall failure, class ...' is not a record (the bold marker is the record)" `
    'Recall failure, class not-loaded: an unbolded line that predates the record marker.'

Test-RrRestraint 'indented-record' `
    'an INDENTED record marker is not a line-start record' `
    '  **Recall failure, class not-loaded:** indented under another bullet, so not a top-level record.'

Test-RrRestraint 'mid-line-marker' `
    'a record marker quoted mid-line is not a record' `
    'The template asks for a **Recall failure, class not-loaded:** line here.'

# Every restraint line together in ONE log, still alongside one true positive.
$RR_ALL_FP = Join-Path $RR_TMP 'restraint-combined'
New-RrLog $RR_ALL_FP '2026-01-01-000000-host-aaaaaaaa.md' @(
    '- Recall failure: none — the lesson was loaded and applied.',
    '- [no-action] No recall failure occurred; existing rules covered the work.',
    '- [check] Recall failure, loaded-but-ignored: the older bulleted format.',
    '- [loaded-but-ignored recall failure] reversed bracket tag.',
    '- [inferred] The misses were loaded-but-ignored recall failures.',
    '## Lessons (Q1a recall-failure record)',
    '- [agent-summary] Recall failure (Q1a, loaded-but-ignored): parenthetical.',
    '- Recall failure (loaded-but-ignored): parenthetical, bare.',
    '- [inferred] Recall miss this session. Surface class: not-loaded.',
    'Recall failure, class not-loaded: unbolded line start.',
    '  **Recall failure, class not-loaded:** indented.',
    'The template asks for a **Recall failure, class not-loaded:** line.',
    $RR_TP_IGNORED)
Assert-Eq 'recall-report.test: restraint — every false-positive shape at once still counts only the true positive' `
    (Get-RrExpect 20 1 1 1 0 1 0) (Get-RrCounts $RR_ALL_FP)

# === 5. NAMED SKIPS — an unmeasurable window is never a silent zero-count report.
$RR_EMPTY = Join-Path $RR_TMP 'empty'
New-Item -ItemType Directory -Path $RR_EMPTY -Force | Out-Null
$rrEmpty = Invoke-Rr @('--sessions-dir', $RR_EMPTY, '--list')
Assert-Eq 'recall-report.test: an empty sessions dir exits 0 (a named skip, not an error)' 0 $rrEmpty.Rc
Assert-Contains 'recall-report.test: an empty sessions dir names the skip' $rrEmpty.Out 'SKIP no .md files in'
Assert-NotContains 'recall-report.test: an empty sessions dir emits NO counts record (never a zero report)' `
    $rrEmpty.Out ('counts' + $RR_TAB)

$RR_NOMARK = Join-Path $RR_TMP 'no-marker'
New-RrThinLog $RR_NOMARK '2026-01-01-000000-host-aaaaaaaa.md' @($RR_TP_IGNORED)
$rrNoMark = Invoke-Rr @('--sessions-dir', $RR_NOMARK, '--list')
Assert-Eq 'recall-report.test: zero MEANINGFUL logs exits 0 (a named skip)' 0 $rrNoMark.Rc
Assert-Contains 'recall-report.test: zero meaningful logs names the skip' `
    $rrNoMark.Out 'SKIP no meaningful session logs found'
Assert-Contains 'recall-report.test: zero meaningful logs says it is indeterminate, not a clean zero' `
    $rrNoMark.Out 'indeterminate, not a clean zero'
Assert-NotContains 'recall-report.test: zero meaningful logs emits NO counts record' `
    $rrNoMark.Out ('counts' + $RR_TAB)

# Sessions dir entirely UNCONFIGURED — no flag, no env var, no local.env.
# --isolated is what suppresses the local.env fallback; without it this test
# would pass or fail depending on whether the operator's checkout has one.
$rrSavedVault = $env:OBSIDIAN_VAULT_PATH
Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
try {
    $rrUnconf = Invoke-Rr @('--isolated', '--list')
    $rrUnconfHuman = (Invoke-Rr @('--isolated')).Out
} finally {
    if ($null -ne $rrSavedVault) { $env:OBSIDIAN_VAULT_PATH = $rrSavedVault }
}
Assert-Eq 'recall-report.test: an unconfigured sessions dir exits 0 (a named skip)' 0 $rrUnconf.Rc
Assert-Contains 'recall-report.test: an unconfigured surface names the skip' `
    $rrUnconf.Out 'SKIP no sessions directory configured'
Assert-NotContains 'recall-report.test: an unconfigured surface emits NO counts record' `
    $rrUnconf.Out ('counts' + $RR_TAB)
Assert-Contains 'recall-report.test: the human-mode skip is stated on stdout too' `
    $rrUnconfHuman 'SKIP — no sessions directory configured'
Assert-Contains 'recall-report.test: the human-mode skip denies being a clean zero' `
    $rrUnconfHuman 'This is an indeterminate result, NOT a clean zero.'
Assert-NotContains 'recall-report.test: the human-mode skip prints no rate line' $rrUnconfHuman 'rate:'

# === 6. EXIT LAW — 0 for a report or a named skip, 2 for usage and scan errors.
#
# BASELINE FIRST: the same invocation shape with valid arguments exits 0.
# Without it, every exit-2 assertion below could be satisfied by a reporter that
# is simply broken for all inputs.
Assert-Eq 'recall-report.test: BASELINE — a valid invocation exits 0' 0 `
    (Invoke-Rr @('--sessions-dir', $RR_BOTH, '--window', '5', '--list')).Rc
Assert-Eq 'recall-report.test: an unknown arg is a usage error (exit 2)' 2 `
    (Invoke-Rr @('--sessions-dir', $RR_BOTH, '--bogus')).Rc
Assert-Eq 'recall-report.test: --window 0 is a usage error (exit 2)' 2 `
    (Invoke-Rr @('--sessions-dir', $RR_BOTH, '--window', '0')).Rc
Assert-Eq 'recall-report.test: a non-numeric --window is a usage error (exit 2)' 2 `
    (Invoke-Rr @('--sessions-dir', $RR_BOTH, '--window', 'twenty')).Rc
Assert-Eq 'recall-report.test: a negative --window is a usage error (exit 2)' 2 `
    (Invoke-Rr @('--sessions-dir', $RR_BOTH, '--window', '-5')).Rc
# DOCUMENTED TWIN DIVERGENCE: the bash twin exits 2 for a value-less `--window`
# / `--sessions-dir`. On PowerShell the BINDER claims those before the $Rest
# loop can see them (one leading `-` is stripped, `-window` prefix-matches the
# -Window parameter, and the missing argument is a binder error, exit 1) — the
# trap recorded in [[reference_ps_binder_and_automatic_variable_traps]], shared
# by every POSIX-flag PS twin in scripts/. It is still a loud non-zero refusal,
# which is the property that matters; only the exit CODE differs.
foreach ($rrFlag in @('--window', '--sessions-dir')) {
    $rrNoValue = (Invoke-Rr @($rrFlag)).Rc
    if ($rrNoValue -ne 0) {
        _Pass "recall-report.test: $rrFlag without a value is refused (non-zero; binder claims it before the arg loop)"
    } else {
        _Fail "recall-report.test: $rrFlag without a value is refused (non-zero; binder claims it before the arg loop)" `
            @("expected a non-zero exit, got $rrNoValue")
    }
}
Assert-Eq 'recall-report.test: --help exits 0' 0 (Invoke-Rr @('--help')).Rc

# A CONFIGURED but nonexistent sessions dir is a SCAN ERROR, not a skip.
$RR_GHOST = Join-Path $RR_TMP 'no-such-dir'
$rrGhost = Invoke-Rr @('--sessions-dir', $RR_GHOST, '--list')
Assert-Eq 'recall-report.test: a configured-but-nonexistent sessions dir FAILS loud (exit 2)' 2 $rrGhost.Rc
Assert-Contains 'recall-report.test: the scan error names the broken path' `
    $rrGhost.Out ('SCAN ERROR — configured sessions directory does not exist: ' + $RR_GHOST)
Assert-NotContains 'recall-report.test: a scan error emits NO counts record' $rrGhost.Out ('counts' + $RR_TAB)

# A path containing ":<digits>:" is a valid POSIX directory name (illegal on
# Windows — platform-guarded); the record separator search must not anchor on it
# (panel finding; the bash twin's grep-output parse was the defect, but the
# behavioral contract is pinned on both twins).
if ($IsWindows) {
    _Skip 'recall-report.test: a colon-digits directory still classifies records' 'colons are illegal in Windows paths'
} else {
    $RR_COLON = Join-Path $RR_TMP 'run:12:archive'
    New-RrLog $RR_COLON '2026-01-01-000000-host-aaaaaaaa.md' @($RR_TP_NOT_LOADED)
    New-RrLog $RR_COLON '2026-01-02-000000-host-bbbbbbbb.md' @($RR_TP_IGNORED)
    $rrColon = Invoke-Rr @('--sessions-dir', $RR_COLON, '--list')
    Assert-Contains 'recall-report.test: a colon-digits directory still classifies records' `
        $rrColon.Out (Get-RrExpect 20 2 2 2 1 1 0)
    Assert-Contains 'recall-report.test: a colon-digits directory keeps the full record location' `
        $rrColon.Out ('record' + $RR_TAB + 'not-loaded' + $RR_TAB + (Join-Path $RR_COLON '2026-01-01-000000-host-aaaaaaaa.md') + ':')
}

# An unreadable SELECTED file is the same false-clean shape as a misspelled dir:
# silently skipping it would understate the count with exit 0 (panel finding).
# Unix-permission fixture — guarded on Windows (chmod bits are not enforced) and
# under root (which reads through permission bits).
if ($IsWindows -or (id -u) -eq '0') {
    _Skip 'recall-report.test: an unreadable session log fails loud' 'permission-bit fixture needs non-root Unix'
} else {
    $RR_UNREAD = Join-Path $RR_TMP 'unreadable'
    New-RrLog $RR_UNREAD '2026-01-01-000000-host-aaaaaaaa.md' @($RR_TP_IGNORED)
    New-RrLog $RR_UNREAD '2026-01-02-000000-host-bbbbbbbb.md' @($RR_TP_IGNORED)
    chmod 000 (Join-Path $RR_UNREAD '2026-01-02-000000-host-bbbbbbbb.md')
    $rrUnread = Invoke-Rr @('--sessions-dir', $RR_UNREAD, '--list')
    chmod 644 (Join-Path $RR_UNREAD '2026-01-02-000000-host-bbbbbbbb.md')
    Assert-Eq 'recall-report.test: an unreadable session log fails loud (exit 2), never an understated count' `
        2 $rrUnread.Rc
    Assert-Contains 'recall-report.test: the unreadable-file scan error is named' `
        $rrUnread.Out 'SCAN ERROR — a session log could not be read'
    Assert-NotContains 'recall-report.test: an unreadable-file scan emits NO counts record' `
        $rrUnread.Out ('counts' + $RR_TAB)
}

# === 7. RESOLUTION — $OBSIDIAN_VAULT_PATH supplies <vault>/30-Archive/Sessions.
$RR_VAULT = Join-Path $RR_TMP 'vault'
New-RrLog (Join-Path $RR_VAULT '30-Archive' 'Sessions') '2026-01-01-000000-host-aaaaaaaa.md' @($RR_TP_IGNORED)
$env:OBSIDIAN_VAULT_PATH = $RR_VAULT
try {
    $rrEnvOut = (Invoke-Rr @('--list')).Out
    $rrFlagOut = (Invoke-Rr @('--sessions-dir', $RR_BOTH, '--list')).Out
} finally {
    if ($null -ne $rrSavedVault) { $env:OBSIDIAN_VAULT_PATH = $rrSavedVault }
    else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
}
Assert-Contains 'recall-report.test: $OBSIDIAN_VAULT_PATH resolves to <vault>/30-Archive/Sessions' `
    $rrEnvOut (Get-RrExpect 20 1 1 1 0 1 0)
Assert-Contains 'recall-report.test: --sessions-dir overrides $OBSIDIAN_VAULT_PATH' `
    $rrFlagOut (Get-RrExpect 20 2 2 2 1 1 0)

# === 8. SELF-AUDIT WIRING — the informational key, and its SCORE NEUTRALITY.
#
# Hermetic: a stub .ps1 stands in for the reporter via $env:SELF_AUDIT_RECALL_BIN
# (the same convention $env:SELF_AUDIT_CURRENTNESS_BIN uses for the semantic
# checker). What is under test is the WIRING contract, not the extractor. The
# load-bearing assertion is the one nobody would notice breaking: an
# informational count must NEVER move total, a pillar score, or the gap list.
$RR_SA = Join-Path $env:REPO_ROOT 'scripts' 'self-audit.ps1'

function New-RrFixtureRepo {
    param([string]$Root)
    foreach ($d in @(
        (Join-Path $Root 'capabilities'),
        (Join-Path $Root 'verification'),
        (Join-Path $Root 'harnesses' 'claude' 'capabilities'),
        (Join-Path $Root 'harnesses' 'codex' 'capabilities'))) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    Write-RrFile (Join-Path $Root 'capabilities' 'example.md') @'
---
name: example
summary: example capability for fixture
triggers: [test]
verification: example
harnesses: [claude, codex]
kind: native
lifecycle: shipped
---

# Example
'@
    Write-RrFile (Join-Path $Root 'harnesses' 'claude' 'capabilities' 'example.md') @'
---
lifecycle: shipped
---

## Claude realization — example
'@
    Write-RrFile (Join-Path $Root 'harnesses' 'codex' 'capabilities' 'example.md') @'
---
lifecycle: shipped
---

## Codex realization — example
'@
    Write-RrFile (Join-Path $Root 'verification' 'example.md') '# Example verification recipe'
}

function New-RrStub {
    param([string]$Path, [int]$ExitCode, [string[]]$Records = @())
    $body = New-Object System.Text.StringBuilder
    [void]$body.AppendLine('param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgList = @())')
    foreach ($r in $Records) {
        [void]$body.AppendLine("Write-Output `"$($r.Replace('"', '`"'))`"")
    }
    [void]$body.AppendLine('[Console]::Error.WriteLine("SKIP stub reason")')
    [void]$body.AppendLine("exit $ExitCode")
    Write-RrFile $Path $body.ToString()
}

function Invoke-RrSelfAudit {
    param([string]$Stub, [string[]]$Argv)
    if ($Stub -ne '') { $env:SELF_AUDIT_RECALL_BIN = $Stub }
    try { return (& pwsh -NoProfile -File $RR_SA @Argv 2>$null | Out-String) }
    finally { Remove-Item Env:SELF_AUDIT_RECALL_BIN -ErrorAction SilentlyContinue }
}

$rrFixture = New-RrTempDir
New-RrFixtureRepo $rrFixture
$rrStub = Join-Path $rrFixture 'stub.ps1'

# BASELINE, taken WITHOUT the reporter wired, so score neutrality is proved by
# comparison rather than asserted against a hard-coded number.
$rrBaseRaw = Invoke-RrSelfAudit '' @('--isolated', '--repo-root', $rrFixture, '--json')
$rrBase = $rrBaseRaw | ConvertFrom-Json
if ($rrBase.total -is [int] -or $rrBase.total -is [long]) {
    _Pass 'recall-report.test: BASELINE — the isolated fixture audit produces a total'
} else {
    _Fail 'recall-report.test: BASELINE — the isolated fixture audit produces a total' `
        @("total was not numeric: $($rrBase.total)")
}

# 1. A reported window — the key appears, carries the counts, and moves nothing.
New-RrStub $rrStub 0 @(
    "counts${RR_TAB}20${RR_TAB}323${RR_TAB}316${RR_TAB}20${RR_TAB}2${RR_TAB}3${RR_TAB}1",
    "record${RR_TAB}not-loaded${RR_TAB}log.md:12")
$rrOutRaw = Invoke-RrSelfAudit $rrStub @('--isolated', '--repo-root', $rrFixture, '--json')
$rrOut = $rrOutRaw | ConvertFrom-Json
Assert-Eq 'recall-report.test: self-audit exposes a recall_failures key' 'reported' $rrOut.recall_failures.status
Assert-Eq 'recall-report.test: self-audit carries the not-loaded count' 2 $rrOut.recall_failures.not_loaded
Assert-Eq 'recall-report.test: self-audit carries the loaded-but-ignored count' 3 $rrOut.recall_failures.loaded_but_ignored
Assert-Eq 'recall-report.test: self-audit carries the unclassified count' 1 $rrOut.recall_failures.unclassified
# ConvertFrom-Json's integer width is not the bash twin's `type == "number"`, so
# assert on the RAW json text that the value is unquoted (mirrors the same trick
# the semantic-currentness twin uses for open_children).
Assert-NotContains 'recall-report.test: the counts are numbers, not strings' $rrOutRaw '"scanned": "20"'
Assert-Eq 'recall-report.test: the key declares itself unscored' 'False' ([string]$rrOut.recall_failures.scored)
Assert-Eq 'recall-report.test: a record lands in the records array' 'not-loaded' $rrOut.recall_failures.records[0].class
# The whole point: informational means informational.
Assert-Eq 'recall-report.test: counts do NOT change the total score' ([string]$rrBase.total) ([string]$rrOut.total)
Assert-Eq 'recall-report.test: counts do NOT enter the gap list' `
    ([string]@($rrBase.gaps).Count) ([string]@($rrOut.gaps).Count)
Assert-Eq 'recall-report.test: counts do NOT change any pillar score' `
    ($rrBase.pillars | ConvertTo-Json -Depth 5 -Compress) ($rrOut.pillars | ConvertTo-Json -Depth 5 -Compress)

$rrMd = Invoke-RrSelfAudit $rrStub @('--isolated', '--repo-root', $rrFixture)
Assert-Contains 'recall-report.test: the markdown has its own section' $rrMd '## Recall failures'
Assert-Contains 'recall-report.test: the markdown renders the class counts' $rrMd '- loaded-but-ignored: 3'
Assert-Contains 'recall-report.test: the markdown states the informational boundary' `
    $rrMd 'Informational only; never scored'

# 2. A named SKIP (exit 0, no counts record) — degraded, NAMED, score-neutral.
New-RrStub $rrStub 0 @()
$rrSkipRaw = Invoke-RrSelfAudit $rrStub @('--isolated', '--repo-root', $rrFixture, '--json')
$rrSkip = $rrSkipRaw | ConvertFrom-Json
Assert-Eq 'recall-report.test: exit 0 without a counts record degrades to skipped' 'skipped' $rrSkip.recall_failures.status
Assert-Eq 'recall-report.test: the degraded entry names its reason, never anonymous' 'stub reason' $rrSkip.recall_failures.reason
Assert-Eq 'recall-report.test: a skipped window reports NULL counts, never zeros' '' ([string]$rrSkip.recall_failures.loaded_but_ignored)
Assert-Eq 'recall-report.test: a skip preserves the filesystem score' ([string]$rrBase.total) ([string]$rrSkip.total)

# 3. A SCAN ERROR (exit 2) — same degraded, named, score-neutral shape.
New-RrStub $rrStub 2 @()
$rrErr = (Invoke-RrSelfAudit $rrStub @('--isolated', '--repo-root', $rrFixture, '--json')) | ConvertFrom-Json
Assert-Eq 'recall-report.test: a reporter scan error degrades to skipped' 'skipped' $rrErr.recall_failures.status
Assert-Eq 'recall-report.test: a scan error preserves the filesystem score' ([string]$rrBase.total) ([string]$rrErr.total)

# 3b. A MALFORMED counts record (non-numeric field) is a reporter CONTRACT
# BREAK — a named skip, never `reported` with null counts (panel finding).
New-RrStub $rrStub 0 @("counts${RR_TAB}20${RR_TAB}323${RR_TAB}316${RR_TAB}20${RR_TAB}x${RR_TAB}3${RR_TAB}1")
$rrMalRaw = Invoke-RrSelfAudit $rrStub @('--isolated', '--repo-root', $rrFixture, '--json')
$rrMal = $rrMalRaw | ConvertFrom-Json
Assert-Eq 'recall-report.test: a malformed counts record degrades to skipped, not reported' 'skipped' $rrMal.recall_failures.status
Assert-Eq 'recall-report.test: the malformed-counts skip names the contract break' `
    'reporter emitted a malformed counts record' $rrMal.recall_failures.reason
Assert-Contains 'recall-report.test: malformed counts stay null, never partial' $rrMalRaw '"not_loaded": null'
Assert-Eq 'recall-report.test: a malformed counts record preserves the filesystem score' `
    ([string]$rrBase.total) ([string]$rrMal.total)

# 4. The key is present even with NO reporter wired at all — an absent section
# would read as "measured, and there was nothing", which is the opposite claim.
Assert-Eq 'recall-report.test: an isolated run with no reporter still names the skip' `
    'isolated run — recall failures not measured' $rrBase.recall_failures.reason
Assert-Contains 'recall-report.test: the markdown section exists even when unmeasured' `
    (Invoke-RrSelfAudit '' @('--isolated', '--repo-root', $rrFixture)) '## Recall failures'

# 5. PRESENCE vs ABSENCE of the key changes nothing about scoring — the JSON
# with recall_failures stripped must be identical either way.
$rrBaseStripped = ($rrBase | Select-Object -ExcludeProperty recall_failures | ConvertTo-Json -Depth 8 -Compress)
$rrOutStripped  = ($rrOut  | Select-Object -ExcludeProperty recall_failures | ConvertTo-Json -Depth 8 -Compress)
Assert-Eq 'recall-report.test: the scorecard minus recall_failures is identical with and without it' `
    $rrBaseStripped $rrOutStripped

Remove-Item -LiteralPath $rrFixture -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $RR_TMP -Recurse -Force -ErrorAction SilentlyContinue
