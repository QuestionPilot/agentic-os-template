#Requires -Version 7
# scripts/operator-skill-parity-check.ps1 — PowerShell twin of
# scripts/operator-skill-parity-check.sh. Same contract, same output tokens,
# same exit codes.
#
# Why this exists: the build manifest tracks only the framework-managed spine
# skills, so scripts/check-drift.ps1 never looks at a skill the operator copied
# into several render homes by hand — and a presence check (the dir exists in
# every home) cannot see CONTENT. The gap is real and silent: an operator edits
# one home's copy of a skill, the other homes keep serving the stale body, and
# every existing gate stays green because nothing in the tree is being compared.
# This script closes it by diffing the content of every UNMANAGED skill in a
# canonical render home against each mirror render home.
# Hermes uses the Capability Map's machine-readable Skill/Where rows for its
# expected operator-skill subset. Explicit variants compare to their declared
# source pair rather than merely being excused by an allowlist.
#
# Output tokens (byte-parity with the bash twin):
#   SKIP / MISSING / DRIFT / VARIANT / PASS / FAIL — see the bash twin's header.
#
# Configuration (env var first, then local.env read as DATA — never imported):
#   SKILL_PARITY_CANONICAL  canonical skills root. Default <CLAUDE_CONFIG_DIR>/skills.
#   SKILL_PARITY_MIRRORS    comma-separated `<label>=<path>` or bare `<path>`
#                           mirror skills roots. Default: the configured
#                           codex / agents / cursor / hermes render homes +
#                           `/skills` when their homes are configured.
#   SKILL_PARITY_ALLOWLIST  comma-separated `<label>/<skill>` deliberate variants.
#   SKILL_PARITY_CAPABILITY_MAP
#                           Capability Map path. Default:
#                           <OBSIDIAN_VAULT_PATH>/90-Indexes/Capability Map.md.
#                           Required when a Hermes mirror is configured.
#   SKILL_PARITY_VARIANTS   comma-separated explicit
#                           `<target-label>/<skill>=<source-label>/<skill>` pairs.
#                           Targets are case-sensitive and unique. A variant
#                           must match its declared, distinct source.
#
# Managed (spine) skills are excluded automatically, derived from the canonical
# render's `.build-manifest.json`. With no manifest the script prints a NOTE and
# compares everything.
#
# Exit 0 = every mirror in sync or explained. Exit 1 = real drift, a missing
# canonical root, or a run that compared nothing.

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$localEnv = if ($env:AI_CONFIG_LOCAL_ENV) { $env:AI_CONFIG_LOCAL_ENV } else { Join-Path $repoRoot 'local.env' }

# Get-SpLocalEnvValue -Path -Key — read ONE KEY=VALUE from local.env as DATA,
# never imported into the process environment (Import-LocalEnv pushes EVERY key
# into process env; a PATH= line in local.env would then steer resolution).
# Mirrors the bash twin's _sp_localenv_get and check-drift.ps1's
# Get-CdLocalEnvValue: strips an optional `export `, one matching outer quote
# pair, backslash escapes; last assignment wins; no $VAR expansion.
function Get-SpLocalEnvValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $result = ''
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
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

# Get-SpConfig <key> — env var first, then local.env.
function Get-SpConfig {
    param([string]$Key)
    $v = [Environment]::GetEnvironmentVariable($Key)
    if (-not [string]::IsNullOrEmpty($v)) { return $v }
    return (Get-SpLocalEnvValue -Path $localEnv -Key $Key)
}

# Parallel lists, NEVER a whitespace-split string: a render home path routinely
# contains a space, and a split on whitespace silently turns two roots into four
# bogus ones that all "skip" — the check then prints PASS having compared
# nothing. Fail loud, never open.
$mirrorLabels = [System.Collections.Generic.List[string]]::new()
$mirrorPaths  = [System.Collections.Generic.List[string]]::new()

# Add-SpMirrors <csv> — append `<label>=<path>` / bare-`<path>` entries. Comma is
# the only separator, so a path containing a comma cannot be expressed here
# (documented limitation; it lands as unresolvable roots reported as loud SKIPs).
function Add-SpMirrors {
    param([string]$Csv)
    foreach ($raw in $Csv.Split(',')) {
        $item = $raw.Trim()
        if ($item.Length -eq 0) { continue }
        $eq = $item.IndexOf('=')
        if ($eq -ge 0) {
            $label = $item.Substring(0, $eq).Trim()
            $path  = $item.Substring($eq + 1).Trim()
        } else {
            $path  = $item
            $label = (Split-Path (Split-Path $item -Parent) -Leaf)
            if ($label.StartsWith('.', [StringComparison]::Ordinal)) { $label = $label.Substring(1) }
        }
        $mirrorLabels.Add($label)
        $mirrorPaths.Add($path)
    }
}

# Get-SpHermesExpected -MapPath — derive the expected Hermes subset from the
# Capability Map schema. This avoids a second hand-maintained Hermes roster.
function Get-SpHermesExpected {
    param([string]$MapPath)
    $out = [System.Collections.Generic.HashSet[string]]::new()
    $mode = $false
    foreach ($line in [System.IO.File]::ReadAllLines($MapPath)) {
        if (-not $line.TrimStart().StartsWith('|', [StringComparison]::Ordinal)) { $mode = $false; continue }
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        if ($cells.Count -lt 2) { $mode = $false; continue }
        if ($cells[0].Equals('Skill', [StringComparison]::OrdinalIgnoreCase) -and $cells[$cells.Count - 1].Equals('Where', [StringComparison]::OrdinalIgnoreCase)) { $mode = $true; continue }
        if ($cells[0] -match '^:?-{3,}:?$') { continue }
        if (-not $mode) { continue }
        if ($cells[0] -notmatch '^`([^`]+)`$') { continue }
        $name = $matches[1]
        foreach ($token in $cells[$cells.Count - 1].Split(',')) {
            $trimmed = $token.Trim()
            if ($trimmed.Equals('all', [StringComparison]::OrdinalIgnoreCase) -or $trimmed.Equals('hermes', [StringComparison]::OrdinalIgnoreCase)) { [void]$out.Add($name); break }
        }
    }
    return @($out | Sort-Object)
}

# --- canonical root --------------------------------------------------------
$canonical = Get-SpConfig 'SKILL_PARITY_CANONICAL'
if ([string]::IsNullOrEmpty($canonical)) {
    $claudeHome = Get-SpConfig 'CLAUDE_CONFIG_DIR'
    if (-not [string]::IsNullOrEmpty($claudeHome)) { $canonical = Join-Path $claudeHome 'skills' }
}
if ([string]::IsNullOrEmpty($canonical)) {
    [Console]::Error.WriteLine('FAIL no canonical skill root: set SKILL_PARITY_CANONICAL (or CLAUDE_CONFIG_DIR) in local.env')
    exit 1
}
if (-not (Test-Path -LiteralPath $canonical -PathType Container)) {
    [Console]::Error.WriteLine("FAIL canonical skill root missing: $canonical")
    exit 1
}

# --- mirror roots ----------------------------------------------------------
$mirrorsCfg = Get-SpConfig 'SKILL_PARITY_MIRRORS'
if (-not [string]::IsNullOrEmpty($mirrorsCfg)) {
    Add-SpMirrors $mirrorsCfg
} else {
    # Default: the configured render homes other than Claude (the canonical),
    # including Hermes. Hermes's expected subset comes from the Capability Map.
    $defaults = [ordered]@{ codex = 'CODEX_HOME'; agents = 'AGENTS_DIR'; cursor = 'CURSOR_CONFIG_DIR'; hermes = 'HERMES_HOME' }
    foreach ($lbl in $defaults.Keys) {
        $dir = Get-SpConfig $defaults[$lbl]
        if ([string]::IsNullOrEmpty($dir)) { continue }
        $mirrorLabels.Add($lbl)
        $mirrorPaths.Add((Join-Path $dir 'skills'))
    }
}
if ($mirrorLabels.Count -eq 0) {
    [Console]::Error.WriteLine('FAIL no mirror skill root configured — the check would compare nothing')
    exit 1
}

# --- Hermes map-backed subset ----------------------------------------------
$hermesExpected = [System.Collections.Generic.List[string]]::new()
if ($mirrorLabels.Contains('hermes')) {
    $hermesMap = Get-SpConfig 'SKILL_PARITY_CAPABILITY_MAP'
    if ([string]::IsNullOrEmpty($hermesMap)) {
        $vaultDir = Get-SpConfig 'OBSIDIAN_VAULT_PATH'
        if (-not [string]::IsNullOrEmpty($vaultDir)) { $hermesMap = Join-Path $vaultDir '90-Indexes/Capability Map.md' }
    }
    if ([string]::IsNullOrEmpty($hermesMap) -or -not (Test-Path -LiteralPath $hermesMap -PathType Leaf)) {
        [Console]::Error.WriteLine('FAIL Hermes Capability Map missing: set SKILL_PARITY_CAPABILITY_MAP (or OBSIDIAN_VAULT_PATH)')
        exit 1
    }
    foreach ($skill in (Get-SpHermesExpected $hermesMap)) { $hermesExpected.Add($skill) }
    if ($hermesExpected.Count -eq 0) {
        [Console]::Error.WriteLine("FAIL Hermes Capability Map has no expected skills: $hermesMap")
        exit 1
    }
    Write-Host ("NOTE   Hermes expected subset: {0} skill(s) from {1}" -f $hermesExpected.Count, $hermesMap)
}

# --- allowlist -------------------------------------------------------------
$allow = [System.Collections.Generic.HashSet[string]]::new()
$allowCfg = Get-SpConfig 'SKILL_PARITY_ALLOWLIST'
if (-not [string]::IsNullOrEmpty($allowCfg)) {
    foreach ($raw in $allowCfg.Split(',')) {
        $item = $raw.Trim()
        if ($item.Length -gt 0) { [void]$allow.Add($item) }
    }
}

# --- explicit variant pairs -------------------------------------------------
# Use Ordinal keys so the mapping has the same case-sensitive contract as Bash.
$variants = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
$variantCfg = Get-SpConfig 'SKILL_PARITY_VARIANTS'
if (-not [string]::IsNullOrEmpty($variantCfg)) {
    foreach ($raw in $variantCfg.Split(',')) {
        $item = $raw.Trim()
        if ($item.Length -eq 0) { continue }
        $eq = $item.IndexOf('=')
        if ($eq -lt 0) { [Console]::Error.WriteLine("FAIL invalid SKILL_PARITY_VARIANTS entry: $item"); exit 1 }
        $target = $item.Substring(0, $eq).Trim()
        $source = $item.Substring($eq + 1).Trim()
        if ($target -notmatch '^[^/]+/[^/]+$') { [Console]::Error.WriteLine("FAIL invalid variant target: $target"); exit 1 }
        if ($source -notmatch '^[^/]+/[^/]+$') { [Console]::Error.WriteLine("FAIL invalid variant source: $source"); exit 1 }
        if ($target.Equals($source, [StringComparison]::Ordinal)) { [Console]::Error.WriteLine("FAIL variant source matches target: $target"); exit 1 }
        if ($variants.ContainsKey($target)) { [Console]::Error.WriteLine("FAIL duplicate variant target: $target"); exit 1 }
        $variants.Add($target, $source)
    }
}

function Get-SpVariantSourceDir {
    param([string]$Source)
    $parts = $Source.Split('/', 2)
    $sourceLabel = $parts[0]
    $sourceSkill = $parts[1]
    if ($sourceLabel -ceq 'canonical') { return (Join-Path $canonical $sourceSkill) }
    for ($i = 0; $i -lt $mirrorLabels.Count; $i++) {
        if ($mirrorLabels[$i] -ceq $sourceLabel) { return (Join-Path $mirrorPaths[$i] $sourceSkill) }
    }
    return $null
}

# Get-SpPhysicalDir resolves every path component before a variant compare.
# It uses FileSystemInfo.Target, which is available for the declared PowerShell
# 7 baseline; ResolveLinkTarget would require PowerShell 7.2 / .NET 6.
function Get-SpPhysicalDir {
    param([string]$Path, [int]$Depth = 0)
    try {
        if ($Depth -ge 40) { throw 'symbolic-link depth exceeded' }
        $full = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($full)
        $relative = $full.Substring($root.Length)
        $segments = $relative.Split([System.IO.Path]::DirectorySeparatorChar, [System.StringSplitOptions]::RemoveEmptyEntries)
        $current = $root
        foreach ($segment in $segments) {
            $item = Get-Item -LiteralPath (Join-Path $current $segment) -Force -ErrorAction Stop
            if ($null -ne $item.Target -and $item.Target.Count -gt 0) {
                $target = @($item.Target)[0]
                $targetPath = if ([System.IO.Path]::IsPathRooted($target)) {
                    $target
                } else {
                    $parent = Split-Path $item.FullName -Parent
                    if ([string]::IsNullOrEmpty($parent)) { $parent = [System.IO.Path]::GetPathRoot($item.FullName) }
                    Join-Path $parent $target
                }
                $current = Get-SpPhysicalDir -Path $targetPath -Depth ($Depth + 1)
            } else {
                $current = $item.FullName
            }
        }
        return $current
    } catch {
        return $null
    }
}

# --- managed (spine) skills, derived from the canonical render's manifest ----
$managed = [System.Collections.Generic.HashSet[string]]::new()
$manifest = Join-Path (Split-Path $canonical -Parent) '.build-manifest.json'
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    Write-Host "NOTE   no build manifest at $manifest — comparing every skill dir"
} else {
    $parsed = $null
    try { $parsed = (Get-Content -LiteralPath $manifest -Raw) | ConvertFrom-Json } catch { $parsed = $null }
    if ($null -eq $parsed -or $null -eq $parsed.generated) {
        Write-Host "NOTE   unreadable build manifest at $manifest — comparing every skill dir"
    } else {
        foreach ($k in $parsed.generated.PSObject.Properties.Name) {
            if ($k.StartsWith('skills/', [StringComparison]::Ordinal)) {
                [void]$managed.Add($k.Substring(7).Split('/')[0])
            }
        }
    }
}

# Test-SpTreeEqual — recursive content equality, mirroring the bash twin's
# `diff -r -q --exclude=.DS_Store --exclude=__pycache__`: same relative file set
# and same bytes for every file.
function Test-SpTreeEqual {
    param([string]$A, [string]$B)
    $mapA = Get-SpTreeMap $A
    $mapB = Get-SpTreeMap $B
    if ($mapA.Count -ne $mapB.Count) { return $false }
    foreach ($rel in $mapA.Keys) {
        if (-not $mapB.ContainsKey($rel)) { return $false }
        if ($mapA[$rel] -ne $mapB[$rel]) { return $false }
    }
    return $true
}

# Get-SpTreeMap — { relative-path (forward slashes) -> SHA256 } for one tree.
function Get-SpTreeMap {
    param([string]$Root)
    $map = @{}
    $full = (Resolve-Path -LiteralPath $Root).Path
    foreach ($f in (Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -eq '.DS_Store') { continue }
        $rel = $f.FullName.Substring($full.Length).TrimStart('\', '/').Replace('\', '/')
        if ($rel -like '*__pycache__/*') { continue }
        $map[$rel] = (Get-FileHash -Algorithm SHA256 -LiteralPath $f.FullName).Hash
    }
    return $map
}

# --- compare ---------------------------------------------------------------
$rc = 0
$checked = 0
$rootsCompared = 0
for ($i = 0; $i -lt $mirrorLabels.Count; $i++) {
    $label = $mirrorLabels[$i]
    $root  = $mirrorPaths[$i]
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Write-Host ("SKIP   {0,-8} root not present ({1})" -f $label, $root)
        if ($label -ceq 'hermes') {
            [Console]::Error.WriteLine("FAIL Hermes skill root missing: $root")
            $rc = 1
        }
        continue
    }
    $rootsCompared++
    if ($label -ceq 'hermes') {
        $compareSkills = @($hermesExpected)
    } else {
        $compareSkills = @(Get-ChildItem -LiteralPath $canonical -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.Name })
    }
    foreach ($skill in $compareSkills) {
        if ($managed.Contains($skill)) { continue }
        $checked++
        $d = Join-Path $canonical $skill
        if (-not (Test-Path -LiteralPath $d -PathType Container)) {
            Write-Host ("MISSING canonical {0}" -f $skill)
            $rc = 1
            continue
        }
        $mirrorSkill = Join-Path $root $skill
        if (-not (Test-Path -LiteralPath $mirrorSkill -PathType Container)) {
            Write-Host ("MISSING {0,-8} {1}" -f $label, $skill)
            $rc = 1
            continue
        }
        $target = "$label/$skill"
        if ($variants.ContainsKey($target)) {
            $source = $variants[$target]
            $sourceDir = Get-SpVariantSourceDir $source
            if ([string]::IsNullOrEmpty($sourceDir) -or -not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
                [Console]::Error.WriteLine("FAIL variant source missing: $source")
                $rc = 1
                continue
            }
            $sourcePhysical = Get-SpPhysicalDir $sourceDir
            $targetPhysical = Get-SpPhysicalDir $mirrorSkill
            $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
            if ([string]::IsNullOrEmpty($sourcePhysical) -or [string]::IsNullOrEmpty($targetPhysical) -or
                $sourcePhysical.Equals($targetPhysical, $pathComparison)) {
                [Console]::Error.WriteLine("FAIL variant source aliases target: $target = $source")
                $rc = 1
                continue
            }
            if (Test-SpTreeEqual $sourceDir $mirrorSkill) {
                Write-Host ("VARIANT {0,-8} {1} (matched {2})" -f $label, $skill, $source)
            } else {
                Write-Host ("DRIFT   {0,-8} {1} (expected {2})" -f $label, $skill, $source)
                $rc = 1
            }
            continue
        }
        if (Test-SpTreeEqual $d $mirrorSkill) { continue }
        if ($allow.Contains("$label/$skill")) {
            Write-Host ("VARIANT {0,-8} {1} (allowlisted)" -f $label, $skill)
        } else {
            Write-Host ("DRIFT   {0,-8} {1}" -f $label, $skill)
            $rc = 1
        }
    }
}

if ($rootsCompared -eq 0) {
    [Console]::Error.WriteLine('FAIL no mirror root was present — the check compared nothing')
    exit 1
}
if ($checked -eq 0) {
    Write-Host 'SKIP   no unmanaged skills to compare'
    exit $rc
}

if ($rc -eq 0) {
    Write-Host ("PASS operator-skill parity: {0} comparison(s) across {1} of {2} mirror root(s), no unexplained drift" -f `
        $checked, $rootsCompared, $mirrorLabels.Count)
} else {
    [Console]::Error.WriteLine("FAIL operator-skill parity drift — sync from $canonical deliberately, or allowlist a real variant")
}
exit $rc
