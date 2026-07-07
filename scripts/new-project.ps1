#Requires -Version 7
<#
.SYNOPSIS
    PowerShell twin of scripts/new-project.sh — scaffold a framework-aware
    project workspace under projects/.

.DESCRIPTION
    The framework ships two project entrypoint templates —
    templates/project-CLAUDE.md (Claude Code) and templates/project-AGENTS.md
    (Codex) — and this script is their tracked consumer: it copies both into a
    fresh projects/<name>/ folder so a session opened there reads a thin,
    project-local entrypoint while the OS spine (session-agent, closeout,
    self-audit, the operating rules) stays shared from the compiled harness
    config. Nothing else is copied — the framework is referenced, not vendored,
    so a `git pull` of framework updates reaches every project at once.

    projects/ is the operator's LOCAL workspace: the tracked .gitignore covers
    it (see the projects/ entry there), so real project work never pollutes the
    framework's tracked tree and never conflicts with framework updates. Each
    scaffolded project can be its own git repo (--git) or a plain working
    folder.

    Windows-native twin of scripts/new-project.sh — same flags, same exit
    codes, same output shape. Arguments are parsed from $args (not a param()
    block) so the bash-style `--git` flag works identically on both twins.

.EXAMPLE
    pwsh -File scripts/new-project.ps1 my-project
.EXAMPLE
    pwsh -File scripts/new-project.ps1 my-project --git
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

$argv = @($args | ForEach-Object { [string]$_ })

$name = if ($argv.Count -ge 1) { $argv[0] } else { '' }
if ([string]::IsNullOrEmpty($name) -or $name.StartsWith('-')) {
    Fail "usage: new-project.ps1 <project-name> [--git]"
}
# One plain folder name only — separators and dot-dirs would scaffold outside
# projects/ (or into nothing nameable) on one platform or the other.
if ($name.Contains('/') -or $name.Contains('\') -or $name -eq '.' -or $name -eq '..') {
    Fail "error: project name must be a plain folder name (got: $name)"
}

# Named initGit to mirror the bash twin's init_git (see the comment there).
$initGit = $false
if ($argv.Count -ge 2) {
    if ($argv.Count -eq 2 -and $argv[1] -eq '--git') {
        $initGit = $true
    }
    else {
        Fail "usage: new-project.ps1 <project-name> [--git]"
    }
}

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $here
$dest     = Join-Path $repoRoot 'projects' $name

# Fail before creating anything if the checkout is missing either template —
# a half-scaffolded project (one entrypoint) orients only one harness.
foreach ($tpl in @('project-CLAUDE.md', 'project-AGENTS.md')) {
    $tplPath = Join-Path $repoRoot 'templates' $tpl
    if (-not (Test-Path -LiteralPath $tplPath -PathType Leaf)) {
        Fail "error: missing template $tplPath (run from a framework checkout)"
    }
}

if (Test-Path -LiteralPath $dest) {
    Fail "error: $dest already exists"
}

New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'templates' 'project-CLAUDE.md') -Destination (Join-Path $dest 'CLAUDE.md')
Copy-Item -LiteralPath (Join-Path $repoRoot 'templates' 'project-AGENTS.md') -Destination (Join-Path $dest 'AGENTS.md')

# Write-Output (not Write-Host) so an in-process caller ($out = & ...) captures
# the same success output an external caller sees — matching the bash twin.
if ($initGit) {
    git -C $dest init -q
    if ($LASTEXITCODE -ne 0) {
        Fail "error: git init failed in $dest"
    }
    Write-Output "initialized git repo in $dest"
}

Write-Output "created project: $dest"
Write-Output "  - CLAUDE.md (Claude Code entrypoint)"
Write-Output "  - AGENTS.md (Codex entrypoint)"
Write-Output ""
Write-Output "next:"
Write-Output "  cd `"$dest`""
Write-Output "  # edit the '## Project context' section, then run: claude   (or: codex)"
