#Requires -Version 7
<#
.SYNOPSIS
    PowerShell port of check-memory-drift.sh — flag memory-index health failures
    (headline-vs-body drift + MEMORY.md bloat).

.DESCRIPTION
    Four failure classes:

    1. Headline-vs-body DRIFT in project_*.md files. A project_*.md file has
    DRIFT when its frontmatter description headline claims a closed state
    (COMPLETE / CLOSED / DONE) but its body links to a different `[[project_*]]`
    follow-on AND the description itself does not acknowledge the follow-on. This
    catches the case where a session closed a project and spawned a follow-on,
    updated the body, but never updated the headline / index.

    2. MEMORY.md index BLOAT. When <MemoryDir>/MEMORY.md exists it is
    checked against two caps documented in core/memory-model.md:
    MEMORY_INDEX_SIZE_CAP_BYTES (24400 — the harness truncates recall past this
    size) and MEMORY_INDEX_LINE_CAP_CHARS (300 — index entries are one-line
    headlines). Crossing either cap is a memory-index health failure (same
    exit 1 as drift).

    3. FRONTMATTER PARSER-SAFETY. Each memory note (feedback_/
    reference_/project_/runtime_*.md) is scanned for the silent-corruption class
    a strict YAML parser misreads without raising: a missing/unterminated `---`
    block, or a TOP-LEVEL scalar value with an unquoted ` #` (YAML drops the rest
    as a comment) or `: ` (YAML may read it as a nested mapping). NARROW hazard
    linter — not a YAML parser/normalizer/schema validator. Twin of the bash
    class; see check-memory-drift.sh header for scope + accepted false-negatives.

    4. INJECTION-DEFENSE on agent-written memory. Each note BODY is
    scanned for BARE, LINE-LEADING prompt-injection payloads (role-tag/role-header
    spoofs, ignore/forget/override-instructions, persona flips, future-agent
    targeting, memory-write directives, prompt exfil) an agent might have copied
    verbatim from untrusted output. SKIPS fenced/indented code, blockquotes, and
    inline-code-led lines so a security note can DISCUSS the patterns. Twin of the
    bash awk class; conservative hazard linter, not a parser. Parity: .NET regex
    needs no slash-escape inside a char class (bash awk does), -imatch gives the
    case-insensitivity bash gets from tolower(), and scanning line-by-line over
    ReadAllLines avoids any (?m) need.

    Parity notes (per [[reference_ps_port_traps]]): the filename filter uses
    `-cmatch` (case-sensitive, matching bash `find -name`); .NET `\s` is a
    superset of POSIX `[[:space:]]` but agrees on the ASCII/BMP text a memory
    note realistically contains; ReadAllLines strips `\r` while awk keeps it, but
    both converge after delimiter trailing-whitespace tolerance + value trim.

    <TEAM>-112 — Windows-native twin of scripts/check-memory-drift.sh. Same flags,
    same exit codes, same output classes after normalization (per the Issue 5B
    bash↔pwsh byte-parity contract documented in the public-template-rewrite
    plan).

.PARAMETER MemoryDir
    Path to the memory directory to scan (e.g. $CLAUDE_CONFIG_DIR/projects/<h>/memory).
    If omitted, derived from $env:CLAUDE_CONFIG_DIR (first matching projects/*/memory).

.OUTPUTS
    Markdown-shaped PASS/FAIL/NOTE lines to stdout/stderr matching the bash
    twin's emit shape.

.EXAMPLE
    pwsh -File scripts/check-memory-drift.ps1 -MemoryDir C:\path\to\memory
    pwsh -File scripts/check-memory-drift.ps1                # derives from $env:CLAUDE_CONFIG_DIR

.NOTES
    Exit codes:
        0 — clean (or no project_*.md files / MEMORY.md to inspect)
        1 — drift detected, or MEMORY.md over a documented cap
        2 — usage error (missing dir, bad args)

    Per [[reference_ps_port_traps]] + [[feedback_powershell_set_content_crlf]]:
    output goes through Write-Host / [Console]::Error.WriteLine which emit LF on
    Linux/macOS and CRLF on Windows. The bash↔pwsh parity test normalizes
    line endings before diff (per Issue 5B normalization rules), so the CRLF
    diff is harmless under the documented contract.

    Per [[feedback_ps_port_path_capture_at_precheck]]: this script does not
    import operator local.env, so the PATH-poisoning window does not apply.
    All external binaries (none required) would be captured at precheck
    upstream of any env-import path.
#>

[CmdletBinding()]
param(
    [string]$MemoryDir = '',
    [string]$InjectionScan = '',
    [Alias('h')][switch]$Help,

    # Remaining args — POSIX-style --memory-dir / --help so bash-trained
    # operators get muscle-memory parity with check-memory-drift.sh.
    # Pattern mirrors scripts/install.ps1's POSIX-flag parser.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Caps documented in core/memory-model.md (Per-Harness Memory Index section).
$MEMORY_INDEX_SIZE_CAP_BYTES = 24400
$MEMORY_INDEX_LINE_CAP_CHARS = 300

# POSIX-style flag pass through $Rest (mirror bash twin's `while [ $# -gt 0 ]` loop).
$i = 0
while ($i -lt $Rest.Count) {
    $arg = $Rest[$i]
    switch -CaseSensitive ($arg) {
        '--memory-dir' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('check-memory-drift.ps1: --memory-dir needs a path')
                exit 2
            }
            $MemoryDir = $Rest[$i + 1]
            $i += 2
        }
        '--injection-scan' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('check-memory-drift.ps1: --injection-scan needs a file path')
                exit 2
            }
            $InjectionScan = $Rest[$i + 1]
            $i += 2
        }
        '-h'     { $Help = [switch]$true; $i += 1 }
        '--help' { $Help = [switch]$true; $i += 1 }
        default {
            [Console]::Error.WriteLine("check-memory-drift.ps1: unknown argument: $arg")
            exit 2
        }
    }
}

# ---------------------------------------------------------------------------
# Usage helper
# ---------------------------------------------------------------------------
function Write-Usage {
    @'
check-memory-drift.ps1 — flag headline-vs-body drift in project_*.md memory files.

A project_*.md file has DRIFT when its frontmatter description headline claims
a closed state (COMPLETE / CLOSED / DONE) but its body links to a different
`[[project_*]]` follow-on AND the description itself does not acknowledge the
follow-on. This catches the case where a session closed a project and spawned
a follow-on, updated the body, but never updated the headline / index.

Usage:
  check-memory-drift.ps1 -MemoryDir <path>
  check-memory-drift.ps1                       (derives from CLAUDE_CONFIG_DIR)
  check-memory-drift.ps1 -InjectionScan <file> (scan ONE file's body for injection
                                                payloads; standalone, no -MemoryDir)
  check-memory-drift.ps1 -Help

Exit codes:
  0 — clean (or no project_*.md files to inspect)
  1 — drift detected
  2 — usage error (missing dir, bad args)

This is a textual heuristic check. It does not call out to Linear. A future
enhancement may cross-reference Linear-project status.
'@ | Write-Host
}

if ($Help.IsPresent) {
    Write-Usage
    exit 0
}

# Get-InjectionHit <path> — return the prompt-injection payload class if the file
# carries a BARE, LINE-LEADING directive in a scannable position, else ''. CONSERVATIVE:
# skips fenced/indented code, blockquotes, and inline-code-led lines (those, plus
# Unicode-whitespace-obfuscated and heading-embedded payloads, are ACCEPTED
# false-negatives — it catches the realistic threat: untrusted text pasted VERBATIM as
# a bare line-leading directive). ReadAllLines strips a UTF-8 BOM. FAIL-SAFE body
# boundary (standalone mode has no companion frontmatter-safety check): if the file has
# NO complete frontmatter (< 2 `---` delimiters) the WHOLE file is scanned rather than
# treated as bodyless. The PAYLOAD PATTERN SET (the return chain) is what stays in
# lockstep with the class-4 per-note scan + the check-memory-drift.sh twin; the
# multi-class lockstep test exercises that set through both modes.
function Get-InjectionHit {
    param([Parameter(Mandatory)][string]$Path)
    $allLines = [System.IO.File]::ReadAllLines($Path)
    $seps = 0
    $bodyStart = 0
    for ($i = 0; $i -lt $allLines.Length; $i++) {
        if ($allLines[$i] -match '^---\s*$') { $seps++; if ($seps -eq 2) { $bodyStart = $i + 1 } }
    }
    if ($seps -lt 2) { $bodyStart = 0 }   # no complete frontmatter -> scan whole file
    $fence = $false
    for ($i = $bodyStart; $i -lt $allLines.Length; $i++) {
        $line = $allLines[$i]
        if ($line -match '^\s*(```|~~~)') { $fence = -not $fence; continue }
        if ($fence) { continue }
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\s*>') { continue }
        if ($line.StartsWith("`t")) { continue }
        if ($line.StartsWith('    ')) { continue }
        $m = $line -replace '^[ \t]+', ''
        $m = $m -replace '^([*+\-]|\d+\.)[ \t]+', ''
        $m = $m -replace '^[ \t]+', ''
        if ($m.StartsWith('`')) { continue }
        if     ($m -imatch '^<[/|]?(system|developer|assistant|user)[|]?>')                                        { return 'role-tag' }
        elseif ($m -imatch '^\[?(system|assistant|developer|user)\]?([ \t]+(message|prompt|instructions?))?[ \t]*:') { return 'role-header' }
        elseif ($m -imatch '^(ignore|forget|override|disregard)[ \t]+(all[ \t]+|the[ \t]+)?(previous|prior|above)') { return 'override' }
        elseif ($m -imatch '^do not follow[ \t]+(the[ \t]+)?(previous|prior|above)')                               { return 'override' }
        elseif ($m -imatch '^you are now[ \t]')                                                                    { return 'persona' }
        elseif ($m -imatch '^from now on,?[ \t]+you[ \t]+(are|will|must)')                                         { return 'persona' }
        elseif ($m -imatch '^if you are (an?[ \t]+)?(ai|agent|assistant|llm)[ \t]+reading this')                   { return 'future-agent' }
        elseif ($m -imatch '^when you read this')                                                                  { return 'future-agent' }
        elseif ($m -imatch '^when loaded into context')                                                            { return 'future-agent' }
        elseif ($m -imatch '^(remember this|save this to memory|store this in memory|add this to memory|write this into memory|write this to memory)([ \t]+(forever|permanently|always))?[ \t]*:') { return 'memory-directive' }
        elseif ($m -imatch '^(reveal|print|output|send|exfiltrate|leak).*(system prompt|developer instructions|hidden instructions|hidden prompt|your instructions)') { return 'exfil' }
    }
    return ''
}

# --injection-scan MODE: lint ONE arbitrary file (e.g. a drafted session log) for
# bare line-leading injection payloads before it is written into the durable vault.
# Standalone — no -MemoryDir / CLAUDE_CONFIG_DIR needed. Exit 0 clean, 1 found,
# 2 usage/missing-file.
if (-not [string]::IsNullOrEmpty($InjectionScan)) {
    if (-not (Test-Path -LiteralPath $InjectionScan -PathType Leaf)) {
        [Console]::Error.WriteLine("FAIL --injection-scan: file does not exist: $InjectionScan")
        exit 2
    }
    $injHit = Get-InjectionHit -Path $InjectionScan
    if ($injHit -ne '') {
        $bn = Split-Path -Leaf $InjectionScan
        [Console]::Error.WriteLine("FAIL injection ${bn}: line-leading prompt-injection payload (class: $injHit) — fence/quote it under Raw observations, or remove it (see core/memory-model.md)")
        exit 1
    }
    Write-Host "PASS no injection payloads in $InjectionScan"
    exit 0
}

# ---------------------------------------------------------------------------
# Resolve MemoryDir (mirror bash behavior)
# ---------------------------------------------------------------------------
if ([string]::IsNullOrEmpty($MemoryDir)) {
    $configDir = $env:CLAUDE_CONFIG_DIR
    if ([string]::IsNullOrEmpty($configDir)) {
        [Console]::Error.WriteLine('FAIL no -MemoryDir given and CLAUDE_CONFIG_DIR unset')
        exit 2
    }
    $projectsRoot = Join-Path $configDir 'projects'
    if (-not (Test-Path -LiteralPath $projectsRoot -PathType Container)) {
        [Console]::Error.WriteLine("FAIL no memory/ subdir under ${projectsRoot}/*/")
        exit 2
    }
    $candidates = @(
        Get-ChildItem -LiteralPath $projectsRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $mem = Join-Path $_.FullName 'memory'
                if (Test-Path -LiteralPath $mem -PathType Container) { $mem }
            }
    )
    switch ($candidates.Count) {
        0 {
            [Console]::Error.WriteLine("FAIL no memory/ subdir under ${projectsRoot}/*/")
            exit 2
        }
        1 {
            $MemoryDir = $candidates[0]
        }
        default {
            $MemoryDir = $candidates[0]
            [Console]::Error.WriteLine("NOTE multiple memory dirs found; using $MemoryDir")
        }
    }
}

if (-not (Test-Path -LiteralPath $MemoryDir -PathType Container)) {
    [Console]::Error.WriteLine("FAIL memory dir does not exist: $MemoryDir")
    exit 2
}

# ---------------------------------------------------------------------------
# Frontmatter parsers (mirror bash awk helpers)
# ---------------------------------------------------------------------------

# Get-FmField — return the first matching frontmatter value, trimmed.
# Mirror bash awk parser: read between the first two `---` lines, match key.
function Get-FmField {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key
    )
    $lines = [System.IO.File]::ReadAllLines($Path)
    if ($lines.Count -eq 0) { return '' }
    if ($lines[0] -ne '---') { return '' }
    $keyPat = '^' + [regex]::Escape($Key) + ':\s*(.*)$'
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^---\s*$') { break }
        if ($lines[$i] -match $keyPat) {
            $val = $matches[1]
            # Bash awk strips one optional leading "%QUOTE% and trailing %QUOTE%
            # for description fields. Replicate:
            $val = $val -replace '^"', ''
            $val = $val -replace '"\s*$', ''
            return $val.TrimEnd()
        }
    }
    return ''
}

# Get-FmBody — return the body (everything after the second `---`).
function Get-FmBody {
    param([Parameter(Mandatory)][string]$Path)
    $lines = [System.IO.File]::ReadAllLines($Path)
    if ($lines.Count -eq 0 -or $lines[0] -ne '---') { return '' }
    $sepCount = 0
    $body = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^---\s*$') {
            $sepCount++
            continue
        }
        if ($sepCount -ge 2) {
            [void]$body.Add($lines[$i])
        }
    }
    return ($body -join "`n")
}

# ---------------------------------------------------------------------------
# Main scan loop
# ---------------------------------------------------------------------------

# F-3 port-parity: bash twin uses `drift=0/1` as a BOOLEAN (not a counter), and
# prints `FAIL %s drift(s)` substituting "1" regardless of actual drift count
# (scripts/check-memory-drift.sh:64,127,136). Mirror that exact behavior so
# bash↔pwsh output is byte-identical under the Issue 5B normalization rules.
# The bash quirk is real (says "1" even when N drift files exist) but is a
# separate bash-side bug — see [[feedback_port_parity_vs_regression_split]];
# fixing it here would diverge the two compilers without a coordinated
# bash-side change. Filed as TODO for post-Wave-3 cleanup.
$drift   = 0
$scanned = 0

# Bash side uses `find -maxdepth 1 -type f -name 'project_*.md'`. Mirror with
# -File + -Filter at depth 1.
$projectFiles = @(
    Get-ChildItem -LiteralPath $MemoryDir -Filter 'project_*.md' -File `
        -ErrorAction SilentlyContinue
)

foreach ($f in $projectFiles) {
    $base = $f.Name
    $scanned++

    $description = Get-FmField -Path $f.FullName -Key 'description'
    $ownName     = Get-FmField -Path $f.FullName -Key 'name'

    # Heuristic trigger: headline claims closed state. Case-insensitive
    # alternation matches bash grep -qiE 'COMPLETE|CLOSED|DONE'.
    if ($description -notmatch '(?i)COMPLETE|CLOSED|DONE') {
        continue
    }

    # Exception: if the description ALSO mentions a follow-on / pointer, the
    # headline acknowledges the live state — not drift. Mirror bash regex
    # 'follow-?on|see body|active.*continu|see .?\['.
    if ($description -match '(?i)follow-?on|see body|active.*continu|see .?\[') {
        continue
    }

    # Inspect body for [[project_*]] links to a DIFFERENT project.
    $body = Get-FmBody -Path $f.FullName

    $followon = ''
    # Bash extracts via grep -oE '\[\[project_[A-Za-z0-9_]+(\|[^]]+)?\]\]'
    # then strips to the project_NAME prefix. PS .NET regex equivalent:
    $linkMatches = [regex]::Matches($body, '\[\[(project_[A-Za-z0-9_]+)(\|[^\]]+)?\]\]')
    foreach ($m in $linkMatches) {
        $link = $m.Groups[1].Value
        if ([string]::IsNullOrEmpty($link)) { continue }
        if ($link -eq $ownName) { continue }
        $followon = $link
        break
    }

    if (-not [string]::IsNullOrEmpty($followon)) {
        [Console]::Error.WriteLine(
            "FAIL drift: $base — headline claims closed but body links to follow-on [[$followon]]; description does not acknowledge it"
        )
        $drift = 1
    }
}

# --- <TEAM>-136: MEMORY.md index size + per-entry line-length enforcement. -------
# Mirror the bash twin: when the index file exists, fail if it crosses either
# documented cap. This is the bloat the headline-vs-body staleness check could
# never catch.
$indexFail = 0
$memIndex = Join-Path $MemoryDir 'MEMORY.md'
if (Test-Path -LiteralPath $memIndex -PathType Leaf) {
    $sizeBytes = (Get-Item -LiteralPath $memIndex).Length
    if ($sizeBytes -gt $MEMORY_INDEX_SIZE_CAP_BYTES) {
        [Console]::Error.WriteLine(
            "FAIL MEMORY.md is $sizeBytes bytes — over the ~${MEMORY_INDEX_SIZE_CAP_BYTES}-byte recall cap; the harness truncates recall past this size. Shorten the longest one-line index entries; move detail into the named topic files."
        )
        $indexFail = 1
    }

    # Per-entry line-length: count lines whose CHARACTER length exceeds the cap.
    # ReadAllLines splits on LF/CRLF; .Length is the UTF-16 unit count, which
    # equals the codepoint count for all BMP characters. The bash twin counts
    # codepoints (byte length minus UTF-8 continuation bytes), so the two agree
    # for every character a text memory index realistically contains (em-dash,
    # accented Latin, etc.). Astral-plane codepoints would diverge (2 UTF-16
    # units here vs 1 codepoint in bash) but are out of scope for an index file.
    $longLines = 0
    foreach ($ln in [System.IO.File]::ReadAllLines($memIndex)) {
        if ($ln.Length -gt $MEMORY_INDEX_LINE_CAP_CHARS) { $longLines++ }
    }
    if ($longLines -gt 0) {
        [Console]::Error.WriteLine(
            "FAIL MEMORY.md has $longLines index line(s) over the ~${MEMORY_INDEX_LINE_CAP_CHARS}-char per-entry line-length cap. Trim each to a one-line headline; move detail into the named topic file."
        )
        $indexFail = 1
    }
}

# --- <TEAM>-206: frontmatter parser-safety scan (narrow hazard linter). ----------
# Twin of the bash awk scan. Parity-critical (see .DESCRIPTION parity notes):
# -cmatch for the case-sensitive filename filter; ReadAllLines drops \r (awk keeps
# it, both converge after TrimEnd/Trim); emit byte-identical FAIL strings to the
# bash twin (line-ending normalized by the parity test).
$fmFail = 0
$noteFiles = @(
    Get-ChildItem -LiteralPath $MemoryDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -cmatch '^(feedback|reference|project|runtime)_.*\.md$' }
)

foreach ($nf in $noteFiles) {
    $base = $nf.Name
    $lines = [System.IO.File]::ReadAllLines($nf.FullName)
    $issues = New-Object System.Collections.Generic.List[string]

    # ReadAllLines auto-strips a leading UTF-8 BOM, matching the bash twin's
    # explicit BOM strip — both accept a BOM'd note and scan it normally.
    if ($lines.Count -eq 0 -or $lines[0].TrimEnd() -ne '---') {
        [void]$issues.Add("no-open`t")
    }
    else {
        $closed = $false
        $scalarHazards = New-Object System.Collections.Generic.List[string]
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line.TrimEnd() -eq '---') { $closed = $true; break }
            if ($line -match '^\s*$') { continue }   # blank
            if ($line -match '^\s*#') { continue }   # comment
            if ($line -match '^\s')   { continue }   # nested (indented) value
            if ($line -match '^-\s')  { continue }   # top-level list marker
            if ($line -notmatch ':')  { continue }   # not a mapping line
            $parts = $line -split ':', 2
            $key = $parts[0]
            $val = $parts[1].Trim()
            if ($val -eq '') { continue }            # parent of a nested block
            $c = $val.Substring(0, 1)
            if (@('"', "'", '[', '{', '|', '>') -contains $c) { continue }  # quoted / flow / block scalar
            if ($val -match '\s#')  { [void]$scalarHazards.Add("hash`t$key") }
            if ($val -match ':\s')  { [void]$scalarHazards.Add("colon`t$key") }
        }
        # Unterminated frontmatter: report ONLY the structural failure, suppress
        # the buffered scalar hazards (body text scanned as frontmatter is
        # unreliable). Mirrors the bash twin's END block.
        if (-not $closed) { [void]$issues.Add("no-close`t") }
        else { foreach ($h in $scalarHazards) { [void]$issues.Add($h) } }
    }

    if ($issues.Count -eq 0) { continue }
    $fmFail = 1
    foreach ($iss in $issues) {
        $kp = $iss -split "`t", 2
        $kind = $kp[0]
        $key = $kp[1]
        switch ($kind) {
            'no-open'  { [Console]::Error.WriteLine("FAIL frontmatter ${base}: missing opening --- delimiter line") }
            'no-close' { [Console]::Error.WriteLine("FAIL frontmatter ${base}: frontmatter not closed (no second --- line)") }
            'hash'     { [Console]::Error.WriteLine("FAIL frontmatter ${base}: top-level key ""$key"" value has unquoted "" #"" — quote it (YAML drops everything after a space-#)") }
            'colon'    { [Console]::Error.WriteLine("FAIL frontmatter ${base}: top-level key ""$key"" value has unquoted "": "" — quote it (YAML may read it as a nested mapping)") }
        }
    }
}

# --- <TEAM>-218: injection-defense scan (line-leading payload hazard linter). ----
# Twin of the bash awk scan. Scans each note BODY for BARE, LINE-LEADING
# prompt-injection payloads; SKIPS fenced/indented code, blockquotes, and
# inline-code-led lines (the documented way to DISCUSS the patterns). Same
# conservative pattern set + accepted false-negatives as the bash twin (see
# check-memory-drift.sh header + core/memory-model.md). Emit byte-identical FAIL
# strings to bash (line-ending normalized by the parity test).
$injFail = 0
foreach ($nf in $noteFiles) {
    $base = $nf.Name
    $allLines = [System.IO.File]::ReadAllLines($nf.FullName)
    $sep = 0
    $fence = $false
    $hit = ''
    foreach ($raw in $allLines) {
        if ($raw -match '^---\s*$') { $sep++; continue }
        if ($sep -lt 2) { continue }
        $line = $raw
        if ($line -match '^\s*(```|~~~)') { $fence = -not $fence; continue }  # fenced code toggle
        if ($fence) { continue }
        if ($line -match '^\s*$') { continue }                 # blank
        if ($line -match '^\s*>') { continue }                 # blockquote
        if ($line.StartsWith("`t")) { continue }               # tab-indented code
        if ($line.StartsWith('    ')) { continue }             # 4-space-indented code
        $m = $line -replace '^[ \t]+', ''
        $m = $m -replace '^([*+\-]|\d+\.)[ \t]+', ''           # strip a list marker
        $m = $m -replace '^[ \t]+', ''
        if ($m.StartsWith('`')) { continue }                   # inline-code-led line
        # Token whitespace is ASCII [ \t] (not .NET \s) so this twin matches the
        # bash awk scan exactly; a Unicode-whitespace-obfuscated payload (e.g. NBSP)
        # is an accepted false-negative in BOTH (see core/memory-model.md).
        if     ($m -imatch '^<[/|]?(system|developer|assistant|user)[|]?>')                                        { $hit = 'role-tag' }
        elseif ($m -imatch '^\[?(system|assistant|developer|user)\]?([ \t]+(message|prompt|instructions?))?[ \t]*:') { $hit = 'role-header' }
        elseif ($m -imatch '^(ignore|forget|override|disregard)[ \t]+(all[ \t]+|the[ \t]+)?(previous|prior|above)') { $hit = 'override' }
        elseif ($m -imatch '^do not follow[ \t]+(the[ \t]+)?(previous|prior|above)')                               { $hit = 'override' }
        elseif ($m -imatch '^you are now[ \t]')                                                                    { $hit = 'persona' }
        elseif ($m -imatch '^from now on,?[ \t]+you[ \t]+(are|will|must)')                                         { $hit = 'persona' }
        elseif ($m -imatch '^if you are (an?[ \t]+)?(ai|agent|assistant|llm)[ \t]+reading this')                   { $hit = 'future-agent' }
        elseif ($m -imatch '^when you read this')                                                                  { $hit = 'future-agent' }
        elseif ($m -imatch '^when loaded into context')                                                            { $hit = 'future-agent' }
        elseif ($m -imatch '^(remember this|save this to memory|store this in memory|add this to memory|write this into memory|write this to memory)([ \t]+(forever|permanently|always))?[ \t]*:') { $hit = 'memory-directive' }
        elseif ($m -imatch '^(reveal|print|output|send|exfiltrate|leak).*(system prompt|developer instructions|hidden instructions|hidden prompt|your instructions)') { $hit = 'exfil' }
        if ($hit -ne '') { break }
    }
    if ($hit -ne '') {
        $injFail = 1
        [Console]::Error.WriteLine("FAIL injection ${base}: line-leading prompt-injection payload (class: $hit) — if documenting the pattern, fence or quote it; if real, remove it (see core/memory-model.md)")
    }
}

if ($drift -eq 0 -and $indexFail -eq 0 -and $fmFail -eq 0 -and $injFail -eq 0) {
    Write-Host "PASS no memory headline-vs-body drift; MEMORY.md within caps; frontmatter parser-safe; no injection payloads ($scanned files scanned in $MemoryDir)"
    exit 0
}

if ($drift -ne 0) {
    [Console]::Error.WriteLine("FAIL $drift drift(s) detected in $MemoryDir")
}
exit 1
