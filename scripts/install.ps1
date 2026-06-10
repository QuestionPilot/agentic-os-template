#Requires -Version 7
<#
.SYNOPSIS
    Windows-native compiler — compiles capabilities/ + a harness adapter into harness-native output.

.DESCRIPTION
    install.ps1 — Windows-native twin of scripts/install.sh (<TEAM>-100 prototype).

    Usage: pwsh scripts/install.ps1 [-Harness <name>] [--harness <name>]... [-Out <dir>] [-BuildOnly]

    -Harness <name>  target harness (default: claude). WINDOWS: claude only.
                     The codex harness is gracefully rejected on Windows with
                     an actionable message; the macOS/Linux bash twin
                     install.sh supports codex. Full Windows codex parity is a
                     tracked follow-on.
                     Repeatable via the POSIX --harness form (PowerShell binds
                     the native -Harness to a single value): the documented
                     `--harness claude --harness codex` builds every requested
                     harness in one pass — on Windows codex is WARN-skipped so
                     claude still installs.
    -Out <dir>       override build target (default: $env:CLAUDE_CONFIG_DIR
                     from local.env). Single-harness only — cannot be combined
                     with more than one --harness.
    -BuildOnly       build + validate into a temp dir, print its path, do NOT swap

    Args are also accepted in --kebab-case for symmetry with install.sh:
        --harness <name>, --out <dir>, --build-only

    Env: AI_CONFIG_LOCAL_ENV  path to local.env (default: <repo>\local.env)

    The build is idempotent and atomic: builds into a temp dir on the target
    filesystem, validates, then renames the managed subtrees into place.

.NOTES
    Compiles the claude harness end-to-end on native Windows. The codex harness
    is gracefully rejected on Windows until its port lands; the
    macOS/Linux bash twin install.sh supports it.

    <TEAM>-135: skills/ swap is now per-subdir (parity with install.sh's swap_in
    skills branch) with an OLD-vs-NEW manifest orphan hash-gate, so re-installs
    preserve operator-authored (Shape C) skills across repeated runs instead of
    clobbering them through a wholesale-directory backup that a 2nd consecutive
    run would overwrite. See Move-SkillsIntoTarget below.

    <TEAM>-109 PS-5: $PSScriptRoot empty-string fallback applied.
    <TEAM>-100 hook-command shape: generated settings.json hook commands use
    `pwsh -NoProfile -File <abs>\hooks\<x>.ps1` shape (NOT the legacy `.sh`
    shape that install.sh:244/270-273/337/540 hardcodes — the actual
    Windows-native blocker Codex surfaced).
    See [[feedback_powershell_set_content_crlf]] — every text-file write uses
    [System.IO.File]::WriteAllText with explicit "`n" + no-BOM UTF-8 so
    bash↔pwsh parity holds at byte level.
    See [[reference_powershell_var_colon]] — every "$var:" delimiter case
    inside a double-quoted string uses ${var}: form.
#>

# ---------------------------------------------------------------------------
# Argument parsing — NO param block; parse $args manually (mirrors install.sh).
#
# Why no [CmdletBinding()]/param(): PowerShell's `-File` parameter binder is
# NOT consistent across platforms for the PS-native single-dash spellings, and
# the divergence is invisible on macOS (so it only ever fails on the Windows CI
# lane). Two concrete divergences hit this script:
#   1. A repeatable bound `-Harness` is impossible — macOS binds `--harness` to
#      it and errors "specified more than once" on the documented
#      `--harness claude --harness codex`.
#   2. With `-Harness` unbound, `pwsh -File install.ps1 -Harness claude -Out <dir>`
#      (bootstrap.ps1's exact form) builds on macOS but FAILS on Windows: the
#      single-dash `-Harness` / `-Out` tokens are routed differently by the
#      Windows binder, so $Out never receives <dir> and the build dies with no
#      target. (PositionalBinding=$false did not cure it.)
# Without a param block, EVERY token lands in the automatic $args array verbatim
# on every platform — no binding, no divergence — so we parse it ourselves, the
# same way the bash twin walks "$@". Accept both POSIX (`--flag`) and PS-native
# (`-Flag`) spellings, case-insensitively, for parity with both muscle memories.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Out = ''
$BuildOnly = $false

# --harness is repeatable. Collect every requested harness, lowercased (so casing
# variants dedupe and resolve identically: claude == CLAUDE) and deduped in
# request order so a repeated harness builds once.
$harnessList = New-Object System.Collections.Generic.List[string]
function Add-HarnessRequest {
    param([string]$Name)
    $norm = $Name.ToLowerInvariant()
    if (-not $harnessList.Contains($norm)) { [void]$harnessList.Add($norm) }
}

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    # Harness — repeatable; accumulate into the deduped list above.
    if ($arg -imatch '^--?harness$') {
        if ($i + 1 -ge $args.Count) { [Console]::Error.WriteLine("install.ps1: --harness needs a value"); exit 2 }
        Add-HarnessRequest ([string]$args[$i + 1])
        $i += 2
        continue
    }
    if ($arg -imatch '^--?out$') {
        if ($i + 1 -ge $args.Count) { [Console]::Error.WriteLine("install.ps1: --out needs a value"); exit 2 }
        $Out = [string]$args[$i + 1]
        $i += 2
        continue
    }
    # `-?build-?only` matches --build-only / -build-only / -BuildOnly.
    if ($arg -imatch '^--?build-?only$') {
        $BuildOnly = $true
        $i += 1
        continue
    }
    # `-h` / --help / -help / --h.
    if ($arg -imatch '^--?h(elp)?$') {
        Get-Help $PSCommandPath -Detailed | Out-Host
        exit 0
    }
    [Console]::Error.WriteLine("install.ps1: unknown argument: $arg")
    exit 2
}

# Default to claude when no harness was requested (mirrors install.sh).
if ($harnessList.Count -eq 0) { Add-HarnessRequest 'claude' }

# ---------------------------------------------------------------------------
# Repo root resolution (<TEAM>-109 PS-5 $PSScriptRoot fallback)
# ---------------------------------------------------------------------------

if ($PSScriptRoot) {
    $repoRoot = Split-Path $PSScriptRoot -Parent
} else {
    # Dot-source / piped-invocation fallback. Assumes the script is being
    # invoked from the scripts/ directory; if $PWD is elsewhere this will
    # resolve wrong, but no clean alternative exists when $PSScriptRoot is
    # blank. The unit test at tests/run-resolve.test.ps1 pins the fallback
    # against the conventional invocation context.
    $repoRoot = (Resolve-Path "$PWD/..").Path
}

function Die { param([string]$Msg) [Console]::Error.WriteLine("install.ps1: $Msg"); exit 1 }
function Warn { param([string]$Msg) [Console]::Error.WriteLine("install.ps1: WARNING $Msg") }

# Capture jq's absolute path at precheck — before local.env is imported. If a
# malicious local.env tries to poison PATH after this point (Codex adversarial
# review A-1), subsequent invocations still resolve to the same binary by
# using $script:JqBin in every external call. This also surfaces the binary
# path in the failure message for debugging.
$script:JqBin = $null
$jqCmd = Get-Command jq -ErrorAction SilentlyContinue
if (-not $jqCmd) {
    Die "jq is required but not found on PATH (use 'winget install jqlang.jq' to install)"
}
$script:JqBin = $jqCmd.Source

# ---------------------------------------------------------------------------
# Multi-harness dispatch
# ---------------------------------------------------------------------------
# --harness is repeatable. With more than one harness, re-exec this script once
# per harness so each build runs in a clean process (its own temp build dir,
# hook accumulator, and EXIT-equivalent finally). The single-harness flow below
# then handles exactly one harness, unchanged. This makes the documented
# `--harness claude --harness codex` build what it can in one pass; the old
# scalar parse was last-wins and silently built only the last requested harness
# (and on Windows that last value, codex, hard-aborted — installing nothing).
if ($harnessList.Count -gt 1) {
    if ($Out) {
        Die "--out / -Out cannot be combined with multiple --harness values (each harness builds into its own target dir); run install.ps1 once per harness with -Out"
    }
    if ($BuildOnly) {
        Die "--build-only / -BuildOnly cannot be combined with multiple --harness values (it prints a single build dir); run install.ps1 once per harness with -BuildOnly"
    }
    $pwshExe = (Get-Process -Id $PID).Path
    if (-not $pwshExe) { $pwshExe = 'pwsh' }
    $built = 0
    foreach ($h in $harnessList) {
        if ($h -eq 'codex') {
            # CONTRACT (deliberate bash↔PS asymmetry): the Windows-native twin
            # builds claude only. In a multi-harness run codex is WARN-skipped —
            # NOT a hard failure — so the documented `--harness claude --harness
            # codex` still installs claude on Windows (best-effort) rather than
            # aborting it. The warning to stderr is the signal that codex was not
            # built; the command still exits 0 as long as a supported harness
            # built (operators can't build codex on Windows, so failing the whole
            # command would only block the claude install for no actionable
            # reason). A SINGLE `-Harness codex` still hard-rejects (exit 1) at
            # the resolution block below. The macOS/Linux bash twin builds codex;
            # full Windows codex parity is a tracked follow-on.
            Warn "codex harness is not yet supported on Windows; skipping it (claude still builds — the macOS/Linux install.sh supports codex; full Windows codex parity is a tracked follow-on)"
            continue
        }
        $childArgs = @('-NoProfile', '-File', $PSCommandPath, '--harness', $h)
        & $pwshExe @childArgs
        if ($LASTEXITCODE -ne 0) { Die "install failed for harness '$h' (exit $LASTEXITCODE)" }
        $built++
    }
    if ($built -eq 0) {
        Die "no supported harness was built (requested: $($harnessList -join ', ')); the Windows twin supports claude only — re-run with -Harness claude (the macOS/Linux install.sh supports codex)"
    }
    exit 0
}
$Harness = $harnessList[0]

# ---------------------------------------------------------------------------
# Helpers — sha256, frontmatter parsing
# ---------------------------------------------------------------------------

function Get-FileSha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    $result = Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop
    return $result.Hash.ToLower()
}

# Read raw file contents preserving line endings as-is.
function Get-RawText {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

# Write text using LF + UTF-8 no BOM — bash↔pwsh parity per
# [[feedback_powershell_set_content_crlf]]. Set-Content's default is CRLF + BOM
# on Windows PowerShell 5.x and CRLF on pwsh-on-Windows; both break parity
# with the bash compiler output.
function Write-LfFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# Append text using LF + UTF-8 no BOM.
function Add-LfFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($Path, $Content, $utf8NoBom)
}

# fm_block — return the YAML between the first two --- lines (empty if none).
function Get-FrontmatterBlock {
    param([Parameter(Mandatory)][string]$Path)
    $lines = [System.IO.File]::ReadAllLines($Path)
    if ($lines.Count -eq 0) { return '' }
    if ($lines[0] -ne '---') { return '' }
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^---\s*$') { break }
        [void]$out.Add($lines[$i])
    }
    return ($out -join "`n")
}

# fm_get — value of <key> from fm block (first match, trimmed). Absent key
# returns empty string.
function Get-FrontmatterValue {
    param(
        [Parameter(Mandatory)][string]$Block,
        [Parameter(Mandatory)][string]$Key
    )
    if ([string]::IsNullOrEmpty($Block)) { return '' }
    foreach ($line in ($Block -split "`n")) {
        # Match `^${Key}:[[:space:]]*` — use ${Key}: form per [[reference_powershell_var_colon]].
        $pattern = "^${Key}:\s*(.*)$"
        if ($line -match $pattern) {
            return $matches[1].TrimEnd()
        }
    }
    return ''
}

# body_after_fm — file content after a leading frontmatter block. If no
# frontmatter, return the whole file. LF-normalized output.
function Get-BodyAfterFrontmatter {
    param([Parameter(Mandatory)][string]$Path)
    $lines = [System.IO.File]::ReadAllLines($Path)
    if ($lines.Count -eq 0) { return '' }
    if ($lines[0] -ne '---') {
        return (($lines -join "`n") + "`n")
    }
    $startAfterClose = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^---\s*$') {
            $startAfterClose = $i + 1
            break
        }
    }
    if ($startAfterClose -lt 0 -or $startAfterClose -ge $lines.Count) { return '' }
    $body = $lines[$startAfterClose..($lines.Count - 1)]
    return (($body -join "`n") + "`n")
}

# ---------------------------------------------------------------------------
# Load local.env — bash uses `set -a; . local.env; set +a`. The native PS
# equivalent lives in scripts/lib/local-env.ps1 (<TEAM>-115 absorbs <TEAM>-108);
# dot-source it. The shared parser is the same one bootstrap.ps1 uses, so
# bootstrap + install agree on quoted-value handling, `export` prefix
# stripping, and malformed-line warnings.
#
# Supported subset (per scripts/lib/local-env.ps1 docstring):
#   KEY=VALUE / KEY="VALUE" / KEY='VALUE' / `# comment` / blank /
#   `export KEY=VALUE`.
# Unsupported: bash ANSI-C `KEY=$'...'`; backslash-newline continuation.
# ---------------------------------------------------------------------------

. (Join-Path $PSScriptRoot 'lib/local-env.ps1')

$LOCAL_ENV = if ($env:AI_CONFIG_LOCAL_ENV) { $env:AI_CONFIG_LOCAL_ENV } else { Join-Path $repoRoot 'local.env' }
Import-LocalEnv -Path $LOCAL_ENV
if (-not $env:AI_CONFIG_DIR) {
    $env:AI_CONFIG_DIR = $repoRoot
}

# ---------------------------------------------------------------------------
# Harness resolution
# ---------------------------------------------------------------------------

# <TEAM>-134: the Windows install.ps1 currently ports the claude harness only.
# The codex harness is documented as a bootstrap.ps1 option but its Windows
# port (codex hooks.json shape, AGENTS.md entrypoint, apply_patch matcher, the
# interactive hooks-trust step) is not yet implemented. Reject it GRACEFULLY
# with an actionable message instead of hard-crashing on a half-resolved
# CODEX_HOME path. The macOS/Linux bash twin (install.sh) supports codex; full
# Windows parity is tracked as a follow-on. Reject BEFORE resolving the target
# env var so a fresh Windows operator who passes -Harness codex gets a clear
# "use claude" instruction, not a confusing CODEX_HOME-not-set failure.
if ($Harness -eq 'codex') {
    Die "codex harness is not yet supported on Windows; re-run with -Harness claude (the macOS/Linux install.sh supports codex — full Windows codex parity is a tracked follow-on)"
}

$targetEnvVar = switch ($Harness) {
    'claude' { 'CLAUDE_CONFIG_DIR' }
    'codex'  { 'CODEX_HOME' }
    default  { Die "unknown harness '$Harness' (known on Windows: claude)" }
}

# Read the target env var by NAME. [Environment]::GetEnvironmentVariable returns
# $null for an unset var WITHOUT throwing; `Get-Item -Path env:$name` throws an
# ItemNotFoundException on Windows when the var is unset (the -ErrorAction
# SilentlyContinue does NOT reliably suppress the Env provider's terminating
# error under $ErrorActionPreference='Stop'). That broke the legitimate
# `--out <dir>` path whenever the per-harness env var isn't set — i.e. bootstrap's
# first-run install (seeded local.env) + <TEAM>-46 parity. macOS masked it because
# the operator's shell usually already exports CLAUDE_CONFIG_DIR.
$targetDefault = [Environment]::GetEnvironmentVariable($targetEnvVar)
$TARGET = if ($Out) { $Out } else { $targetDefault }
if (-not $TARGET) {
    Die "${targetEnvVar} is not set in $LOCAL_ENV (or pass -Out <dir>)"
}

$adapter = Join-Path (Join-Path $repoRoot 'harnesses') $Harness 'adapter.md'
if (-not (Test-Path -LiteralPath $adapter -PathType Leaf)) {
    Die "no adapter for harness '$Harness' (expected $adapter)"
}

# ---------------------------------------------------------------------------
# Build dir on the target filesystem (so the final swap is a rename).
# ---------------------------------------------------------------------------

New-Item -ItemType Directory -Path $TARGET -Force | Out-Null
# Canonicalize $TARGET to an absolute path. A relative -Out would otherwise
# leak relative `command` paths into the generated settings.json hook entries.
$TARGET = (Resolve-Path -LiteralPath $TARGET).Path

$BUILD = Join-Path $TARGET (".install-build." + [Guid]::NewGuid().Guid.Substring(0,8))
New-Item -ItemType Directory -Path $BUILD -Force | Out-Null

# Cleanup trap — runs on script exit. PS's `try/finally` is the closest analog
# to bash `trap ... EXIT`. Wrap main() in try/finally below.
$Script:KeepBuild = $false

# ---------------------------------------------------------------------------
# Compilers — compile_native + compile_vendored
# ---------------------------------------------------------------------------

# Accumulator for hooks. Each record is [event, matcher, script].
$Script:HookBlocks = New-Object System.Collections.Generic.List[object]

function Add-Hook {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$Event,
        [string]$Matcher = ''
    )
    # Per [[feedback_powershell_set_content_crlf]] + parity with install.sh,
    # this is `install_hook`. install.sh copies the hook script into the build,
    # substitutes @@AI_CONFIG_DIR@@, makes it executable, and records its
    # settings.json wiring. For PS we DO NOT chmod (Windows ACLs); we DO copy
    # + substitute. Hook scripts for the prototype are .ps1 — the bash twin
    # would copy .sh.
    #
    # Idempotent: re-registering the same script is a no-op.
    $src = Join-Path (Join-Path (Join-Path $repoRoot 'harnesses') $Harness 'hooks') $Script
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        Die "hook script not found: $src"
    }
    $buildHooksDir = Join-Path $BUILD 'hooks'
    if (-not (Test-Path -LiteralPath $buildHooksDir -PathType Container)) {
        New-Item -ItemType Directory -Path $buildHooksDir -Force | Out-Null
    }
    $dst = Join-Path $buildHooksDir $Script
    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) {
        $content = Get-RawText -Path $src
        # Literal substitution — Replace, NOT regex Replace, so '$' etc. in
        # $env:AI_CONFIG_DIR don't get pattern-interpreted.
        $resolved = $content.Replace('@@AI_CONFIG_DIR@@', $env:AI_CONFIG_DIR)
        Write-LfFile -Path $dst -Content $resolved
    }

    # Dedupe by script name (matches install.sh's case-substring check).
    $already = $false
    foreach ($rec in $Script:HookBlocks) {
        if ($rec.script -eq $Script) { $already = $true; break }
    }
    if (-not $already) {
        $Script:HookBlocks.Add([pscustomobject]@{
            event   = $Event
            matcher = $Matcher
            script  = $Script
        })
    }
}

# hook_for_class — enforcement-class -> "script event matcher".
function Resolve-HookForClass {
    param([Parameter(Mandatory)][string]$Class)
    # PROTOTYPE: claude only. Each row mirrors install.sh hook_for_class.
    # Hook script names are .ps1 — the <TEAM>-100 Windows-native fix to the
    # generated settings.json hook command shape.
    # `session-end-gate` was removed in <TEAM>-211 (closeout Stop hook removed;
    # closeout is now manual-fire) — no row, mirroring install.sh.
    $rows = @{
        'claude:pre-edit-gate'    = @{ script = 'session-agent.ps1'; event = 'PreToolUse'; matcher = 'Write|Edit|NotebookEdit' }
    }
    $key = "${Harness}:${Class}"
    if (-not $rows.ContainsKey($key)) {
        return $null
    }
    return $rows[$key]
}

function Compile-Native {
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$CapFile,
        [Parameter(Mandatory)][string]$Fm
    )
    $real = Join-Path (Join-Path (Join-Path $repoRoot 'harnesses') $Harness 'capabilities') ($Base + '.md')
    if (-not (Test-Path -LiteralPath $real -PathType Leaf)) {
        Die "native capability '$Base' has no $Harness realization"
    }

    $summary  = Get-FrontmatterValue -Block $Fm -Key 'summary'
    $triggers = Get-FrontmatterValue -Block $Fm -Key 'triggers'
    $triggers = $triggers -replace '[\[\]]',''
    $desc     = "$summary Triggers: $triggers"

    if ($desc.Length -gt 1536) {
        Warn "capability '$Base' description is $($desc.Length) chars (>1536 router cap)"
    }

    $realFm = Get-FrontmatterBlock -Path $real
    $tools  = Get-FrontmatterValue -Block $realFm -Key 'allowed-tools'

    $skillDir = Join-Path (Join-Path $BUILD 'skills') $Base
    New-Item -ItemType Directory -Path $skillDir -Force | Out-Null

    $skillFile = Join-Path $skillDir 'SKILL.md'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("---`n")
    [void]$sb.Append("name: $Base`n")
    # Folded block scalar — robust to ':' / quotes / '#' in summary or triggers.
    [void]$sb.Append("description: >-`n  $desc`n")
    if ($tools) {
        [void]$sb.Append("allowed-tools: $tools`n")
    }
    [void]$sb.Append("---`n`n")
    [void]$sb.Append((Get-BodyAfterFrontmatter -Path $CapFile))
    [void]$sb.Append("`n")
    [void]$sb.Append((Get-BodyAfterFrontmatter -Path $real))
    Write-LfFile -Path $skillFile -Content $sb.ToString()

    # Register enforcement hook, if declared.
    $enf = Get-FrontmatterValue -Block $Fm -Key 'enforcement'
    if ($enf) {
        $spec = Resolve-HookForClass -Class $enf
        if (-not $spec) {
            Die "capability '$Base' declares unknown enforcement class '$enf'"
        }
        Add-Hook -Script $spec.script -Event $spec.event -Matcher $spec.matcher
    }
}

function Compile-Vendored {
    param([Parameter(Mandatory)][string]$Base)
    $snap = Join-Path (Join-Path (Join-Path $repoRoot 'harnesses') $Harness 'vendored') $Base
    if (Test-Path -LiteralPath $snap -PathType Container) {
        $skillsBuild = Join-Path $BUILD 'skills'
        New-Item -ItemType Directory -Path $skillsBuild -Force | Out-Null
        Copy-Item -LiteralPath $snap -Destination (Join-Path $skillsBuild $Base) -Recurse -Force
    } else {
        Warn "vendored capability '$Base' has no committed snapshot at harnesses/$Harness/vendored/$Base — skipping (tracked by <TEAM>-42)"
    }
}

# ---------------------------------------------------------------------------
# generate_capability_catalog — markdown table.
# ---------------------------------------------------------------------------

function New-CapabilityCatalog {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("| Capability | What it does | Kind |`n")
    [void]$sb.Append("| --- | --- | --- |`n")
    $caps = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'capabilities') -Filter '*.md' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property Name -Culture 'en-US' -CaseSensitive
    foreach ($cap in $caps) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($cap.Name)
        if ($base -eq 'README') { continue }
        $cfm = Get-FrontmatterBlock -Path $cap.FullName
        $harnesses = (Get-FrontmatterValue -Block $cfm -Key 'harnesses') -replace '[\[\]]','' -replace ',',' '
        # Match the bash `case " $harnesses " in *" $HARNESS "*) ;; *) continue;; esac` pattern.
        $padded = " $harnesses "
        if ($padded -notmatch ("\s" + [regex]::Escape($Harness) + "\s")) { continue }
        $summary = Get-FrontmatterValue -Block $cfm -Key 'summary'
        $kind    = Get-FrontmatterValue -Block $cfm -Key 'kind'
        # A '|' in the summary would break the table cell — escape it.
        $summary = $summary -replace '\|','\|'
        # <TEAM>-121 — `` `` `` is the PS escape for a literal backtick; a SINGLE
        # backtick before `$` escapes the variable expansion (so `` `${base}` ``
        # rendered the 7-byte literal `${base}`, not the value). Pair `` `` ``
        # for the markdown-code backticks AROUND the interpolated $base. The
        # `` `n `` at the end is the PS escape for newline. Bash twin at
        # scripts/install.sh:212 has no equivalent footgun (POSIX printf has
        # no backtick-as-escape).
        [void]$sb.Append("| ``$base`` | $summary | $kind |`n")
    }
    return $sb.ToString().TrimEnd("`n")
}

# ---------------------------------------------------------------------------
# compile_entrypoint — substitute @@VAR@@ + @@CAPABILITY_CATALOG@@ tokens.
# ---------------------------------------------------------------------------

function Compile-Entrypoint {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$OutName,
        [Parameter(Mandatory)][string]$Catalog
    )
    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        Die "entrypoint template not found: $TemplatePath"
    }
    $content = Get-RawText -Path $TemplatePath

    # Operator skills overlay — twin of install.sh compile_entrypoint.
    # Splice the local overlay file (named by SKILLS_OVERLAY_PATH) at the
    # @@OPERATOR_SKILLS_OVERLAY@@ marker, or empty for a spine-only render. Strip
    # the overlay's trailing newlines so this matches bash's `$(cat)` (which drops
    # them) and both twins render byte-identically. Done before token enumeration
    # so any path tokens inside the overlay resolve and the marker is consumed.
    # Only for a template that actually carries the marker (so the missing-overlay
    # warning fires at most once per render).
    if ($content.Contains('@@OPERATOR_SKILLS_OVERLAY@@')) {
        $overlay = ''
        $overlayPath = [Environment]::GetEnvironmentVariable('SKILLS_OVERLAY_PATH')
        if ($overlayPath) {
            if (Test-Path -LiteralPath $overlayPath -PathType Leaf) {
                $overlay = (Get-RawText -Path $overlayPath) -replace '(\r?\n)+\z', ''
                # Never let the overlay re-introduce ANY overlay marker (single-pass
                # splice). Strip BOTH: a surviving marker would either make the later
                # codex branch fire on post-splice content (leak) or hit the @@VAR@@
                # loop and die "resolves empty" — Codex F3 + cross-overlay composition.
                $overlay = $overlay.Replace('@@OPERATOR_SKILLS_OVERLAY@@', '')
                $overlay = $overlay.Replace('@@OPERATOR_CODEX_RULES_OVERLAY@@', '')
            } else {
                # SET-but-missing — warn loudly, still render spine-only (Codex F2).
                [Console]::Error.WriteLine("warning: SKILLS_OVERLAY_PATH=$overlayPath is set but the file does not exist — rendering a spine-only $OutName")
            }
        }
        $content = $content.Replace('@@OPERATOR_SKILLS_OVERLAY@@', $overlay)
    }

    # Operator codex-rules overlay — twin of install.sh compile_entrypoint. Splice
    # the local overlay file (named by CODEX_RULES_OVERLAY_PATH) at the
    # @@OPERATOR_CODEX_RULES_OVERLAY@@ marker, or empty for a spine-only render.
    # Codex has no auto-loaded rules/ dir, so operator tool-policy rules must land
    # in the rendered AGENTS.md rather than a sidecar. Strip the overlay's trailing
    # newlines so this matches bash's $(cat) and both twins render byte-identically.
    # Done before token enumeration so any path tokens inside the overlay resolve.
    if ($content.Contains('@@OPERATOR_CODEX_RULES_OVERLAY@@')) {
        $overlay = ''
        $overlayPath = [Environment]::GetEnvironmentVariable('CODEX_RULES_OVERLAY_PATH')
        if ($overlayPath) {
            if (Test-Path -LiteralPath $overlayPath -PathType Leaf) {
                $overlay = (Get-RawText -Path $overlayPath) -replace '(\r?\n)+\z', ''
                # Never let the overlay re-introduce ANY overlay marker (single-pass
                # splice). Strip BOTH — symmetric cross-overlay neutralization (see
                # the skills branch above); a surviving skills marker would hit the
                # @@VAR@@ loop and die "resolves empty".
                $overlay = $overlay.Replace('@@OPERATOR_CODEX_RULES_OVERLAY@@', '')
                $overlay = $overlay.Replace('@@OPERATOR_SKILLS_OVERLAY@@', '')
            } else {
                [Console]::Error.WriteLine("warning: CODEX_RULES_OVERLAY_PATH=$overlayPath is set but the file does not exist — rendering a spine-only $OutName")
            }
        }
        $content = $content.Replace('@@OPERATOR_CODEX_RULES_OVERLAY@@', $overlay)
    }

    # Find every @@VAR@@ token. Mirrors install.sh's `[A-Z_]+` shape — keeping
    # the narrow regex is intentional (matches install.sh contract). The
    # tests/install-render-stable.test.sh <TEAM>-80 F2 well-formedness check is
    # the gate that catches digit-containing tokens at PR time.
    $matchesT = [regex]::Matches($content, '@@([A-Z_]+)@@')
    $seen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in $matchesT) {
        [void]$seen.Add($m.Groups[1].Value)
    }
    foreach ($var in $seen) {
        if ($var -eq 'CAPABILITY_CATALOG') { continue }
        # GetEnvironmentVariable: $null for unset (no throw) — see the target
        # resolution note above; Get-Item env:$var throws on Windows for an
        # unset placeholder var instead of falling through to the clear die below.
        $val = [Environment]::GetEnvironmentVariable($var)
        if (-not $val) {
            Die "entrypoint ${OutName}: placeholder @@${var}@@ resolves empty — set $var in local.env"
        }
        # Literal Replace — '$' in resolved paths must not regex-interpret.
        $content = $content.Replace("@@${var}@@", $val)
    }
    $content = $content.Replace('@@CAPABILITY_CATALOG@@', $Catalog)
    Write-LfFile -Path (Join-Path $BUILD $OutName) -Content $content
}

# ---------------------------------------------------------------------------
# generate_settings — merges generated hooks into a copy of settings.base.json.
#
# <TEAM>-100 Windows-native fix: hook entries are emitted with a PS-callable
# `command: "pwsh"` + `args: ["-NoProfile", "-File", "<abs>\hooks\<x>.ps1"]`
# shape. install.sh hardcodes the .sh path in command; that bare command shape
# is non-executable on Windows.
# ---------------------------------------------------------------------------

function New-Settings {
    $base = Join-Path $repoRoot 'harnesses' $Harness 'settings.base.json'
    if (-not (Test-Path -LiteralPath $base -PathType Leaf)) {
        Die "settings.base.json not found at $base"
    }

    # Build the hooks object via jq for byte-identical shape with install.sh
    # (sorted keys, consistent formatting). Each hook entry's `command` is
    # `pwsh` and `args` includes -NoProfile -File <abs>\hooks\<x>.ps1.
    #
    # PS subtlety — & $script:JqBin returns array-of-lines for multi-line output. Use
    # `jq -c` so each entry is compact single-line; the outer `-join "`n"`
    # collapses the array back to a string so --argjson sees one arg.
    $hooksJson = '{}'
    foreach ($rec in $Script:HookBlocks) {
        # Absolute path in the FINAL target (not the temp build dir).
        $hookAbs = Join-Path $TARGET 'hooks' $rec.script
        $entryOut = & $script:JqBin -nc `
            --arg matcher $rec.matcher `
            --arg command 'pwsh' `
            --arg flag1 '-NoProfile' `
            --arg flag2 '-File' `
            --arg hookpath $hookAbs `
            '{matcher: $matcher, hooks: [{type: "command", command: $command, args: [$flag1, $flag2, $hookpath], timeout: 10}]}'
        if ($LASTEXITCODE -ne 0) { Die "jq failed to construct hook entry" }
        $entryJson = if ($entryOut -is [array]) { $entryOut -join '' } else { $entryOut }
        $appendOut = $hooksJson | & $script:JqBin -c `
            --arg event $rec.event `
            --argjson entry $entryJson `
            '.[$event] = ((.[$event] // []) + [$entry])'
        if ($LASTEXITCODE -ne 0) { Die "jq failed to append hook entry" }
        $hooksJson = if ($appendOut -is [array]) { $appendOut -join '' } else { $appendOut }
    }

    # Preserve operator-owned preference keys across re-renders (mirrors
    # generate_settings in install.sh). settings.base.json ships spine-only
    # defaults with ZERO plugin opinions and NO cost/behavior preferences (no
    # theme, no effortLevel — those would otherwise ship the authoring operator's
    # xhigh cost setting downstream); the operator's LIVE enabledPlugins,
    # agentPushNotifEnabled, theme, and effortLevel must survive a re-render, else
    # every install reverts them to base.
    #
    # AI_CONFIG_SKIP_PRESERVE_LIVE: check-drift.ps1 sets this when building the
    # canonical comparison artifact, so the soft-drift classifier baseline stays
    # opinion-free (base only) and enabledPlugins/agentPushNotifEnabled changes
    # remain detectable rather than silently absorbed. Normal/cure re-renders
    # still preserve-live. Fresh install (no live settings.json) => empty overlay
    # => byte-identical to a plain `. + {hooks}`.
    $live = Join-Path $TARGET 'settings.json'
    $overlay = '{}'
    if ((-not $env:AI_CONFIG_SKIP_PRESERVE_LIVE) -and (Test-Path -LiteralPath $live -PathType Leaf)) {
        $liveRaw = Get-Content -Raw -LiteralPath $live
        $liveRaw | & $script:JqBin -e 'type == "object"' *>$null
        if ($LASTEXITCODE -eq 0) {
            # enabledPlugins is plugin-id -> boolean; keep only boolean-valued
            # entries so a malformed/hostile nested value can't ride through.
            # theme + effortLevel are scalar string preferences; preserve only
            # when they parse as strings so a hostile non-string can't ride through.
            $overlayOut = $liveRaw | & $script:JqBin -c '
                (if (has("enabledPlugins") and (.enabledPlugins | type == "object")) then {enabledPlugins: (.enabledPlugins | with_entries(select(.value | type == "boolean")))} else {} end)
              + (if has("agentPushNotifEnabled") then {agentPushNotifEnabled} else {} end)
              + (if (has("theme") and (.theme | type == "string")) then {theme} else {} end)
              + (if (has("effortLevel") and (.effortLevel | type == "string")) then {effortLevel} else {} end)'
            if ($LASTEXITCODE -eq 0) {
                $overlay = if ($overlayOut -is [array]) { $overlayOut -join '' } else { $overlayOut }
            }
        }
    }

    $outSettings = Join-Path $BUILD 'settings.json'
    $mergedOut = Get-Content -Raw -LiteralPath $base | & $script:JqBin --argjson hooks $hooksJson --argjson overlay $overlay '. + $overlay + {hooks: $hooks}'
    if ($LASTEXITCODE -ne 0) { Die "failed to generate settings.json" }
    $merged = if ($mergedOut -is [array]) { $mergedOut -join "`n" } else { $mergedOut }
    Write-LfFile -Path $outSettings -Content $merged
}

# ---------------------------------------------------------------------------
# write_manifest — sha256 of every source input and every generated output.
# ---------------------------------------------------------------------------

function Write-Manifest {
    $srcPairs = New-Object System.Collections.Generic.List[object]
    $genPairs = New-Object System.Collections.Generic.List[object]

    function Add-SrcPair {
        param([string]$AbsPath, [string]$RootRel)
        if (-not (Test-Path -LiteralPath $AbsPath -PathType Leaf)) { return }
        $rel = $AbsPath.Substring($repoRoot.Length).TrimStart('/', '\').Replace('\','/')
        $srcPairs.Add([pscustomobject]@{ path = $rel; hash = (Get-FileSha256Hex -Path $AbsPath) })
    }

    # Capability specs + realizations + hook scripts + adapter + settings.base.
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'capabilities') -Filter '*.md' -File -ErrorAction SilentlyContinue |
        ForEach-Object { Add-SrcPair -AbsPath $_.FullName }
    $harnessRoot = Join-Path (Join-Path $repoRoot 'harnesses') $Harness
    Get-ChildItem -LiteralPath (Join-Path $harnessRoot 'capabilities') -Filter '*.md' -File -ErrorAction SilentlyContinue |
        ForEach-Object { Add-SrcPair -AbsPath $_.FullName }
    # <TEAM>-100 prototype: both .sh and .ps1 hook scripts are sources (claude
    # ships .ps1 for the prototype-ported hooks; the .sh originals remain as
    # the bash-path source; both are tracked as inputs).
    Get-ChildItem -LiteralPath (Join-Path $harnessRoot 'hooks') -File -ErrorAction SilentlyContinue |
        ForEach-Object { Add-SrcPair -AbsPath $_.FullName }
    Add-SrcPair -AbsPath (Join-Path $harnessRoot 'adapter.md')
    Add-SrcPair -AbsPath (Join-Path $harnessRoot 'settings.base.json')

    # Entrypoint templates.
    foreach ($pair in $Script:Entrypoints) {
        Add-SrcPair -AbsPath (Join-Path $harnessRoot $pair.tmpl)
    }

    # Vendored snapshots — recurse (none in current agentic-os-template after <TEAM>-75
    # but the loop is preserved for forward-compat).
    $vendored = Join-Path $harnessRoot 'vendored'
    if (Test-Path -LiteralPath $vendored -PathType Container) {
        Get-ChildItem -LiteralPath $vendored -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { Add-SrcPair -AbsPath $_.FullName }
    }

    # Generated outputs: everything in $BUILD except the manifest itself.
    Get-ChildItem -LiteralPath $BUILD -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.build-manifest.json' } |
        ForEach-Object {
            $rel = $_.FullName.Substring($BUILD.Length).TrimStart('/', '\').Replace('\','/')
            $genPairs.Add([pscustomobject]@{ path = $rel; hash = (Get-FileSha256Hex -Path $_.FullName) })
        }

    # Sort + build {path: hash} objects.
    $srcObj = @{}
    $srcPairs | Sort-Object -Property path | ForEach-Object { $srcObj[$_.path] = $_.hash }
    $genObj = @{}
    $genPairs | Sort-Object -Property path | ForEach-Object { $genObj[$_.path] = $_.hash }

    $manifest = [ordered]@{
        adapterVersion = (Get-FileSha256Hex -Path $adapter)
        generated      = $genObj
        harness        = $Harness
        sources        = $srcObj
    }

    # Use jq -S for sorted-keys byte-identical output.
    $json = $manifest | ConvertTo-Json -Depth 32
    $sortedOut = $json | & $script:JqBin -S '.'
    if ($LASTEXITCODE -ne 0) { Die "failed to canonicalize manifest JSON" }
    $sorted = if ($sortedOut -is [array]) { $sortedOut -join "`n" } else { $sortedOut }
    if (-not $sorted) { Die "manifest JSON canonicalization produced empty output" }
    Write-LfFile -Path (Join-Path $BUILD '.build-manifest.json') -Content $sorted
}

# ---------------------------------------------------------------------------
# validate_build — sanity-check before swap.
# ---------------------------------------------------------------------------

function Test-Build {
    # Every managed *.json file must be valid JSON.
    foreach ($p in $Script:ManagedPaths) {
        if ($p -like '*.json') {
            $f = Join-Path $BUILD $p
            if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
            $null = Get-Content -Raw -LiteralPath $f | & $script:JqBin empty 2>$null
            if ($LASTEXITCODE -ne 0) { Die "generated $p is not valid JSON" }
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $BUILD 'skills') -PathType Container)) {
        Die "build produced no skills/ directory"
    }
    # No unresolved @@PLACEHOLDER@@ tokens.
    $unresolved = Get-ChildItem -LiteralPath $BUILD -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { (Select-String -LiteralPath $_.FullName -Pattern '@@[A-Z_]+@@' -SimpleMatch:$false -Quiet -ErrorAction SilentlyContinue) }
    if ($unresolved) {
        Die "unresolved @@PLACEHOLDER@@ tokens in build output: $($unresolved.FullName -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# swap_in / rollback / cleanup
#
# <TEAM>-135: swap_in's skills/ branch is now a PER-SUBDIR swap (parity with
# install.sh:398-575) instead of a wholesale-directory move. The wholesale
# move (pre-<TEAM>-135) swapped the entire skills/ tree into a single
# .install-bak.skills backup; a 2nd consecutive re-install would clobber that
# single backup, AND on success the cleanup loop deletes it — so operator-
# authored (Shape C) skills under $TARGET/skills/ were lost on EVERY re-install
# (data-loss reproduced in tests/install-shape-c.test.ps1).
#
# The per-subdir swap mirrors the bash twin exactly:
#   - Each compiled $BUILD/skills/<base>/ replaces $TARGET/skills/<base>/, with
#     a per-subdir backup at $TARGET/skills/.install-bak.<base>/.
#   - Any $TARGET/skills/<x>/ the build did NOT produce (Shape C operator
#     skills) is left untouched.
#   - Orphans (subdirs the OLD manifest managed but the NEW build no longer
#     produces) are deleted ONLY behind a hash gate: every manifest-tracked
#     file under the orphan must still exist on disk AND match the OLD
#     manifest's recorded hash (positive-evidence required). Operator-modified
#     framework skills are preserved; only untouched stale framework content
#     is removed. Unsafe orphan names (path-traversal, separators, control/
#     whitespace, backup-prefix, symlinks) are rejected before any rm.
#     (Mount-point detection is bash-twin-specific via stat -c/-f; on Windows
#     the same-volume assumption holds for $CLAUDE_CONFIG_DIR — documented
#     below at Remove-StaleOrphanSkills.)
# ---------------------------------------------------------------------------

# Move-SkillsIntoTarget — per-subdir swap of $BUILD/skills/* into
# $TARGET/skills/*. Mirrors install.sh:398-575's skills branch. Returns $true
# on success, $false if any per-subdir Move-Item fails (so the caller rolls
# back). Orphan cleanup runs only after every per-subdir swap succeeded.
function Move-SkillsIntoTarget {
    $buildSkills  = Join-Path $BUILD 'skills'
    $targetSkills = Join-Path $TARGET 'skills'
    if (-not (Test-Path -LiteralPath $buildSkills -PathType Container)) { return $true }

    # Compute orphans BEFORE the per-subdir swap. $TARGET/.build-manifest.json
    # still holds the OLD content here (it is swapped later in the
    # ManagedPaths order); $BUILD/.build-manifest.json is the NEW manifest.
    $oldManifest = Join-Path $TARGET '.build-manifest.json'
    $newManifest = Join-Path $BUILD '.build-manifest.json'
    $orphans = @()
    if ((Test-Path -LiteralPath $oldManifest -PathType Leaf) -and (Test-Path -LiteralPath $newManifest -PathType Leaf)) {
        $oldManaged = Get-SkillSubdirsFromManifest -ManifestPath $oldManifest
        $newManaged = Get-SkillSubdirsFromManifest -ManifestPath $newManifest
        # Require BOTH manifests to enumerate cleanly (mirrors the bash twin's
        # `command -v jq` guard around the whole orphan computation). If either
        # jq call failed ($null), skip orphan detection entirely — leaving
        # stale skills is far safer than computing a bogus orphan set from an
        # empty new-managed set (which would mark every OLD-managed subdir an
        # orphan; the hash gate would still protect freshly-rewritten managed
        # skills, but we fail safe rather than rely on that).
        if (($null -ne $oldManaged) -and ($null -ne $newManaged)) {
            # Orphans = OLD-managed subdirs not present in NEW-managed set.
            $newSet = New-Object System.Collections.Generic.HashSet[string]
            foreach ($n in $newManaged) { [void]$newSet.Add($n) }
            $orphans = @($oldManaged | Where-Object { -not $newSet.Contains($_) })
        }
    }

    New-Item -ItemType Directory -Path $targetSkills -Force | Out-Null

    # <TEAM>-147: per-subdir backups go to a run-private root OUTSIDE skills/ at
    # $TARGET/.install-bak.d/skills/<base>/ (parity with install.sh), so an
    # operator skill named `.install-bak.*` is never treated as a backup. The
    # main flow recovers + removes a leftover .install-bak.d from a crashed prior
    # run before the swap loop, so the root is fresh here (no stale same-base
    # collision — hence no pre-delete of a per-subdir backup is needed).
    $bakRoot       = Join-Path $TARGET '.install-bak.d'
    $bakRootSkills = Join-Path $bakRoot 'skills'
    New-Item -ItemType Directory -Path $bakRootSkills -Force | Out-Null

    # Per-subdir swap. Use [string] base names; iterate only directory children.
    $subdirs = @(Get-ChildItem -LiteralPath $buildSkills -Directory -ErrorAction SilentlyContinue)
    foreach ($sub in $subdirs) {
        $base       = $sub.Name
        $tgtSub     = Join-Path $targetSkills $base
        $bakSub     = Join-Path $bakRootSkills $base
        if (Test-Path -LiteralPath $tgtSub) {
            try {
                Move-Item -LiteralPath $tgtSub -Destination $bakSub -Force -ErrorAction Stop
            } catch {
                return $false
            }
        }
        try {
            Move-Item -LiteralPath $sub.FullName -Destination $tgtSub -Force -ErrorAction Stop
        } catch {
            return $false
        }
    }

    # Orphan cleanup runs only after every per-subdir swap succeeded.
    Remove-StaleOrphanSkills -Orphans $orphans -OldManifest $oldManifest -TargetSkills $targetSkills

    return $true
}

# Get-SkillSubdirsFromManifest — return the sorted-unique set of <base> names
# from `.generated` keys shaped `skills/<base>/...`. Mirrors the bash twin's
# `jq -r '.generated | keys[] | select(startswith("skills/")) | split("/")[1]'`.
# Returns $null if jq enumeration fails (caller skips orphan computation).
function Get-SkillSubdirsFromManifest {
    param([Parameter(Mandatory)][string]$ManifestPath)
    $out = Get-Content -Raw -LiteralPath $ManifestPath |
        & $script:JqBin -r '.generated | keys[] | select(startswith("skills/")) | split("/")[1]' 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $names = @($out | Where-Object { ($null -ne $_) -and (($_.ToString()) -ne '') })
    return @($names | Sort-Object -Unique -CaseSensitive)
}

# Remove-StaleOrphanSkills — delete orphan skill subdirs behind a hash gate.
# Mirrors install.sh:430-575. An orphan is deleted ONLY if every manifest-
# tracked file under skills/<orphan>/ still exists on disk AND matches the OLD
# manifest's recorded hash (positive-evidence required via $foundMatch). Unsafe
# orphan names are rejected before any filesystem touch.
function Remove-StaleOrphanSkills {
    param(
        [string[]]$Orphans,
        [Parameter(Mandatory)][string]$OldManifest,
        [Parameter(Mandatory)][string]$TargetSkills
    )
    if (-not $Orphans -or $Orphans.Count -eq 0) { return }

    # Stage the OLD manifest's generated {path -> hash} map once. If jq fails to
    # enumerate it, skip orphan cleanup entirely (defense-in-depth: rather LEAVE
    # stale skills than risk a partial validation deleting operator content).
    $manifestJson = Get-Content -Raw -LiteralPath $OldManifest |
        & $script:JqBin -c '.generated' 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("install.ps1: manifest enumeration failed; skipping orphan cleanup")
        return
    }
    if ($manifestJson -is [array]) { $manifestJson = $manifestJson -join '' }
    $genMap = $null
    try { $genMap = $manifestJson | ConvertFrom-Json -ErrorAction Stop } catch { $genMap = $null }
    if ($null -eq $genMap) {
        [Console]::Error.WriteLine("install.ps1: manifest parse failed; skipping orphan cleanup")
        return
    }
    # Flatten to [pscustomobject]@{ rel; hash } pairs for the inner loop.
    $manifestPairs = New-Object System.Collections.Generic.List[object]
    foreach ($prop in $genMap.PSObject.Properties) {
        $manifestPairs.Add([pscustomobject]@{ rel = $prop.Name; hash = $prop.Value })
    }

    foreach ($orphan in $Orphans) {
        if ([string]::IsNullOrEmpty($orphan)) { continue }
        # Reject control/whitespace FIRST (matches bash's [[:cntrl:][:space:]]
        # check). PS \s is Unicode-aware; add \p{C} for control chars. -cmatch
        # for byte-for-byte (case is irrelevant here but keep the discipline).
        if ($orphan -match '[\s\p{C}]') {
            [Console]::Error.WriteLine("install.ps1: unsafe orphan name skipped (control/whitespace): $orphan")
            continue
        }
        # Path-traversal / separator / backup-prefix. Use -ceq / Ordinal so a
        # case-folded `.INSTALL-BAK.` cannot slip past on PS's case-insensitive
        # default (PS-port trap #15).
        if (($orphan -ceq '.') -or ($orphan -ceq '..')) {
            [Console]::Error.WriteLine("install.ps1: unsafe orphan name skipped (path-traversal): $orphan")
            continue
        }
        if ($orphan.Contains('/') -or $orphan.Contains('\')) {
            [Console]::Error.WriteLine("install.ps1: unsafe orphan name skipped (path-separator): $orphan")
            continue
        }
        if ($orphan.StartsWith('.install-bak.', [StringComparison]::Ordinal)) {
            [Console]::Error.WriteLine("install.ps1: unsafe orphan name skipped (in-flight backup prefix): $orphan")
            continue
        }
        # Windows-specific name classes the bash twin never faces (Codex
        # adversarial <TEAM>-135-F5). A colon would open an NTFS alternate-data-
        # stream (`name:stream`); a trailing dot/space is silently stripped by
        # Win32 path normalization so the validated name would not map 1:1 to
        # the deleted directory. Reject both — fail closed, consistent with the
        # <TEAM>-107 "rather LEAVE stale skills than risk operator content" stance.
        if ($orphan.Contains(':')) {
            [Console]::Error.WriteLine("install.ps1: unsafe orphan name skipped (NTFS data-stream colon): $orphan")
            continue
        }
        if ($orphan.EndsWith('.', [StringComparison]::Ordinal)) {
            [Console]::Error.WriteLine("install.ps1: unsafe orphan name skipped (trailing dot — Win32 normalization): $orphan")
            continue
        }
        $orphanPath = Join-Path $TargetSkills $orphan
        # The resolved orphan must remain an IMMEDIATE child of $TargetSkills
        # (Codex adversarial <TEAM>-135-F5): if Win32 normalization or a sneaky
        # name escapes the skills/ dir, refuse. GetFullPath canonicalizes
        # without requiring the path to exist.
        $orphanFull = [System.IO.Path]::GetFullPath($orphanPath)
        $skillsFull = [System.IO.Path]::GetFullPath($TargetSkills)
        $expectedChild = [System.IO.Path]::Combine($skillsFull, $orphan)
        if ($orphanFull -ne ([System.IO.Path]::GetFullPath($expectedChild)) -or
            -not $orphanFull.StartsWith($skillsFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
            [Console]::Error.WriteLine("install.ps1: unsafe orphan name skipped (not an immediate child of skills/): $orphan")
            continue
        }
        # Reject symlinks/reparse-points before any read under that path.
        $orphanItem = Get-Item -LiteralPath $orphanPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $orphanItem -and ($orphanItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            [Console]::Error.WriteLine("install.ps1: unsafe orphan name skipped (symlink/reparse-point): $orphan")
            continue
        }
        if (-not (Test-Path -LiteralPath $orphanPath -PathType Container)) { continue }

        # Hash gate: every manifest entry under skills/<orphan>/ must exist on
        # disk AND match its recorded hash; at least one must be validated
        # (positive evidence) before deletion.
        $allStale  = $true
        $foundMatch = $false
        $prefix = "skills/$orphan/"
        foreach ($pair in $manifestPairs) {
            $rel = $pair.rel
            # <TEAM>-147 F6: reject any manifest path with a real `..` component
            # before the prefix match (parity with install.sh's `*/../*` guard).
            # A hand-edited OLD manifest could otherwise make a
            # `skills/<orphan>/../<elsewhere>` key satisfy the prefix and validate
            # a hash against a file OUTSIDE skills/<orphan>/. Slash-wrap so only a
            # true `..` segment matches (not `foo..bar`/`..foo`/`foo..`).
            if (('/' + ($rel -replace '\\','/') + '/').Contains('/../')) { continue }
            if (-not $rel.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
            # Manifest rel paths are forward-slash; translate to native for disk.
            $diskPath = Join-Path $TARGET ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $diskPath -PathType Leaf)) {
                $allStale = $false
                break
            }
            $gotHash = Get-FileSha256Hex -Path $diskPath
            if ($gotHash -ne ([string]$pair.hash)) {
                $allStale = $false
                break
            }
            $foundMatch = $true
        }
        if ($allStale -and $foundMatch) {
            # Codex adversarial <TEAM>-135-F4: the root-symlink check above guards
            # the orphan dir itself, but a reparse point (symlink/junction)
            # NESTED inside the orphan could make `Remove-Item -Recurse` delete
            # content on the link's target outside the orphan tree. Scan the
            # subtree for ANY descendant reparse point first; if found, fail
            # closed (skip deletion — leaving a stale orphan is the safe loss).
            $hasNestedReparse = $false
            $descendants = @(Get-ChildItem -LiteralPath $orphanPath -Recurse -Force -ErrorAction SilentlyContinue)
            foreach ($d in $descendants) {
                if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    $hasNestedReparse = $true
                    break
                }
            }
            if ($hasNestedReparse) {
                [Console]::Error.WriteLine("install.ps1: orphan cleanup skipped (nested reparse-point under skills/${orphan} — refusing recursive delete): $orphan")
                continue
            }
            Remove-Item -LiteralPath $orphanPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Move-IntoTarget {
    param([Parameter(Mandatory)][string]$Name)
    # <TEAM>-147 test seam (parity with install.sh swap_in): deterministic rollback
    # induction for the parity tests. When this env var names a managed path,
    # that path's swap fails, exercising the real Restore-Backups caller path.
    # Test-only — production callers never set it, and a forced failure only
    # triggers a clean rollback. -ceq for byte-exact parity with the bash twin's
    # `[ "$X" = "$name" ]`.
    if ($env:AI_CONFIG_INSTALL_TEST_FAIL_SWAP -ceq $Name) { return $false }
    # <TEAM>-135: skills/ uses the per-subdir swap (parity with install.sh swap_in).
    if ($Name -eq 'skills') { return (Move-SkillsIntoTarget) }

    $buildPath  = Join-Path $BUILD $Name
    $targetPath = Join-Path $TARGET $Name
    $backupPath = Join-Path $TARGET (".install-bak.$Name")
    if (-not (Test-Path -LiteralPath $buildPath)) { return $true }

    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $targetPath) {
        try {
            Move-Item -LiteralPath $targetPath -Destination $backupPath -Force -ErrorAction Stop
        } catch {
            return $false
        }
    }
    try {
        Move-Item -LiteralPath $buildPath -Destination $targetPath -Force -ErrorAction Stop
    } catch {
        return $false
    }
    return $true
}

function Restore-Backups {
    foreach ($n in $Script:ManagedPaths) {
        # <TEAM>-135: skills/ uses per-subdir backups under
        # $TARGET/skills/.install-bak.<base>/ (parity with install.sh
        # rollback_swaps). Shape C subdirs were never touched — nothing to
        # restore for them.
        if ($n -eq 'skills') {
            # <TEAM>-147: per-subdir backups live in the run-private root
            # $TARGET/.install-bak.d/skills/<base>/ (parity with install.sh
            # rollback_swaps). Restore each, then drop the root. Shape C subdirs
            # (incl. any named `.install-bak.*`) were never moved in — untouched.
            $targetSkills  = Join-Path $TARGET 'skills'
            $bakRootSkills = Join-Path $TARGET '.install-bak.d' 'skills'
            $restoreOk = $true
            if (Test-Path -LiteralPath $bakRootSkills -PathType Container) {
                $baks = @(Get-ChildItem -LiteralPath $bakRootSkills -Directory -Force -ErrorAction SilentlyContinue)
                foreach ($bak in $baks) {
                    $base = $bak.Name
                    $tgtSub = Join-Path $targetSkills $base
                    if (Test-Path -LiteralPath $tgtSub) {
                        Remove-Item -LiteralPath $tgtSub -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    try {
                        Move-Item -LiteralPath $bak.FullName -Destination $tgtSub -Force -ErrorAction Stop
                    } catch {
                        $restoreOk = $false
                        Warn "rollback could not restore skills/$base"
                    }
                }
            }
            # Codex adversarial <TEAM>-147 F5: only drop the run-private backup root
            # once every restore succeeded — never delete the sole surviving copy
            # on the failure path. Leave .install-bak.d for manual recovery if a
            # restore failed.
            if ($restoreOk) {
                Remove-Item -LiteralPath (Join-Path $TARGET '.install-bak.d') -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                Warn "left $TARGET\.install-bak.d after a failed rollback restore"
            }
            continue
        }
        $bak = Join-Path $TARGET (".install-bak.$n")
        if (Test-Path -LiteralPath $bak) {
            $tgt = Join-Path $TARGET $n
            if (Test-Path -LiteralPath $tgt) {
                Remove-Item -LiteralPath $tgt -Recurse -Force -ErrorAction SilentlyContinue
            }
            Move-Item -LiteralPath $bak -Destination $tgt -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

# Per-harness managed paths + entrypoints (mirrors install.sh:119-126).
switch ($Harness) {
    'claude' {
        $Script:ManagedPaths = @('skills', 'hooks', 'settings.json', 'CLAUDE.md', 'SKILLS.md', '.build-manifest.json')
        $Script:Entrypoints  = @(
            [pscustomobject]@{ tmpl = 'CLAUDE.template.md'; out = 'CLAUDE.md' },
            [pscustomobject]@{ tmpl = 'SKILLS.template.md'; out = 'SKILLS.md' }
        )
    }
    default { Die "harness '$Harness' not implemented in prototype" }
}

try {
    # Compile every capability that targets this harness.
    $capDir = Join-Path $repoRoot 'capabilities'
    $caps = Get-ChildItem -LiteralPath $capDir -Filter '*.md' -File -ErrorAction Stop
    foreach ($cap in $caps) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($cap.Name)
        if ($base -eq 'README') { continue }
        $fm = Get-FrontmatterBlock -Path $cap.FullName
        $harnessesField = (Get-FrontmatterValue -Block $fm -Key 'harnesses') -replace '[\[\]]','' -replace ',',' '
        $padded = " $harnessesField "
        if ($padded -notmatch ("\s" + [regex]::Escape($Harness) + "\s")) { continue }
        $kind = Get-FrontmatterValue -Block $fm -Key 'kind'
        if ($kind -eq 'native') {
            Compile-Native -Base $base -CapFile $cap.FullName -Fm $fm
        } else {
            Compile-Vendored -Base $base
        }
    }

    # Non-capability hook — framework-surface fires unconditionally.
    Add-Hook -Script 'framework-surface.ps1' -Event 'SessionStart' -Matcher 'startup|clear|compact'

    # Generate harness entrypoints from templates + capability catalog.
    $catalog = New-CapabilityCatalog
    foreach ($pair in $Script:Entrypoints) {
        $tmplAbs = Join-Path (Join-Path (Join-Path $repoRoot 'harnesses') $Harness) $pair.tmpl
        Compile-Entrypoint -TemplatePath $tmplAbs -OutName $pair.out -Catalog $catalog
    }

    # Wire hooks into the harness's native config file.
    switch ($Harness) {
        'claude' { New-Settings }
        default  { Die "harness '$Harness' has no settings generator" }
    }

    Write-Manifest
    Test-Build

    if ($BuildOnly) {
        # Print the build dir + suppress the EXIT cleanup so the operator can inspect.
        Write-Output $BUILD
        $Script:KeepBuild = $true
        return
    }

    # <TEAM>-147: a leftover $TARGET/.install-bak.d means a prior install crashed
    # mid-swap. Recover conservatively BEFORE the swap loop (parity with
    # install.sh): restore any backed-up skill whose live counterpart is now
    # missing, then drop the root. A live counterpart that still exists means
    # that subdir's swap completed before the crash, so its backup is stale and
    # discarded. Crash-safe without ever blind-deleting the only surviving copy.
    $recoverSkills = Join-Path $TARGET '.install-bak.d' 'skills'
    if (Test-Path -LiteralPath $recoverSkills -PathType Container) {
        $targetSkills = Join-Path $TARGET 'skills'
        $rbaks = @(Get-ChildItem -LiteralPath $recoverSkills -Directory -Force -ErrorAction SilentlyContinue)
        $recoverOk = $true
        foreach ($rbak in $rbaks) {
            $rtgt = Join-Path $targetSkills $rbak.Name
            if (-not (Test-Path -LiteralPath $rtgt)) {
                try {
                    Move-Item -LiteralPath $rbak.FullName -Destination $rtgt -Force -ErrorAction Stop
                } catch {
                    $recoverOk = $false
                    Warn "could not restore skills/$($rbak.Name) from an interrupted prior install"
                }
            }
        }
        # Codex adversarial <TEAM>-147 F2: never delete the run-private backup root
        # after a FAILED restore — that would discard the sole surviving copy.
        # Abort instead and leave .install-bak.d in place for manual recovery.
        if (-not $recoverOk) {
            Die "interrupted prior install could not be recovered; $TARGET\.install-bak.d left in place — restore its skills\* subdirs manually, then re-run"
        }
    }
    Remove-Item -LiteralPath (Join-Path $TARGET '.install-bak.d') -Recurse -Force -ErrorAction SilentlyContinue

    # Swap each managed path into place.
    foreach ($name in $Script:ManagedPaths) {
        if (-not (Move-IntoTarget -Name $name)) {
            Warn "swap failed for '$name' — rolling back to pre-install state"
            Restore-Backups
            Die "install aborted; target restored to its pre-install state"
        }
    }

    # All swaps succeeded — drop the backups. <TEAM>-135: skills/ uses per-subdir
    # backups under $TARGET/skills/.install-bak.<base>/ (parity with install.sh).
    foreach ($name in $Script:ManagedPaths) {
        if ($name -eq 'skills') {
            # <TEAM>-147: skills backups live in the run-private root (see
            # Move-SkillsIntoTarget); removing it by exact path never touches an
            # operator skill named `.install-bak.*`.
            Remove-Item -LiteralPath (Join-Path $TARGET '.install-bak.d') -Recurse -Force -ErrorAction SilentlyContinue
            continue
        }
        $bak = Join-Path $TARGET (".install-bak.$name")
        if (Test-Path -LiteralPath $bak) {
            Remove-Item -LiteralPath $bak -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    [Console]::Error.WriteLine("install.ps1: built $Harness harness into $TARGET")
} finally {
    if (-not $Script:KeepBuild) {
        if ($BUILD -and (Test-Path -LiteralPath $BUILD)) {
            Remove-Item -LiteralPath $BUILD -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
