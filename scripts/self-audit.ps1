#Requires -Version 7
<#
.SYNOPSIS
    PowerShell port of self-audit.sh — score the agentic OS on five pillars (0-100 total).

.DESCRIPTION
    <TEAM>-112 — Windows-native twin of scripts/self-audit.sh. Same flags, same
    pillar shape, same JSON/markdown output, same scoring algorithm. Per the
    Issue 5B bash↔pwsh byte-parity contract (after LF-only + path-normalization).

    Read-only diagnostic. Never gates: exits 0 unless a USAGE error.

    Pillars (5 x 20pt = 100pt):
      1. Cross-layer handoffs (Linear/memory/vault linkage)
      2. Memory hygiene (MEMORY.md index, orphans, size, headline-vs-Linear)
      3. Folder hygiene (empty stubs, anti-pattern dirs, lifecycle successors)
      4. Verification coverage (capability <-> recipe linkage, manifest freshness)
      5. Closeout / spine discipline (spine symmetry, recent state-deltas)

.PARAMETER Json
    Emit JSON output instead of markdown.

.PARAMETER Save
    Write the output to this path (in addition to stdout).

.PARAMETER RepoRoot
    Override the repo root used for scans. Defaults to the parent of this script.

.PARAMETER MemoryDir
    Override the memory dir. Defaults to first matching
    $env:CLAUDE_CONFIG_DIR/projects/*/memory.

.PARAMETER VaultDir
    Override the vault dir. Defaults to $env:OBSIDIAN_VAULT_PATH.

.PARAMETER ConfigDir
    Override the harness config dir. Defaults to $env:CLAUDE_CONFIG_DIR.

.PARAMETER Isolated
    Turn off all operator-env fallbacks (env vars + lineark detection). Used
    by tests so fixtures only see what the test sets up.

.NOTES
    Per [[reference_ps_port_traps]] trap #3: all file output uses
    [System.IO.File]::WriteAllText with no-BOM UTF-8 + explicit "`n" join
    so bash↔pwsh byte-parity holds.

    Per [[feedback_powershell_set_content_crlf]]: Set-Content / Out-File
    are avoided for byte-significant output.

    Per [[feedback_ps_port_path_capture_at_precheck]]: external binaries
    (lineark, jq, git) are looked up via Get-Command at call time (matching the
    bash twin's `command -v ... >/dev/null 2>&1` pattern). <TEAM>-180 D2 added a
    local.env read for config resolution, but via Get-SaLocalEnvValue it reads
    ONLY the three config keys (CLAUDE_CONFIG_DIR / OBSIDIAN_VAULT_PATH /
    CLAUDE_PRIMARY_MEMORY_DIR) — never PATH or any other key — so no
    PATH-poisoning window opens. The general Import-LocalEnv (scripts/lib/
    local-env.ps1), which pushes EVERY key into the env, is deliberately NOT used
    here for that reason.
#>

[CmdletBinding()]
param(
    [switch]$Json,
    [string]$Save = '',
    [string]$RepoRoot = '',
    [string]$MemoryDir = '',
    [string]$VaultDir = '',
    [string]$ConfigDir = '',
    [switch]$Isolated,
    [Alias('h')][switch]$Help,

    # Remaining args — POSIX-style --json / --save / --repo-root / --memory-dir /
    # --vault-dir / --config-dir / --isolated / --help so the bash twin's
    # documented CLI surface (scripts/self-audit.sh:49-60) works under
    # bash-trained operator muscle memory. Pattern mirrors install.ps1.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# POSIX-style flag pass through $Rest (mirror bash twin's `while [ $# -gt 0 ]` loop).
$i = 0
while ($i -lt $Rest.Count) {
    $arg = $Rest[$i]
    switch -CaseSensitive ($arg) {
        '--json'       { $Json = [switch]$true; $i += 1 }
        '--isolated'   { $Isolated = [switch]$true; $i += 1 }
        '--save' {
            if ($i + 1 -ge $Rest.Count) { [Console]::Error.WriteLine('self-audit.ps1: --save needs a path'); exit 2 }
            $Save = $Rest[$i + 1]; $i += 2
        }
        '--repo-root' {
            if ($i + 1 -ge $Rest.Count) { [Console]::Error.WriteLine('self-audit.ps1: --repo-root needs a path'); exit 2 }
            $RepoRoot = $Rest[$i + 1]; $i += 2
        }
        '--memory-dir' {
            if ($i + 1 -ge $Rest.Count) { [Console]::Error.WriteLine('self-audit.ps1: --memory-dir needs a path'); exit 2 }
            $MemoryDir = $Rest[$i + 1]; $i += 2
        }
        '--vault-dir' {
            if ($i + 1 -ge $Rest.Count) { [Console]::Error.WriteLine('self-audit.ps1: --vault-dir needs a path'); exit 2 }
            $VaultDir = $Rest[$i + 1]; $i += 2
        }
        '--config-dir' {
            if ($i + 1 -ge $Rest.Count) { [Console]::Error.WriteLine('self-audit.ps1: --config-dir needs a path'); exit 2 }
            $ConfigDir = $Rest[$i + 1]; $i += 2
        }
        '-h'     { $Help = [switch]$true; $i += 1 }
        '--help' { $Help = [switch]$true; $i += 1 }
        default {
            [Console]::Error.WriteLine("self-audit.ps1: unknown argument: $arg")
            exit 2
        }
    }
}

# Initialize $LASTEXITCODE so Strict-Mode-Latest reads don't trip. PS sets it
# only after the first external-command invocation; multiple helpers below
# read+restore it as a transaction wrapper, which Strict-Mode flags if the
# very first call's "read $prev" hits an unset variable.
$global:LASTEXITCODE = 0

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
if ($Help.IsPresent) {
    @'
self-audit.ps1 — score the agentic OS on five pillars (0-100 total).

Usage:
  pwsh -File scripts/self-audit.ps1 [-Json] [-Save <path>]
                                    [-RepoRoot <path>] [-MemoryDir <path>]
                                    [-VaultDir <path>] [-ConfigDir <path>]
                                    [-Isolated]

Read-only diagnostic. Never gates: exits 0 unless a USAGE error.

Pillars (5 x 20pt = 100pt):
  1. Cross-layer handoffs (Linear/memory/vault linkage)
  2. Memory hygiene (MEMORY.md index, orphans, size, headline-vs-Linear)
  3. Folder hygiene (empty stubs, anti-pattern dirs, lifecycle successors)
  4. Verification coverage (capability <-> recipe linkage, manifest freshness)
  5. Closeout / spine discipline (spine symmetry, recent state-deltas)

Default inputs:
  -RepoRoot    parent dir of this script
  -MemoryDir   first matching $env:CLAUDE_CONFIG_DIR/projects/*/memory/ if -ConfigDir
               or $env:CLAUDE_CONFIG_DIR resolves; else skipped
  -VaultDir    $env:OBSIDIAN_VAULT_PATH if set; else skipped
  -ConfigDir   $env:CLAUDE_CONFIG_DIR if set; else skipped

Output: markdown by default. -Json emits a structured object for tests:
  {date, total, pillars{...}, gaps[], skipped[]}
'@ | Write-Host
    exit 0
}

# ---------------------------------------------------------------------------
# Resolve defaults
# ---------------------------------------------------------------------------
if ([string]::IsNullOrEmpty($RepoRoot)) {
    if ($PSScriptRoot) {
        $RepoRoot = Split-Path $PSScriptRoot -Parent
    } else {
        $RepoRoot = (Resolve-Path (Join-Path $PWD '..')).Path
    }
}
# Canonicalize path (no trailing slash, absolute).
if (Test-Path -LiteralPath $RepoRoot -PathType Container) {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
}

# Get-SaLocalEnvValue — read ONE key's value from local.env WITHOUT importing the
# whole file (<TEAM>-180 D2). We deliberately do NOT use scripts/lib/local-env.ps1's
# Import-LocalEnv here: that pushes EVERY key (incl. a hostile PATH=) into the
# process env, and this script resolves lineark/jq/git via Get-Command AFTER this
# point — the exact [[feedback_ps_port_path_capture_at_precheck]] PATH-poisoning
# window. Reading only the three config keys (never PATH) keeps the bash twin's
# `set -a; . local.env` behaviour while preserving the hardened posture. Mirrors
# bash sourcing semantics: a later assignment of the same key wins.
function Get-SaLocalEnvValue {
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
                    # bash %q backslash-escape collapse (parity with lib/local-env.ps1).
                    $v = [System.Text.RegularExpressions.Regex]::Replace($v, '\\(.)', '$1')
                }
            }
            $result = $v  # last assignment wins
        }
    }
    return $result
}

# Select-SaMemoryDir — the operator's PRIMARY memory dir, chosen DETERMINISTICALLY
# (<TEAM>-180 D1). Parity with bash _sa_select_memory_dir: prefer
# $env:CLAUDE_PRIMARY_MEMORY_DIR; else the projects/*/memory dir holding a
# MEMORY.md, ranked by project_*.md count; else most *.md; else the first dir
# (name-sorted). The old `... | Select-Object -First 1` over an unordered
# enumeration scored a near-empty stray dir on a multi-project setup.
function Select-SaMemoryDir {
    param([string]$ConfigDirPath)
    if (-not [string]::IsNullOrEmpty($env:CLAUDE_PRIMARY_MEMORY_DIR) -and
        (Test-Path -LiteralPath $env:CLAUDE_PRIMARY_MEMORY_DIR -PathType Container)) {
        return $env:CLAUDE_PRIMARY_MEMORY_DIR
    }
    $projects = Join-Path $ConfigDirPath 'projects'
    if (-not (Test-Path -LiteralPath $projects -PathType Container)) { return '' }
    $cands = @(Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object {
            $m = Join-Path $_.FullName 'memory'
            if (Test-Path -LiteralPath $m -PathType Container) { $m }
        })
    if ($cands.Count -eq 0) { return '' }
    # 1. prefer dirs with a MEMORY.md, ranked by project_*.md count.
    $withIndex = @($cands | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'MEMORY.md') -PathType Leaf })
    if ($withIndex.Count -gt 0) {
        $best = ''; $bestCount = -1
        foreach ($d in $withIndex) {
            $count = @(Get-ChildItem -LiteralPath $d -Filter 'project_*.md' -File -ErrorAction SilentlyContinue).Count
            if ($count -gt $bestCount) { $bestCount = $count; $best = $d }
        }
        return $best
    }
    # 2. no MEMORY.md anywhere: pick the dir with the most *.md files.
    $best = ''; $bestCount = -1
    foreach ($d in $cands) {
        $count = @(Get-ChildItem -LiteralPath $d -Filter '*.md' -File -ErrorAction SilentlyContinue).Count
        if ($count -gt $bestCount) { $bestCount = $count; $best = $d }
    }
    if ($best -ne '') { return $best }
    # 3. last resort: first (name-sorted) candidate.
    return $cands[0]
}

# -Isolated turns off env-fallbacks (mirror bash ISOLATED=1).
if (-not $Isolated.IsPresent) {
    # <TEAM>-180 D2: read operator config from local.env (the same source the bash
    # twin sources) so the no-flag run is REPRODUCIBLE across shells. local.env
    # wins over ambient env; explicit flags still win over local.env. Only the
    # three config keys are read (never PATH) — see Get-SaLocalEnvValue. This
    # branch is skipped under -Isolated, so fixtures never see operator config.
    $localEnv = Join-Path $RepoRoot 'local.env'
    if (Test-Path -LiteralPath $localEnv -PathType Leaf) {
        if ([string]::IsNullOrEmpty($ConfigDir)) {
            $v = Get-SaLocalEnvValue -Path $localEnv -Key 'CLAUDE_CONFIG_DIR'
            if (-not [string]::IsNullOrEmpty($v)) { $ConfigDir = $v }
        }
        if ([string]::IsNullOrEmpty($VaultDir)) {
            $v = Get-SaLocalEnvValue -Path $localEnv -Key 'OBSIDIAN_VAULT_PATH'
            if (-not [string]::IsNullOrEmpty($v)) { $VaultDir = $v }
        }
        # CLAUDE_PRIMARY_MEMORY_DIR: bash's `set -a; . local.env` makes a
        # local.env pin override ambient env before the selector reads it. Mirror
        # that by setting our own process env var (this specific config key only —
        # never PATH) so Select-SaMemoryDir, which reads $env:CLAUDE_PRIMARY_MEMORY_DIR,
        # honours the local.env pin and it wins over an ambient pin — preserving
        # the flag > local.env > ambient precedence. (Codex <TEAM>-180 review: a
        # parity miss where the PS twin ignored the local.env pin entirely.)
        $v = Get-SaLocalEnvValue -Path $localEnv -Key 'CLAUDE_PRIMARY_MEMORY_DIR'
        if (-not [string]::IsNullOrEmpty($v)) { $env:CLAUDE_PRIMARY_MEMORY_DIR = $v }
    }
    if ([string]::IsNullOrEmpty($ConfigDir) -and -not [string]::IsNullOrEmpty($env:CLAUDE_CONFIG_DIR)) {
        $ConfigDir = $env:CLAUDE_CONFIG_DIR
    }
    if ([string]::IsNullOrEmpty($VaultDir) -and -not [string]::IsNullOrEmpty($env:OBSIDIAN_VAULT_PATH)) {
        $VaultDir = $env:OBSIDIAN_VAULT_PATH
    }
    if ([string]::IsNullOrEmpty($MemoryDir) -and -not [string]::IsNullOrEmpty($ConfigDir)) {
        $sel = Select-SaMemoryDir -ConfigDirPath $ConfigDir
        if (-not [string]::IsNullOrEmpty($sel)) { $MemoryDir = $sel }
    }
}

# ---------------------------------------------------------------------------
# Pillar state — [ordered] hashtable preserves insertion order
# ---------------------------------------------------------------------------
$pillarLabels = [ordered]@{
    'cross-layer-handoffs'       = '1. Cross-layer handoffs'
    'memory-hygiene'             = '2. Memory hygiene'
    'folder-hygiene'             = '3. Folder hygiene'
    'verification-coverage'      = '4. Verification coverage'
    'closeout-spine-discipline'  = '5. Closeout / spine discipline'
}
$pillarScores = [ordered]@{}
$pillarNotes  = [ordered]@{}
foreach ($k in $pillarLabels.Keys) {
    $pillarScores[$k] = 20
    $pillarNotes[$k]  = 'clean'
}

$skipped = New-Object System.Collections.Generic.List[string]
# Each gap entry: [pscustomobject]@{ pillar=<int>; leverage=<int>; title=<str>; detail=<str>; fix=<str> }
$gaps    = New-Object System.Collections.Generic.List[object]

function Add-Skip {
    param([string]$Msg)
    [void]$skipped.Add($Msg)
}

function Add-Gap {
    param(
        [int]$Pillar, [int]$Leverage,
        [string]$Title, [string]$Detail, [string]$Fix
    )
    [void]$gaps.Add([pscustomobject]@{
        pillar   = $Pillar
        leverage = $Leverage
        title    = $Title
        detail   = $Detail
        fix      = $Fix
    })
}

function Use-Deduct {
    # Bash twin name: `deduct`. PS approved verb closest analog: Use- (transition).
    param([string]$Key, [int]$Amount)
    $cur = $pillarScores[$Key]
    $new = $cur - $Amount
    if ($new -lt 0) { $new = 0 }
    $pillarScores[$Key] = $new
}

# ---------------------------------------------------------------------------
# fm_get — first matching frontmatter value, trimmed. Mirrors bash awk parser
# (between first two `---` lines, leading + trailing whitespace strip).
# ---------------------------------------------------------------------------
function Get-FmField {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $lines = [System.IO.File]::ReadAllLines($Path)
    if ($lines.Count -eq 0 -or $lines[0] -ne '---') { return '' }
    $keyPat = '^' + [regex]::Escape($Key) + ':\s*(.*?)\s*$'
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^---\s*$') { break }
        if ($lines[$i] -match $keyPat) {
            return $matches[1]
        }
    }
    return ''
}

# ---------------------------------------------------------------------------
# CLI / git helpers — null-tolerant
# ---------------------------------------------------------------------------
function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Bash twin uses `git -C "$REPO_ROOT" check-ignore -q <rel>` returning 0 if ignored.
function Test-GitIgnored {
    param([string]$RelPath)
    if (-not (Test-Command 'git')) { return $false }
    $prev = $LASTEXITCODE
    & git -C $RepoRoot check-ignore -q $RelPath 2>$null | Out-Null
    $rc = $LASTEXITCODE
    $LASTEXITCODE = $prev
    return ($rc -eq 0)
}

# ---------------------------------------------------------------------------
# Pillar 1 — Cross-layer handoffs
# ---------------------------------------------------------------------------
function Invoke-Pillar1 {
    $key = 'cross-layer-handoffs'

    $linearkAvail = 0
    $memoryAvail  = 0
    $vaultAvail   = 0

    if (-not $Isolated.IsPresent -and (Test-Command 'lineark')) { $linearkAvail = 1 }
    if ((-not [string]::IsNullOrEmpty($MemoryDir)) -and (Test-Path -LiteralPath $MemoryDir -PathType Container)) { $memoryAvail = 1 }
    if ((-not [string]::IsNullOrEmpty($VaultDir))  -and (Test-Path -LiteralPath $VaultDir  -PathType Container)) { $vaultAvail  = 1 }

    if ($linearkAvail -eq 0) { Add-Skip 'lineark not installed — Linear-side cross-layer checks skipped' }
    if ($memoryAvail -eq 0)  { Add-Skip 'memory dir not resolved — memory-side cross-layer checks skipped' }
    if ($vaultAvail -eq 0)   { Add-Skip 'vault dir not configured — vault-side cross-layer checks skipped' }

    # Codex S-4 mirror: jq-missing skip emitted once if lineark is available.
    $needJqWarned = $false
    if ($linearkAvail -eq 1 -and -not (Test-Command 'jq')) {
        Add-Skip 'jq not installed — Linear-side cross-layer checks skipped'
        $needJqWarned = $true
    }

    # Helper: list active+planned Linear project names via lineark.
    # Returns @() on any failure path so the calling code can continue cleanly.
    function _Get-ActiveProjectNames {
        try {
            $projectsJsonLines = & lineark projects list --format json 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $projectsJsonLines) { return @() }
            $projectsJson = if ($projectsJsonLines -is [array]) { ($projectsJsonLines -join "`n") } else { $projectsJsonLines }
            # Try jq first (matches bash); fall back to ConvertFrom-Json.
            if (Test-Command 'jq') {
                $names = $projectsJson | & jq -r '.[] | .name' 2>$null
                if ($LASTEXITCODE -eq 0 -and $names) {
                    if ($names -is [array]) { return @($names | Where-Object { $_ }) }
                    return @($names) | Where-Object { $_ }
                }
            }
            $obj = $projectsJson | ConvertFrom-Json -ErrorAction Stop
            return @($obj | ForEach-Object { $_.name } | Where-Object { $_ })
        } catch {
            return @()
        }
    }

    # Sub-check 1.1 — for each active project, a matching memory file.
    if ($linearkAvail -eq 1 -and $memoryAvail -eq 1 -and (Test-Command 'jq')) {
        foreach ($pname in (_Get-ActiveProjectNames)) {
            if ([string]::IsNullOrEmpty($pname)) { continue }
            $matched = $false
            $candidates = @(Get-ChildItem -LiteralPath $MemoryDir -Filter 'project_*.md' -File -ErrorAction SilentlyContinue)
            foreach ($cand in $candidates) {
                if ([System.IO.File]::ReadAllText($cand.FullName) -like "*$pname*") { $matched = $true; break }
            }
            if (-not $matched) {
                Use-Deduct $key 4
                Add-Gap 1 8 `
                    'No memory file for active Linear project' `
                    "Active project `"$pname`" has no project_*.md in $MemoryDir (active projects should land a memory file at kickoff)" `
                    "Create $MemoryDir/project_<slug>.md with type: project frontmatter linking to the Linear URL"
            }
        }
    }

    # Sub-check 1.2 — for each active project, a matching vault handshake.
    if ($linearkAvail -eq 1 -and $vaultAvail -eq 1 -and (Test-Command 'jq')) {
        $hsRoot = Join-Path $VaultDir '01-Projects'
        foreach ($pname in (_Get-ActiveProjectNames)) {
            if ([string]::IsNullOrEmpty($pname)) { continue }
            $matched = $false
            if (Test-Path -LiteralPath $hsRoot -PathType Container) {
                # Walk recursively (parity with bash `grep -rlF`).
                $hits = @(Get-ChildItem -LiteralPath $hsRoot -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object {
                        try {
                            $txt = [System.IO.File]::ReadAllText($_.FullName)
                            $txt.Contains($pname)
                        } catch { $false }
                    })
                if ($hits.Count -gt 0) { $matched = $true }
            }
            if (-not $matched) {
                Use-Deduct $key 4
                Add-Gap 1 6 `
                    'No vault handshake for active Linear project' `
                    "Active project `"$pname`" has no Handshake note in $VaultDir/01-Projects/" `
                    "Create $VaultDir/01-Projects/<slug>.md with linear: frontmatter pointing to the Linear URL"
            }
        }
    }

    # Sub-check 1.3 — MEMORY.md link integrity.
    $memoryIndex = if (-not [string]::IsNullOrEmpty($MemoryDir)) { Join-Path $MemoryDir 'MEMORY.md' } else { $null }
    if ($memoryAvail -eq 1 -and $memoryIndex -and (Test-Path -LiteralPath $memoryIndex -PathType Leaf)) {
        $broken = 0
        $idxTxt = [System.IO.File]::ReadAllText($memoryIndex)
        $linkMatches = [regex]::Matches($idxTxt, '\]\(([^)]+\.md)(#[^)]*)?\)')
        foreach ($m in $linkMatches) {
            $target = $m.Groups[1].Value
            if ([string]::IsNullOrEmpty($target)) { continue }
            switch -Regex ($target) {
                '^(https?|mailto):' { continue }
                '^/'                { continue }
            }
            $target = ($target -replace '#.*$', '')
            if ([string]::IsNullOrEmpty($target)) { continue }
            $full = Join-Path $MemoryDir $target
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                $broken++
            }
        }
        if ($broken -gt 0) {
            $pen = [Math]::Min($broken * 2, 8)
            Use-Deduct $key $pen
            Add-Gap 1 4 `
                'Broken MEMORY.md link(s)' `
                "MEMORY.md references $broken file(s) that do not exist in $MemoryDir" `
                'Remove the broken index lines or restore the missing memory files'
        }
    }

    # Finalize note.
    $s = $pillarScores[$key]
    if ($s -eq 20) { $pillarNotes[$key] = 'clean' }
    else { $pillarNotes[$key] = "$((20 - $s)) pts deducted; see top gaps" }
}

# ---------------------------------------------------------------------------
# Pillar 2 — Memory hygiene
# ---------------------------------------------------------------------------
function Invoke-Pillar2 {
    $key = 'memory-hygiene'
    if ([string]::IsNullOrEmpty($MemoryDir) -or -not (Test-Path -LiteralPath $MemoryDir -PathType Container)) {
        Add-Skip 'memory dir not resolved — memory hygiene checks skipped'
        $pillarNotes[$key] = 'skipped (no memory dir)'
        return
    }

    $memIndex = Join-Path $MemoryDir 'MEMORY.md'

    # Sub-check 2.1 — orphan check.
    $orphans = 0
    if (Test-Path -LiteralPath $memIndex -PathType Leaf) {
        $indexContent = [System.IO.File]::ReadAllText($memIndex)
        $mdFiles = @(Get-ChildItem -LiteralPath $MemoryDir -Filter '*.md' -File -ErrorAction SilentlyContinue)
        foreach ($mf in $mdFiles) {
            $base = $mf.Name
            if ($base -eq 'MEMORY.md') { continue }
            if (-not $indexContent.Contains($base)) { $orphans++ }
        }
    } else {
        Use-Deduct $key 20
        Add-Gap 2 10 `
            'MEMORY.md index missing' `
            "$MemoryDir/MEMORY.md does not exist; every kickoff orient runs blind" `
            'Create MEMORY.md with one line per memory file per core/memory-model.md'
        $pillarNotes[$key] = 'MEMORY.md missing'
        return
    }

    if ($orphans -gt 0) {
        $pen = [Math]::Min($orphans * 2, 10)
        Use-Deduct $key $pen
        Add-Gap 2 3 `
            'Orphan memory file(s)' `
            "$orphans memory file(s) have no MEMORY.md index entry" `
            'Run /consolidate-memory or hand-add a one-line pointer to MEMORY.md'
    }

    # Sub-check 2.2 — size vs recall cap (~24400 bytes).
    # MEMORY_INDEX_SIZE_CAP_BYTES in core/memory-model.md.
    $sizeBytes = (Get-Item -LiteralPath $memIndex).Length
    if ($sizeBytes -gt 24400) {
        Use-Deduct $key 4
        Add-Gap 2 5 `
            'MEMORY.md over recall cap' `
            "MEMORY.md is $sizeBytes bytes (over the ~24400 recall cap)" `
            'Shorten the longest one-line index entries; move detail into the named topic files'
    }

    # Sub-check 2.3 — per-entry line-length cap (~300 chars). Counts CHARACTERS:
    # .Length is the UTF-16 unit count, which equals the codepoint count for all
    # BMP characters. The bash twin counts codepoints (byte length minus UTF-8
    # continuation bytes), so the two agree for every character a text memory
    # index realistically contains (em-dash, accented Latin, etc.).
    # MEMORY_INDEX_LINE_CAP_CHARS in core/memory-model.md.
    $longLines = 0
    foreach ($ln in [System.IO.File]::ReadAllLines($memIndex)) {
        if ($ln.Length -gt 300) { $longLines++ }
    }
    if ($longLines -gt 0) {
        Use-Deduct $key 4
        Add-Gap 2 5 `
            'MEMORY.md entries over line-length cap' `
            "$longLines index line(s) exceed the ~300-char per-entry cap" `
            'Trim each to a one-line headline; move detail into the named topic file'
    }

    $s = $pillarScores[$key]
    if ($s -eq 20) { $pillarNotes[$key] = 'clean' }
    else { $pillarNotes[$key] = "$((20 - $s)) pts deducted; see top gaps" }
}

# ---------------------------------------------------------------------------
# Pillar 3 — Folder hygiene
# ---------------------------------------------------------------------------
function Invoke-Pillar3 {
    $key = 'folder-hygiene'

    $hasGit = $false
    if (Test-Command 'git') {
        $prev = $LASTEXITCODE
        & git -C $RepoRoot rev-parse --git-dir 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $hasGit = $true }
        $LASTEXITCODE = $prev
    }

    # Sub-check 3.1 — empty dirs (excluding harness worktrees + .git +
    # .install-build.* + anything .gitignore excludes).
    $emptyDirs = New-Object System.Collections.Generic.List[string]
    $allDirs = @(Get-ChildItem -LiteralPath $RepoRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $f = $_.FullName
            # Skip .git/* + harness worktrees + .install-build.* sentinels.
            if ($f -eq (Join-Path $RepoRoot '.git') -or $f.StartsWith((Join-Path $RepoRoot '.git') + [IO.Path]::DirectorySeparatorChar)) { return $false }
            foreach ($h in '.claude', '.codex', '.agents') {
                $wt = Join-Path $RepoRoot $h 'worktrees'
                if ($f -eq $wt -or $f.StartsWith($wt + [IO.Path]::DirectorySeparatorChar)) { return $false }
            }
            if ($_.Name -like '.install-build.*') { return $false }
            return $true
        })
    foreach ($d in $allDirs) {
        $contents = @(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)
        if ($contents.Count -gt 0) { continue }
        $rel = $d.FullName.Substring($RepoRoot.Length).TrimStart([char]'/', [char]'\').Replace([char]'\', [char]'/')
        if ($hasGit -and (Test-GitIgnored $rel)) { continue }
        [void]$emptyDirs.Add($d.FullName)
    }

    if ($emptyDirs.Count -gt 0) {
        $pen = [Math]::Min($emptyDirs.Count * 2, 8)
        Use-Deduct $key $pen
        $sampleRel = $emptyDirs[0].Substring($RepoRoot.Length).TrimStart([char]'/', [char]'\').Replace([char]'\', [char]'/')
        Add-Gap 3 2 `
            'Empty directory(s) in repo' `
            "Found $($emptyDirs.Count) empty dir(s) (e.g. $sampleRel)" `
            "Remove the empty dir, or add a README explaining why it's reserved"
    }

    # Sub-check 3.2 — anti-pattern dir names.
    $antipatterns = @('tmp', 'misc', 'notes', 'scratch', 'junk')
    foreach ($ap in $antipatterns) {
        $hits = @(Get-ChildItem -LiteralPath $RepoRoot -Directory -Recurse -Force -Filter $ap -ErrorAction SilentlyContinue |
            Where-Object {
                $f = $_.FullName
                $gitDir = (Join-Path $RepoRoot '.git') + [IO.Path]::DirectorySeparatorChar
                $nodeMod = (Join-Path $RepoRoot 'node_modules') + [IO.Path]::DirectorySeparatorChar
                $fixDir  = (Join-Path $RepoRoot 'tests' 'fixtures') + [IO.Path]::DirectorySeparatorChar
                if ($f.StartsWith($gitDir) -or $f.StartsWith($nodeMod) -or $f.StartsWith($fixDir)) { return $false }
                return $true
            })
        foreach ($h in $hits) {
            $rel = $h.FullName.Substring($RepoRoot.Length).TrimStart([char]'/', [char]'\').Replace([char]'\', [char]'/')
            if ($hasGit -and (Test-GitIgnored $rel)) { continue }
            Use-Deduct $key 4
            Add-Gap 3 5 `
                'Anti-pattern directory name' `
                "$($h.FullName) uses a name (`"$ap`") that signals undisciplined accretion" `
                'Rename to something meaningful (e.g. "runtime/", "sandbox/") or remove if dead'
        }
    }

    # Sub-check 3.3 — lifecycle: superseded missing successor + sunset missing reason.
    if ($hasGit) {
        $supers = 0
        $sunsetNoWhy = 0
        $tracked = @(& git -C $RepoRoot ls-files 2>$null)
        foreach ($rel in $tracked) {
            if ([string]::IsNullOrEmpty($rel)) { continue }
            $inScope = $false
            switch -Wildcard ($rel) {
                'docs/plans/*.md'                  { $inScope = $true }
                'docs/specs/*.md'                  { $inScope = $true }
                'docs/*/plans/*.md'                { $inScope = $true }
                'docs/*/specs/*.md'                { $inScope = $true }
                'capabilities/*.md'                { $inScope = $true }
                'harnesses/*/capabilities/*.md'    { $inScope = $true }
            }
            if (-not $inScope) { continue }
            $f = Join-Path $RepoRoot $rel
            if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
            $lc = Get-FmField -Path $f -Key 'lifecycle'
            if ($lc -eq 'superseded') {
                $txt = [System.IO.File]::ReadAllText($f)
                if ($txt -notmatch '\[\[[^]]+\]\]|\]\([^)]+\.md\)') { $supers++ }
            } elseif ($lc -eq 'sunset') {
                # Count body words (post-frontmatter).
                $lines = [System.IO.File]::ReadAllLines($f)
                $sepCount = 0
                $bodyWords = 0
                foreach ($l in $lines) {
                    if ($l -match '^---\s*$') { $sepCount++; continue }
                    if ($sepCount -ge 2) {
                        $bodyWords += @(($l -split '\s+') | Where-Object { $_ }).Count
                    }
                }
                if ($bodyWords -lt 20) { $sunsetNoWhy++ }
            }
        }
        if ($supers -gt 0) {
            $pen = [Math]::Min($supers * 2, 6)
            Use-Deduct $key $pen
            Add-Gap 3 3 `
                'Superseded artifact missing successor link' `
                "$supers superseded file(s) have no [[wiki-link]] or markdown-link successor reference in body" `
                "Add a 'Superseded by: [[name]]' or markdown link to each affected file's body"
        }
        if ($sunsetNoWhy -gt 0) {
            $pen = [Math]::Min($sunsetNoWhy * 2, 4)
            Use-Deduct $key $pen
            Add-Gap 3 3 `
                'Sunset artifact without explanation' `
                "$sunsetNoWhy sunset file(s) have <20 words of body explaining why" `
                "Add a brief 'Why sunset' note (~2-3 sentences) per affected file"
        }
    }

    # Sub-check 3.4: a sync-hosted vault must never contain a live `.git`. The
    # durable vault lives on a sync service (Google Drive / iCloud / Dropbox —
    # OBSIDIAN_VAULT_PATH) that races file writes; a live `.git` there corrupts
    # the object store (and Drive sprays .DS_Store into tracked dirs). Vault
    # history, if wanted, belongs in a clone OUTSIDE the synced tree. Gated on
    # $VaultDir being set, so a machine with no configured vault (e.g. CI) is
    # unaffected. Test-Path (no -PathType) catches both a `.git` dir and a `.git`
    # gitlink file. See obsidian/vault-guide.md. Mirrors self-audit.sh.
    if ((-not [string]::IsNullOrEmpty($VaultDir)) -and (Test-Path -LiteralPath (Join-Path $VaultDir '.git'))) {
        Use-Deduct $key 6
        Add-Gap 3 8 `
            'Live .git inside the sync-hosted vault' `
            "$VaultDir/.git exists — a sync service races writes to the git object store (corruption footgun) and sprays .DS_Store into tracked dirs" `
            "Remove the in-vault .git; if you want vault history, keep a clone OUTSIDE the synced path (see obsidian/vault-guide.md)"
    }

    $s = $pillarScores[$key]
    if ($s -eq 20) { $pillarNotes[$key] = 'clean' }
    else { $pillarNotes[$key] = "$((20 - $s)) pts deducted; see top gaps" }
}

# ---------------------------------------------------------------------------
# Pillar 4 — Verification coverage
# ---------------------------------------------------------------------------
function Invoke-Pillar4 {
    $key = 'verification-coverage'

    # Sub-check 4.1 — capability declares verification: <gate> but recipe missing.
    $brokenRefs = 0
    $capDir = Join-Path $RepoRoot 'capabilities'
    if (Test-Path -LiteralPath $capDir -PathType Container) {
        $caps = @(Get-ChildItem -LiteralPath $capDir -Filter '*.md' -File -ErrorAction SilentlyContinue)
        foreach ($cap in $caps) {
            if ([System.IO.Path]::GetFileNameWithoutExtension($cap.Name) -eq 'README') { continue }
            $v = Get-FmField -Path $cap.FullName -Key 'verification'
            if ([string]::IsNullOrEmpty($v) -or $v -eq 'none') { continue }
            $recipe = Join-Path $RepoRoot 'verification' "$v.md"
            if (-not (Test-Path -LiteralPath $recipe -PathType Leaf)) { $brokenRefs++ }
        }
    }
    if ($brokenRefs -gt 0) {
        $pen = [Math]::Min($brokenRefs * 4, 12)
        Use-Deduct $key $pen
        Add-Gap 4 8 `
            'Capability references a missing verification recipe' `
            "$brokenRefs capability/(ies) declare verification: pointing at a non-existent verification/*.md" `
            "Either add the missing recipe or change the capability's verification: value to 'none' or an existing recipe"
    }

    # Sub-check 4.2 — orphan recipes (recipe referenced by no routing surface).
    # <TEAM>-180 D3 (parity with bash): a recipe is "referenced" if its name appears
    # as a whole token in capabilities/, playbooks/, core/, or harnesses/ — the
    # session-agent R3 gate list + playbook/core routing, not only as a
    # `verification:` frontmatter field. The prior frontmatter-only scan
    # false-flagged the recipes routed BY NAME from session-agent R3 + core
    # (~78% false positives). Token boundary [^A-Za-z0-9-] stops a basename
    # matching inside a longer word. (?m) keeps ^/$ line-anchored like the bash
    # `grep -E`. Scans routing dirs only (the recipe's own verification/<base>.md
    # is out of scope), so a recipe named nowhere else still flags — teeth kept.
    # HEURISTIC trade-off (Codex <TEAM>-180 review): an incidental prose mention also
    # counts as a reference; the accepted alternative (requiring backticks /
    # `verification:` shape) would re-flag the BARE-name routing refs in
    # SKILLS.template.md + core/routing.md. The D3b-teeth test pins the
    # named-nowhere case.
    $orphanRecipes = 0
    $verifDir   = Join-Path $RepoRoot 'verification'
    $routingDirs = @('capabilities', 'playbooks', 'core', 'harnesses') |
        ForEach-Object { Join-Path $RepoRoot $_ } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container }
    if (Test-Path -LiteralPath $verifDir -PathType Container) {
        $recipes = @(Get-ChildItem -LiteralPath $verifDir -Filter '*.md' -File -ErrorAction SilentlyContinue)
        foreach ($r in $recipes) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($r.Name)
            if ($base -eq 'README') { continue }
            $pat   = '(?m)(^|[^A-Za-z0-9-])' + [regex]::Escape($base) + '([^A-Za-z0-9-]|$)'
            $found = $false
            foreach ($root in $routingDirs) {
                $mdFiles = @(Get-ChildItem -LiteralPath $root -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue)
                foreach ($mf in $mdFiles) {
                    $txt = [System.IO.File]::ReadAllText($mf.FullName)
                    if ($txt -match $pat) { $found = $true; break }
                }
                if ($found) { break }
            }
            if (-not $found) { $orphanRecipes++ }
        }
    }
    if ($orphanRecipes -gt 0) {
        $pen = [Math]::Min($orphanRecipes * 4, 8)
        Use-Deduct $key $pen
        Add-Gap 4 3 `
            'Orphan verification recipe(s)' `
            "$orphanRecipes recipe(s) in verification/ have no capability declaring them as a gate" `
            "Either wire a capability's verification: to the recipe, or delete the orphan recipe"
    }

    # Sub-check 4.3 — manifest freshness via check-drift.sh.
    # Bash twin shells out to bash check-drift.sh. We use the .sh script
    # (not .ps1) on purpose — both work on the same manifest input, and the
    # bash twin is the authoritative gate. (The Windows full-port lane will
    # use check-drift.ps1 once Issue 5B-d wires runtime selection.)
    if (-not [string]::IsNullOrEmpty($ConfigDir) -and `
        (Test-Path -LiteralPath (Join-Path $ConfigDir '.build-manifest.json') -PathType Leaf) -and `
        (Test-Command 'jq')) {
        $driftScript = Join-Path $RepoRoot 'scripts' 'check-drift.sh'
        if (Test-Path -LiteralPath $driftScript -PathType Leaf) {
            $prev = $LASTEXITCODE
            # Prefer pwsh-native check-drift.ps1 if present; matches the
            # Windows-lane runtime selection that Issue 5B-d will document.
            # Both scripts share manifest semantics; either gives the same
            # verdict on the same manifest input.
            $psDrift = Join-Path $RepoRoot 'scripts' 'check-drift.ps1'
            if (Test-Path -LiteralPath $psDrift -PathType Leaf) {
                & pwsh -NoProfile -File $psDrift -Manifest $ConfigDir *>$null
            } else {
                & bash $driftScript --manifest $ConfigDir *>$null
            }
            $rc = $LASTEXITCODE
            $LASTEXITCODE = $prev
            if ($rc -ne 0) {
                Use-Deduct $key 4
                Add-Gap 4 6 `
                    'Build manifest drift' `
                    "$ConfigDir/.build-manifest.json source hashes do not match current repo source" `
                    'Run: bash scripts/install.sh --harness claude --harness codex (and trust hooks in codex)'
            }
        }
    }

    $s = $pillarScores[$key]
    if ($s -eq 20) { $pillarNotes[$key] = 'clean' }
    else { $pillarNotes[$key] = "$((20 - $s)) pts deducted; see top gaps" }
}

# ---------------------------------------------------------------------------
# Pillar 5 — Closeout / spine discipline
# ---------------------------------------------------------------------------
function Invoke-Pillar5 {
    $key = 'closeout-spine-discipline'

    # Sub-check 5.1 — spine symmetry: every kind: native cap must have a
    # realization under EACH harness it declares in its `harnesses:` frontmatter
    # list. Deriving the harness set from frontmatter (not a hardcoded
    # claude+codex pair) keeps the check honest as harnesses become first-class:
    # a dropped hermes realization deducts exactly like a missing Claude/Codex
    # one. Twin of self-audit.sh sub-check 5.1.
    $nativeCaps  = New-Object System.Collections.Generic.List[string]
    $nativeHlist = @{}   # capability base -> declared-harness string[]
    $capDir = Join-Path $RepoRoot 'capabilities'
    if (Test-Path -LiteralPath $capDir -PathType Container) {
        foreach ($cap in (Get-ChildItem -LiteralPath $capDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($cap.Name)
            if ($base -eq 'README') { continue }
            $kind = Get-FmField -Path $cap.FullName -Key 'kind'
            if ($kind -ne 'native') { continue }
            [void]$nativeCaps.Add($base)
            # `harnesses: [claude, codex, hermes]` -> @('claude','codex','hermes')
            $hraw = Get-FmField -Path $cap.FullName -Key 'harnesses'
            $hlist = @()
            if ($hraw) {
                # Lowercased — twin of self-audit.sh's tr '[:upper:]' '[:lower:]';
                # keeps a capitalized frontmatter value resolving to the lowercase
                # harnesses/<h>/ dir and the bash/PS scores in lockstep.
                $hlist = @(($hraw -replace '[\[\]]', '') -split ',' |
                    ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne '' })
            }
            $nativeHlist[$base] = $hlist
        }
    }

    # Union of declared harnesses, first-seen order.
    $allHarnesses = New-Object System.Collections.Generic.List[string]
    foreach ($name in $nativeCaps) {
        foreach ($h in $nativeHlist[$name]) {
            if (-not $allHarnesses.Contains($h)) { [void]$allHarnesses.Add($h) }
        }
    }

    # Per harness: native caps that DECLARE it but lack the realization file.
    foreach ($h in $allHarnesses) {
        $missingFor = New-Object System.Collections.Generic.List[string]
        foreach ($name in $nativeCaps) {
            if ($nativeHlist[$name] -notcontains $h) { continue }
            $realPath = Join-Path $RepoRoot 'harnesses' $h 'capabilities' "$name.md"
            if (-not (Test-Path -LiteralPath $realPath -PathType Leaf)) { [void]$missingFor.Add($name) }
        }
        if ($missingFor.Count -eq 0) { continue }
        $pen = [Math]::Min($missingFor.Count * 8, 16)
        Use-Deduct $key $pen
        $hname = $h.Substring(0,1).ToUpper() + $h.Substring(1)
        Add-Gap 5 10 `
            "Spine asymmetry: missing $hname realization(s)" `
            "Native capability(s) without harnesses/$h/capabilities/<name>.md: $($missingFor -join ' ')" `
            "Author the $hname realization file(s) and re-run: bash scripts/install.sh --harness $h"
    }

    # Sub-check 5.2 — recent project_*.md (mtime ≤ 7 days) without ## State Deltas.
    if (-not [string]::IsNullOrEmpty($MemoryDir) -and (Test-Path -LiteralPath $MemoryDir -PathType Container)) {
        $missingSd = 0
        $sevenDaysAgo = (Get-Date).AddDays(-7)
        $projectFiles = @(Get-ChildItem -LiteralPath $MemoryDir -Filter 'project_*.md' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $sevenDaysAgo })
        foreach ($pf in $projectFiles) {
            $txt = [System.IO.File]::ReadAllText($pf.FullName)
            if ($txt -notmatch '(?m)^## State Deltas') { $missingSd++ }
        }
        if ($missingSd -gt 0) {
            $pen = [Math]::Min($missingSd * 4, 8)
            Use-Deduct $key $pen
            Add-Gap 5 4 `
                'Recent project memory lacks ## State Deltas' `
                "$missingSd project memory file(s) modified in the last 7 days have no '## State Deltas' section" `
                "Add the section per capabilities/closeout.md output shape, even if the contents are '_none_'"
        }
    }

    $s = $pillarScores[$key]
    if ($s -eq 20) { $pillarNotes[$key] = 'clean' }
    else { $pillarNotes[$key] = "$((20 - $s)) pts deducted; see top gaps" }
}

# ---------------------------------------------------------------------------
# Run all five pillars
# ---------------------------------------------------------------------------
Invoke-Pillar1
Invoke-Pillar2
Invoke-Pillar3
Invoke-Pillar4
Invoke-Pillar5

# ---------------------------------------------------------------------------
# Aggregate
# ---------------------------------------------------------------------------
$total = 0
foreach ($k in $pillarScores.Keys) { $total += $pillarScores[$k] }
$dateStr = [DateTime]::UtcNow.ToString('yyyy-MM-dd')

# ---------------------------------------------------------------------------
# Output emitters
# ---------------------------------------------------------------------------
function Get-MarkdownOutput {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# /self-audit scorecard — $dateStr")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Total: $total/100**")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Pillar | Score | Notes |')
    [void]$sb.AppendLine('| --- | --- | --- |')
    foreach ($k in $pillarLabels.Keys) {
        [void]$sb.AppendLine("| $($pillarLabels[$k]) | $($pillarScores[$k])/20 | $($pillarNotes[$k]) |")
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Top gaps (leverage-weighted)')
    [void]$sb.AppendLine('')
    if ($gaps.Count -eq 0) {
        [void]$sb.AppendLine('_(none)_')
    } else {
        $sorted = @($gaps | Sort-Object -Property leverage -Descending | Select-Object -First 3)
        $n = 1
        foreach ($g in $sorted) {
            [void]$sb.AppendLine("$n. [Pillar $($g.pillar)] $($g.title) (leverage $($g.leverage))")
            [void]$sb.AppendLine("   - Detail: $($g.detail)")
            [void]$sb.AppendLine("   - Fix: $($g.fix)")
            $n++
        }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Skipped surfaces')
    [void]$sb.AppendLine('')
    if ($skipped.Count -eq 0) {
        [void]$sb.AppendLine('_(none — all surfaces configured)_')
    } else {
        foreach ($s in $skipped) {
            [void]$sb.AppendLine("- $s")
        }
    }
    # Bash twin emits via `printf '%s\n' "$OUTPUT"` so output ends with one
    # trailing newline. AppendLine already added per-line newlines; the
    # final state has a trailing `\n` from the last AppendLine. Match bash.
    return $sb.ToString().TrimEnd("`r", "`n")
}

function Get-JsonOutput {
    # Build pillar objects in insertion order; mirrors bash jq output.
    $pillarsObj = [ordered]@{}
    foreach ($k in $pillarLabels.Keys) {
        $pillarsObj[$k] = [ordered]@{
            label = $pillarLabels[$k]
            score = $pillarScores[$k]
            notes = $pillarNotes[$k]
        }
    }
    $sortedGaps = @($gaps | Sort-Object -Property leverage -Descending | ForEach-Object {
        [ordered]@{
            pillar   = $_.pillar
            leverage = $_.leverage
            title    = $_.title
            detail   = $_.detail
            fix      = $_.fix
        }
    })
    $obj = [ordered]@{
        date    = $dateStr
        total   = $total
        pillars = $pillarsObj
        gaps    = $sortedGaps
        skipped = @($skipped)
    }
    return ($obj | ConvertTo-Json -Depth 6)
}

if ($Json.IsPresent) {
    $output = Get-JsonOutput
} else {
    $output = Get-MarkdownOutput
}

# Mirror bash `printf '%s\n' "$OUTPUT"` — append one trailing newline.
Write-Host $output

if (-not [string]::IsNullOrEmpty($Save)) {
    if ([System.IO.Path]::IsPathRooted($Save)) {
        $saveFull = $Save
    } else {
        $saveFull = Join-Path $RepoRoot $Save
    }
    $saveDir = Split-Path $saveFull -Parent
    if (-not [string]::IsNullOrEmpty($saveDir) -and -not (Test-Path -LiteralPath $saveDir -PathType Container)) {
        New-Item -ItemType Directory -Path $saveDir -Force | Out-Null
    }
    # No-BOM UTF-8 + LF-only per [[feedback_powershell_set_content_crlf]].
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($saveFull, $output + "`n", $utf8NoBom)
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("Saved scorecard to $saveFull")
}

exit 0
