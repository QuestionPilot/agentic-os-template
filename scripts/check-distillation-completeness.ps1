#Requires -Version 7
<#
.SYNOPSIS
    PowerShell port of check-distillation-completeness.sh — pre-wipe /
    pre-migration guard that no feedback/decision memory note strands undistilled.

.DESCRIPTION
    The closeout capability promotes each feedback_*/decision memory note a
    session writes into its thematic vault 04-Lessons note (a cache->durable
    promotion — see capabilities/closeout.md). This check is the backstop: before
    a machine wipe or memory migration it cross-checks every feedback/decision
    note in the harness-native store against the 04-Lessons corpus and FAILS if
    any is not yet distilled.

    Deliberately NOT part of `make verify`: a mid-session store legitimately holds
    not-yet-distilled notes, so a per-push gate would false-fail. Run it at the
    wipe/migration boundary the way check-clean runs at the CI boundary.

    WHAT COUNTS AS DISTILLED. A note is distilled when its name appears as a WHOLE
    TOKEN anywhere in any 04-Lessons/*.md note (the canonical home is a lesson's
    `## Source Notes`, but the whole-file scan also counts a name recorded in the
    body). Names are matched with `_` and `-` interchangeable, so kebab auto-memory
    slugs resolve against snake Source-Notes entries and vice-versa.

    WHICH NOTES ARE IN SCOPE. A memory note is feedback/decision when its filename
    stem starts with feedback/decision (kebab or snake) OR its frontmatter `type:`
    (top-level or nested under metadata:) is feedback or decision. project_* and
    reference_* notes are out of scope.

    Windows-native twin of scripts/check-distillation-completeness.sh — same flags,
    same exit codes, same output classes after the Issue 5B bash<->pwsh
    byte-parity normalization.

.PARAMETER MemoryDir
    Path to the harness memory directory. If omitted, derived from
    $env:CLAUDE_CONFIG_DIR (first matching projects/*/memory).

.PARAMETER LessonsDir
    Path to the vault 04-Lessons directory. If omitted, derived from
    $env:OBSIDIAN_VAULT_PATH (joined with 04-Lessons).

.OUTPUTS
    PASS/FAIL lines matching the bash twin's emit shape.

.NOTES
    Exit codes:
        0 — every feedback/decision note is distilled (or none to check)
        1 — one or more feedback/decision notes are not yet distilled
        2 — usage error (missing dir, unresolvable path, bad args)
#>

[CmdletBinding()]
param(
    [string]$MemoryDir = '',
    [string]$LessonsDir = '',
    [Alias('h')][switch]$Help,

    # POSIX-style --memory-dir / --lessons-dir / --help so bash-trained operators
    # get muscle-memory parity with the .sh twin (mirrors check-memory-drift.ps1).
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
        '--memory-dir' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('FAIL --memory-dir requires a value'); exit 2
            }
            $MemoryDir = $Rest[$i + 1]; $i += 2
        }
        '--lessons-dir' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('FAIL --lessons-dir requires a value'); exit 2
            }
            $LessonsDir = $Rest[$i + 1]; $i += 2
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
check-distillation-completeness.ps1 — pre-wipe guard that no feedback/decision
memory note strands undistilled.

Usage:
  check-distillation-completeness.ps1 -MemoryDir <path> -LessonsDir <path>
  check-distillation-completeness.ps1   (derives MemoryDir from CLAUDE_CONFIG_DIR
                                         and LessonsDir from OBSIDIAN_VAULT_PATH)
  check-distillation-completeness.ps1 -Help

Exit codes:
  0 — every feedback/decision note is distilled (or none exist to check)
  1 — one or more feedback/decision notes are not yet distilled
  2 — usage error (missing dir, unresolvable path, bad args)
'@ | Write-Host
}

if ($Help.IsPresent) { Write-Usage; exit 0 }

# Test-FeedbackOrDecision <path> — $true if the note is feedback/decision by
# filename stem OR frontmatter type, else $false.
function Test-FeedbackOrDecision {
    param([Parameter(Mandatory)][string]$Path)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    # Bare word (`feedback`), or word + `-`/`_` separator (`feedback-foo`); the
    # `$` alternative catches the bare stem so it stays parity-identical to the
    # bash `feedback|decision|feedback[-_]*|decision[-_]*` case. `feedbackish` is
    # NOT a match. (A leading UTF-8 BOM is already stripped by ReadAllLines below,
    # so a BOM'd frontmatter-only note is recognized — bash strips it explicitly.)
    if ($stem -cmatch '^(feedback|decision)([-_]|$)') { return $true }
    # First `type:` line inside the frontmatter (top-level or nested under metadata:).
    $lines = [System.IO.File]::ReadAllLines($Path)
    $sawSep = 0
    for ($j = 0; $j -lt $lines.Length; $j++) {
        $ln = $lines[$j]
        if ($j -eq 0 -and $ln -notmatch '^---\s*$') { break }
        if ($ln -match '^---\s*$') { $sawSep++; if ($sawSep -eq 2) { break }; continue }
        if ($sawSep -eq 1 -and $ln -match '^\s*type:\s*') {
            $v = ($ln -replace '^\s*type:\s*', '') -replace '\s*$', ''
            if ($v.ToLower() -in @('feedback', 'decision')) { return $true }
            return $false
        }
    }
    return $false
}

# Resolve the MemoryDir set (mirror bash: explicit flag = exactly one, else
# derive from CLAUDE_CONFIG_DIR). <TEAM>-360: a bare run used to pick
# $candidates[0] when several projects/*/memory dirs existed — every other
# store went silently unscanned, a false-PASS direction for a pre-wipe guard.
# Scan ALL discovered dirs instead.
$MemoryDirs = @()
if (-not [string]::IsNullOrEmpty($MemoryDir)) {
    $MemoryDirs = @($MemoryDir)
} else {
    $configDir = $env:CLAUDE_CONFIG_DIR
    if ([string]::IsNullOrEmpty($configDir)) {
        [Console]::Error.WriteLine('FAIL no --memory-dir given and CLAUDE_CONFIG_DIR unset'); exit 2
    }
    $projectsRoot = Join-Path $configDir 'projects'
    if (Test-Path -LiteralPath $projectsRoot -PathType Container) {
        $MemoryDirs = @(
            Get-ChildItem -LiteralPath $projectsRoot -Directory -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $mem = Join-Path $_.FullName 'memory'
                    if (Test-Path -LiteralPath $mem -PathType Container) { $mem }
                }
        )
    }
    if ($MemoryDirs.Count -eq 0) {
        [Console]::Error.WriteLine("FAIL no memory/ subdir under ${projectsRoot}/*/"); exit 2
    }
    if ($MemoryDirs.Count -gt 1) {
        [Console]::Error.WriteLine("NOTE $($MemoryDirs.Count) memory dirs found; scanning all of them")
    }
}

# Resolve LessonsDir (mirror bash: explicit flag, else derive from OBSIDIAN_VAULT_PATH).
if ([string]::IsNullOrEmpty($LessonsDir)) {
    $vault = $env:OBSIDIAN_VAULT_PATH
    if ([string]::IsNullOrEmpty($vault)) {
        [Console]::Error.WriteLine('FAIL no --lessons-dir given and OBSIDIAN_VAULT_PATH unset'); exit 2
    }
    $LessonsDir = Join-Path $vault '04-Lessons'
}

foreach ($d in $MemoryDirs) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) {
        [Console]::Error.WriteLine("FAIL memory dir does not exist: $d"); exit 2
    }
}
# Space-joined for the summary lines (matches bash "${memory_dirs[*]}").
$MemoryDirsLabel = $MemoryDirs -join ' '
if (-not (Test-Path -LiteralPath $LessonsDir -PathType Container)) {
    [Console]::Error.WriteLine("FAIL lessons dir does not exist: $LessonsDir"); exit 2
}

# Build the normalized Lessons haystack: concatenate every 04-Lessons/*.md, then
# lowercase and fold `_`->`-` so name lookups are separator-insensitive. Split to
# lines so the whole-token match below mirrors the bash per-line grep boundaries.
$lessonsText = (
    Get-ChildItem -LiteralPath $LessonsDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
        ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }
) -join "`n"
$lessonsText = $lessonsText.ToLower().Replace('_', '-')
$lessonsLines = $lessonsText -split "`n"

$checked = 0
$undistilled = 0

Get-ChildItem -LiteralPath $MemoryDirs -Filter '*.md' -File -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object {
        $base = $_.Name
        if ($base -eq 'MEMORY.md') { return }
        if (-not (Test-FeedbackOrDecision -Path $_.FullName)) { return }

        $script:checked++
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($base)
        $norm = $stem.ToLower().Replace('_', '-')
        # Whole-token match: a slug char on either side means we landed inside a
        # longer name (false-PASS risk for a prefix note). Require a non-slug
        # boundary or line edge. [regex]::Escape neutralizes any stray metachar
        # (a normalized slug is [a-z0-9-] only, so it is a no-op in practice).
        $normRe = [regex]::Escape($norm)
        $pattern = "(^|[^a-z0-9-])$normRe([^a-z0-9-]|`$)"
        $found = $false
        foreach ($ln in $lessonsLines) {
            if ($ln -match $pattern) { $found = $true; break }
        }
        if (-not $found) {
            [Console]::Error.WriteLine("FAIL undistilled: $base — not found in any 04-Lessons note; promote it (see capabilities/closeout.md → Distill this session's feedback)")
            $script:undistilled++
        }
    }

if ($undistilled -eq 0) {
    Write-Host "PASS all $checked feedback/decision note(s) distilled into 04-Lessons ($MemoryDirsLabel vs $LessonsDir)"
    exit 0
}

[Console]::Error.WriteLine("FAIL $undistilled of $checked feedback/decision note(s) undistilled in $MemoryDirsLabel")
exit 1
