#Requires -Version 7
<#
.SYNOPSIS
    check-project-note-budget.ps1 — per-note BODY budget gate for `type: project`
    memory notes. Fails CLOSED on a project-type note whose file size exceeds the
    budget. PowerShell twin of scripts/check-project-note-budget.sh.

.DESCRIPTION
    WHY THIS EXISTS. A project-type note is the body a kickoff orient
    dereferences, every session. The self-audit already MEASURES the same budget
    (its memory-hygiene sub-check 2.6) — but that is a 2-point advisory warn an
    operator reads after the fact, and the note that keeps growing is precisely
    the one closeout writes to. Measuring at audit time and never at write time
    is how a store grows a 30 KB arc note nobody trimmed: the growth happens in
    closeout, the warning arrives somewhere else. This check runs INSIDE the
    closeout pre-write gate, so the session that would add to an already-oversize
    note is the session told to trim it.

    WHAT COUNTS AS A PROJECT NOTE — the frontmatter `type:`, not a filename
    glob. Scoped to the first `---`-fenced block, lowercased, one surrounding
    quote pair stripped, matched case-SENSITIVELY (-cmatch / -creplace: the bash
    twin's awk is case-sensitive, so a case-insensitive PS regex would classify
    a `Type:` note the other shell ignores). WHICH `type:` wins is load-bearing:
    a frontmatter block can carry several `type:` keys under different parents
    (`source:` provenance blocks are the common case), so "the first `type:` at
    any indent" reads the WRONG one — a note whose `source:` names
    `type: project` above its real `metadata: type: reference` was classified
    project. The rules:
      0. the block must CLOSE (a second `---`); an unclosed opening fence is not
         frontmatter at all, so a body line `type: project` classifies nothing;
      1. a `type:` nested as a DIRECT child of the top-level `metadata:` key
         wins — direct meaning at the first indentation level seen inside that
         block, so `metadata: source: type: …` belongs to `source:`, not to the
         note;
      2. else a TOP-LEVEL `type:` (column 0);
      3. a `type:` nested under any OTHER key is ignored entirely.
    `MEMORY.md` matching is case-SENSITIVE (-ceq) to match the bash twin's
    shell compare; whether a file NAMED `memory.MD` even reaches the scan is the
    host filesystem's business (a case-insensitive volume folds it), so that half
    is not asserted anywhere.

    `node_type:` is not matched (the key is compared whole). The same detector
    scripts/self-audit.ps1 uses (its Get-MemNoteType), so the write-time gate and
    the audit can never disagree about which notes are in scope. `MEMORY.md` is
    the index, never a note, and is always excluded.

    WHAT IS MEASURED. The file's byte size, against <cap> * 1024. The cap is the
    same knob the self-audit reads, resolved by the same precedence:

      1. -WarnKb <n>                          (explicit caller intent)
      2. PROJECT_NOTE_BODY_WARN_KB in repo-root local.env, read as DATA — never
         imported ($env:AI_CONFIG_LOCAL_ENV overrides the file path, the fixture
         convention shared with check-drift.ps1 / closeout-gate.ps1)
      3. $env:PROJECT_NOTE_BODY_WARN_KB in the ambient environment
      4. 16

    A cap value that is not a positive integer, or is longer than 7 digits,
    falls back to the default SILENTLY — mirroring self-audit. The digit bound
    is load-bearing on the bash side, where the KB*1024 product is 64-bit signed
    arithmetic that a huge value wraps to 0; the twin applies the same bound so
    both shells accept and reject exactly the same knob values. Leading zeros are
    normalized to base 10 in both shells — [int] here, `10#` there — because bash
    reads a leading-zero literal as OCTAL (`08` is an arithmetic error, `0000016`
    means 14). The NORMALIZED value is what every message echoes.

    SURFACE CONTRACT, matching scripts/closeout-gate.ps1's:
      - No -MemoryDir given at all  -> named SKIP, exit 0. There is no
        project-note surface to scan; a real, benign configuration (a fresh
        public clone), not a broken gate.
      - -MemoryDir given but the directory does not exist, or exists and cannot
        be enumerated -> FAIL. A configured store that is not there, or cannot
        be opened, is a misspelled / unsynced / permission-broken path, and
        scanning nothing while reporting clean is the fail-open case this
        closes. A NOTE that cannot be read fails the same way, checked before
        the type filter: an unreadable file classifies as "no type" and would
        otherwise drop out of the scan indistinguishable from a reference note,
        when it may be the oversize project note this check exists to catch.

    Windows-native twin of scripts/check-project-note-budget.sh — same flags,
    same exit codes, same output classes after the bash<->pwsh byte-parity
    normalization.

.PARAMETER MemoryDir
    Memory store(s) to scan. Repeatable (POSIX `--memory-dir <dir>` too).

.PARAMETER WarnKb
    Per-note budget in KB. Overrides every other cap source.

.NOTES
    Exit codes:
        0 — every scanned project-type note is within budget (a skip does not fail)
        1 — at least one note is over budget, or a given memory dir or note
            could not be read
        2 — usage error (bad args)

    Tests: tests/project-note-budget.test.ps1 (+ the .sh twin), and the
    project-note-budget check in tests/closeout-gate.test.ps1.
#>

[CmdletBinding()]
param(
    [string[]]$MemoryDir = @(),
    [string]$WarnKb = '',
    [Alias('h')][switch]$Help,

    # POSIX-style --memory-dir / --warn-kb / --help so bash-trained operators get
    # muscle-memory parity with the .sh twin (mirrors check-machine-paths.ps1).
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# An EXPLICIT empty value is a usage error, never a fallback. Silently dropping
# it would turn `-MemoryDir $someUnsetVar` into the named SKIP — a caller that
# believed it pinned a store gets a clean run over nothing, which is precisely
# the fail-open shape this check exists to close.
$dirs = [System.Collections.Generic.List[string]]::new()
foreach ($d in $MemoryDir) {
    if ([string]::IsNullOrEmpty($d)) {
        [Console]::Error.WriteLine('FAIL --memory-dir requires a non-empty value'); exit 2
    }
    $dirs.Add($d)
}

$i = 0
while ($i -lt $Rest.Count) {
    $arg = $Rest[$i]
    switch -CaseSensitive ($arg) {
        '--memory-dir' {
            if ($i + 1 -ge $Rest.Count) { [Console]::Error.WriteLine('FAIL --memory-dir requires a value'); exit 2 }
            if ([string]::IsNullOrEmpty($Rest[$i + 1])) {
                [Console]::Error.WriteLine('FAIL --memory-dir requires a non-empty value'); exit 2
            }
            $dirs.Add($Rest[$i + 1]); $i += 2
        }
        '--warn-kb' {
            if ($i + 1 -ge $Rest.Count) { [Console]::Error.WriteLine('FAIL --warn-kb requires a value'); exit 2 }
            $WarnKb = $Rest[$i + 1]; $i += 2
        }
        '-h'     { $Help = [switch]$true; $i += 1 }
        '--help' { $Help = [switch]$true; $i += 1 }
        default  { [Console]::Error.WriteLine("FAIL unknown arg: $arg"); exit 2 }
    }
}

function Write-Usage {
    @'
check-project-note-budget.ps1 — per-note BODY budget gate for `type: project`
memory notes (fail closed), run inside the closeout pre-write gate.

Usage:
  check-project-note-budget.ps1 [--memory-dir <dir>]... [--warn-kb <n>]
  check-project-note-budget.ps1 --help

Exit codes:
  0 — every scanned project-type note is within budget (a skip does not fail)
  1 — at least one note is over budget, or a given memory dir does not exist
  2 — usage error (bad args)
'@ | Write-Host
}

if ($Help.IsPresent) { Write-Usage; exit 0 }

$selfDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# Get-PnbLocalEnvValue -Path -Key — read ONE KEY=VALUE from local.env as DATA,
# never imported into the process environment. Same parser as
# closeout-gate.ps1's Get-CgLocalEnvValue: strips an optional `export `, one
# matching outer quote pair, backslash escapes; last assignment wins; no $VAR
# expansion.
function Get-PnbLocalEnvValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    # An unreadable (locked / access-denied) file degrades to "no value" like
    # the bash twin's failed open, rather than crashing under Stop.
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

# Get-PnbTypeValue — the value half of a `type:` line: leading key stripped
# case-SENSITIVELY, trimmed, an inline YAML comment removed, one surrounding
# quote pair unwrapped (so `type: "project"` classifies as project, else a valid
# quoted note goes invisible), lowercased.
function Get-PnbTypeValue {
    param([string]$Line)
    $v = ($Line -creplace '^\s*type:\s*', '').Trim()
    # QUOTED values are unwrapped by finding the CLOSING quote rather than by
    # comparing the last character: `type: "project" # active arc` has a comment
    # after the pair (so a last-character compare sees `c`, not `"`, and gives
    # back the whole line), and a `#` INSIDE the quotes is literal, not a comment.
    # Finding the close quote settles both.
    if ($v.Length -ge 1) {
        $q = $v[0]
        if ($q -eq '"' -or $q -eq "'") {
            $i = $v.IndexOf($q, 1)
            if ($i -ge 1) { return $v.Substring(1, $i - 1).ToLowerInvariant() }
            # No closing quote — not a quoted scalar; fall through.
        }
    }
    # UNQUOTED: everything from a `#` that FOLLOWS whitespace is a YAML comment;
    # `a#b` with no space keeps its hash.
    $v = ($v -creplace '\s+#.*$', '').TrimEnd()
    return $v.ToLowerInvariant()
}

# Get-PnbNoteType — the note's memory type from frontmatter. Identical to
# scripts/self-audit.ps1's Get-MemNoteType; see .DESCRIPTION for the
# metadata-first nesting rule and why it is load-bearing.
function Get-PnbNoteType {
    param([Parameter(Mandatory)][string]$Path)
    try { $lines = [System.IO.File]::ReadAllLines($Path) } catch { return '' }
    if ($lines.Count -eq 0) { return '' }
    $first = $lines[0]
    if ($first.Length -ge 1 -and $first[0] -eq [char]0xFEFF) { $first = $first.Substring(1) }
    if ($first.TrimEnd() -ne '---') { return '' }
    $meta = ''; $top = ''; $cur = ''; $metaIndent = -1; $closed = $false
    for ($j = 1; $j -lt $lines.Count; $j++) {
        $ln = $lines[$j]
        if ($ln.TrimEnd() -eq '---') { $closed = $true; break }
        # A column-0 `<key>:` opens a top-level block. `type:` at column 0 IS the
        # top-level type; any other key becomes the block an indented `type:`
        # would belong to.
        if ($ln -cmatch '^([A-Za-z0-9_.-]+):') {
            if ($matches[1] -ceq 'type') {
                if ($top -eq '') { $top = Get-PnbTypeValue $ln }
                $cur = ''
            } else {
                $cur = $matches[1]
                if ($cur -ceq 'metadata') { $metaIndent = -1 }
            }
            continue
        }
        # An INDENTED `type:` counts only as a DIRECT child of `metadata:` — the
        # first indentation level seen inside that block. A deeper `type:`
        # belongs to a sub-key (`metadata: source: type: …`), not to the note.
        if ($cur -ceq 'metadata' -and $ln -cmatch '^(\s+)[A-Za-z0-9_.-]+:') {
            $w = $matches[1].Length
            if ($metaIndent -lt 0) { $metaIndent = $w }
            if ($w -eq $metaIndent -and $ln -cmatch '^\s+type:') {
                if ($meta -eq '') { $meta = Get-PnbTypeValue $ln }
            }
        }
    }
    # An UNCLOSED block is not frontmatter at all: without a second fence the
    # whole file is body, and a body line `type: project` must not classify the
    # note. Only a closed block yields a type.
    if (-not $closed) { return '' }
    if ($meta -ne '') { return $meta }
    return $top
}

# Cap precedence: flag > local.env (as DATA) > ambient env > default.
if ([string]::IsNullOrEmpty($WarnKb)) {
    $pnbLocalEnv = if ($env:AI_CONFIG_LOCAL_ENV) { $env:AI_CONFIG_LOCAL_ENV } else { Join-Path (Split-Path -Parent $selfDir) 'local.env' }
    $WarnKb = Get-PnbLocalEnvValue -Path $pnbLocalEnv -Key 'PROJECT_NOTE_BODY_WARN_KB'
}
if ([string]::IsNullOrEmpty($WarnKb)) {
    $ambient = [Environment]::GetEnvironmentVariable('PROJECT_NOTE_BODY_WARN_KB')
    if (-not [string]::IsNullOrEmpty($ambient)) { $WarnKb = $ambient }
}
# An unusable knob degrades to the default silently (see .DESCRIPTION).
$capKb = 16
if ($WarnKb -match '^[0-9]+$' -and $WarnKb.Length -le 7) {
    $parsed = [int]$WarnKb
    if ($parsed -gt 0) { $capKb = $parsed }
}
$capBytes = $capKb * 1024

# No surface at all is an inapplicable check, not a silent pass: say so, with
# the denominator, so a zero-scan run can never be mistaken for a clean one.
if ($dirs.Count -eq 0) {
    Write-Host 'SKIP no --memory-dir given — no project-note surface to scan (scanned 0 project note(s) in 0 dir(s))'
    exit 0
}

$over = 0
$badDirs = 0
$unreadable = 0
$scanned = 0
$dirsOk = 0

foreach ($d in $dirs) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) {
        # A CONFIGURED store that is not there fails: scanning nothing and
        # reporting clean is exactly the fail-open hole this gate closes.
        Write-Host "FAIL memory dir not found: $d"
        $badDirs++
        continue
    }
    # A store that EXISTS but cannot be enumerated is the same hole wearing a
    # different hat: the run reported `scanned 0` and PASSed over a store it
    # never opened. The probe is a .NET call, NOT Get-ChildItem: even under
    # -ErrorAction Stop, Get-ChildItem on an unsearchable directory returns an
    # empty set WITHOUT throwing (measured on this platform), so a try/catch
    # around it would have looked like a fix while still failing open.
    try { [void][System.IO.Directory]::GetFileSystemEntries($d) } catch {
        Write-Host "FAIL memory dir not readable: $d"
        $badDirs++
        continue
    }
    # Name-sorted, ordinal — the bash twin pipes find through `sort` under
    # LC_ALL=C, so both shells report findings in the same order.
    $files = @(Get-ChildItem -LiteralPath $d -File -Filter '*.md' -ErrorAction SilentlyContinue |
        Sort-Object -Property Name -CaseSensitive)
    $dirsOk++
    foreach ($f in $files) {
        # -ceq, not -eq: the bash twin compares with `=` in the shell, which is
        # case-sensitive, so a case-INSENSITIVE compare here would exclude a note
        # literally named `memory.md` that the other shell scans. Whether such a
        # file can exist alongside MEMORY.md at all is the host filesystem's
        # business (a case-insensitive volume folds them), so only the comparison
        # is pinned — see .DESCRIPTION.
        if ($f.Name -ceq 'MEMORY.md') { continue }
        # Readability is checked BEFORE the type filter, deliberately. An
        # unreadable note classifies as "no type" and would drop out of the scan
        # silently — indistinguishable from a reference note, when it may be the
        # oversize project note this check exists to catch. We cannot know, so
        # we fail.
        try { $probe = [System.IO.File]::OpenRead($f.FullName); $probe.Close() } catch {
            Write-Host "FAIL memory note not readable: $($f.FullName)"
            $unreadable++
            continue
        }
        if ((Get-PnbNoteType -Path $f.FullName) -ne 'project') { continue }
        $scanned++
        $b = $f.Length
        if ($b -gt $capBytes) {
            Write-Host "FAIL project note over budget: $($f.FullName) ($b B > $capKb KB) — trim per capabilities/closeout.md memory-hygiene rule 4"
            $over++
        }
    }
}

# The denominator, always — a check that reports PASS without saying how many
# notes it actually measured is indistinguishable from one that measured none.
Write-Host "scanned $scanned project note(s) in $dirsOk dir(s) against a $capKb KB budget"

if ($over -gt 0 -or $badDirs -gt 0 -or $unreadable -gt 0) {
    Write-Host "FAIL $over note(s) over the $capKb KB budget, $badDirs memory dir(s) unusable, $unreadable note(s) unreadable — trim, or raise PROJECT_NOTE_BODY_WARN_KB if the size is deliberate"
    exit 1
}

Write-Host "PASS every project-type note is within the $capKb KB budget"
exit 0
