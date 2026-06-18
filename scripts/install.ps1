#Requires -Version 7
<#
.SYNOPSIS
    Windows-native compiler — compiles capabilities/ + a harness adapter into harness-native output.

.DESCRIPTION
    install.ps1 — Windows-native twin of scripts/install.sh (<TEAM>-100 prototype).

    Usage: pwsh scripts/install.ps1 [-Harness <name>] [--harness <name>]... [-Out <dir>] [-BuildOnly]

    -Harness <name>  target harness (default: claude). WINDOWS: claude + codex.
                     The hermes harness is gracefully rejected on Windows with
                     an actionable message; the macOS/Linux bash twin
                     install.sh supports hermes. Full Windows hermes parity is a
                     tracked follow-on.
                     Repeatable via the POSIX --harness form (PowerShell binds
                     the native -Harness to a single value): the documented
                     `--harness claude --harness codex` builds every requested
                     harness in one pass — on Windows hermes is WARN-skipped so
                     claude + codex still install.
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
    Compiles the claude + codex harnesses end-to-end on native Windows. The
    hermes harness is gracefully rejected on Windows until its port lands; the
    macOS/Linux bash twin install.sh supports it.

    <TEAM>-135: per-subdir swap (parity with install.sh's swap_in PER_SUBDIR_PATHS
    branch) with an OLD-vs-NEW manifest orphan hash-gate, so re-installs preserve
    operator-authored subdirs (Shape C skills, operator-added plugins) across
    repeated runs instead of clobbering them through a wholesale-directory backup
    that a 2nd consecutive run would overwrite. The set of per-subdir paths is
    $Script:PerSubdirPaths (skills, plugins) — parity with install.sh. On Windows
    only claude + codex build (neither manages plugins — only hermes does), so the
    plugins path stays dormant until the hermes port lands; it is mirrored for
    parity, and the N1 collision warning runs live on claude/codex skills/. See
    Move-SubdirsIntoTarget below.

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
        if ($h -eq 'hermes') {
            # CONTRACT (deliberate bash↔PS asymmetry): the Windows-native twin builds
            # claude + codex but not yet hermes. In a multi-harness run hermes is
            # WARN-skipped — NOT a hard failure — so the documented `--harness claude
            # --harness codex --harness hermes` still installs claude + codex on
            # Windows (best-effort) rather than aborting them. The warning to stderr
            # is the signal that hermes was not built; the command still exits 0 as
            # long as a supported harness built (operators can't build hermes on
            # Windows yet, so failing the whole command would only block the
            # claude/codex install for no actionable reason). A SINGLE `-Harness
            # hermes` still hard-rejects (exit 1) at the resolution block below. The
            # macOS/Linux bash twin builds hermes; full Windows hermes parity is a
            # tracked follow-on.
            Warn "hermes harness is not yet supported on Windows; skipping it (claude + codex still build — the macOS/Linux install.sh supports hermes; full Windows parity is a tracked follow-on)"
            continue
        }
        $childArgs = @('-NoProfile', '-File', $PSCommandPath, '--harness', $h)
        & $pwshExe @childArgs
        if ($LASTEXITCODE -ne 0) { Die "install failed for harness '$h' (exit $LASTEXITCODE)" }
        $built++
    }
    if ($built -eq 0) {
        Die "no supported harness was built (requested: $($harnessList -join ', ')); the Windows twin supports claude + codex — re-run with one of those (the macOS/Linux install.sh also supports hermes)"
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

# <TEAM>-296: the Windows install.ps1 now ports claude + codex. The hermes harness
# port (hooks.yaml shape, SOUL.md entrypoint + soul-identity overlay, the
# agentic-os-hook-bridge desktop-app plugin, the 5-hook wiring, the steward
# script-only copy, plugin-source hashing) is not yet implemented. Reject it
# GRACEFULLY with an actionable message instead of hard-crashing on a
# half-resolved HERMES_HOME path. The macOS/Linux bash twin (install.sh) supports
# hermes; full Windows hermes parity is tracked as a follow-on. Reject BEFORE
# resolving the target env var so a fresh Windows operator who passes
# -Harness hermes gets a clear "use claude or codex" instruction, not a confusing
# HERMES_HOME-not-set failure.
if ($Harness -eq 'hermes') {
    Die "hermes harness is not yet supported on Windows; re-run with -Harness claude or -Harness codex (the macOS/Linux install.sh supports hermes — full Windows parity is a tracked follow-on)"
}

$targetEnvVar = switch ($Harness) {
    'claude' { 'CLAUDE_CONFIG_DIR' }
    'codex'  { 'CODEX_HOME' }
    default  { Die "unknown harness '$Harness' (known on Windows: claude, codex)" }
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
    # claude + codex on Windows. Each row mirrors install.sh hook_for_class.
    # Hook script names are .ps1 — the <TEAM>-100 Windows-native fix to the
    # generated hook command shape. The codex matcher is `apply_patch` (codex
    # file edits report tool_name "apply_patch"), event PreToolUse — mirrors
    # install.sh:493 (codex:pre-edit-gate). hermes (pre_tool_call /
    # write_file|patch|terminal) is a tracked follow-on.
    # `session-end-gate` was removed in <TEAM>-211 (closeout Stop hook removed;
    # closeout is now manual-fire) — no row, mirroring install.sh.
    $rows = @{
        'claude:pre-edit-gate'    = @{ script = 'session-agent.ps1'; event = 'PreToolUse'; matcher = 'Write|Edit|NotebookEdit' }
        'codex:pre-edit-gate'     = @{ script = 'session-agent.ps1'; event = 'PreToolUse'; matcher = 'apply_patch' }
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
    # agentPushNotifEnabled, inputNeededNotifEnabled, theme, and effortLevel must
    # survive a re-render, else every install reverts them to base.
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
              + (if has("inputNeededNotifEnabled") then {inputNeededNotifEnabled} else {} end)
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
# generate_codex_hooks — emits the standalone codex hooks.json.
#
# Mirrors install.sh:565-587 (generate_codex_hooks). Each entry's `command` is
# the PS-callable `pwsh` + `args: ["-NoProfile", "-File", "<abs>\hooks\<x>.ps1"]`
# launcher shape (identical to New-Settings) — a bare `.ps1` path in `command` is
# non-executable on Windows. Codex's hooks.json hook block is structurally
# identical to Claude's settings.json hooks object (codex adapter Fact 2), so the
# same launcher shape applies. The only structural differences from New-Settings:
# a standalone `{hooks: ...}` envelope written to hooks.json (not merged into a
# settings.base.json) and NO preserve-live overlay — codex has neither a base
# settings file nor operator-owned preference keys to carry across re-renders.
# ---------------------------------------------------------------------------

function New-CodexHooks {
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
        if ($LASTEXITCODE -ne 0) { Die "jq failed to construct codex hook entry" }
        $entryJson = if ($entryOut -is [array]) { $entryOut -join '' } else { $entryOut }
        $appendOut = $hooksJson | & $script:JqBin -c `
            --arg event $rec.event `
            --argjson entry $entryJson `
            '.[$event] = ((.[$event] // []) + [$entry])'
        if ($LASTEXITCODE -ne 0) { Die "jq failed to append codex hook entry" }
        $hooksJson = if ($appendOut -is [array]) { $appendOut -join '' } else { $appendOut }
    }

    $outHooks = Join-Path $BUILD 'hooks.json'
    $wrappedOut = & $script:JqBin -n --argjson hooks $hooksJson '{hooks: $hooks}'
    if ($LASTEXITCODE -ne 0) { Die "failed to generate hooks.json" }
    $wrapped = if ($wrappedOut -is [array]) { $wrappedOut -join "`n" } else { $wrappedOut }
    Write-LfFile -Path $outHooks -Content $wrapped
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
#     below at Remove-StaleOrphanSubdirs.)
# ---------------------------------------------------------------------------

# Test-FsCaseInsensitive — return $true if the filesystem backing $Dir treats
# names case-insensitively (default macOS APFS, Windows NTFS/ReFS). Probes by
# creating a UNIQUE temp dir under $Dir (GetRandomFileName, so it can never
# collide with operator content), writing a lowercase-named file inside it, and
# testing whether the uppercase variant resolves to the same entry. It removes
# ONLY the temp dir it created — a pre-existing operator file/dir of ANY name is
# never touched (the routine's never-delete-what-we-did-not-author contract).
# Any probe failure (unwritable dir, name collision) returns $true (assume case-
# insensitive) — the SAFE direction for the orphan gate: a case-insensitive
# comparison yields FEWER orphans, never more, so it can never turn a live
# managed subdir into a deletion. Callers probe the dir where deletion actually
# happens ($TARGET/<Name>), not its parent, so a $TARGET/<Name> mounted on a
# different-case-sensitivity volume than $TARGET is judged correctly.
#
# Why this exists: the orphan set ($newSet) and the N1 authorship set
# ($oldManagedSet) below were default (Ordinal, case-SENSITIVE) HashSets. On a
# case-insensitive FS, a casing-only rename of a managed subdir between builds
# (e.g. skills/Foo -> skills/foo, identical content) made the OLD-cased name
# look like an orphan; the hash gate then resolved against the just-swapped-in
# new-cased files (identical content -> hashes match) and Remove-Item deleted
# the freshly-installed directory. Folding the comparison ONLY on a case-
# insensitive FS fixes that without merging genuinely-distinct `Foo`/`foo`
# dirs on a case-SENSITIVE FS (Linux), where both must remain real orphans.
# Mirrors install.sh's fs_case_insensitive twin.
function Test-FsCaseInsensitive {
    param([Parameter(Mandatory)][string]$Dir)
    # Unique probe dir (GetRandomFileName → no fixed-name collision with operator
    # content). If we cannot create it, fail to the safe default (insensitive).
    $probeDir = Join-Path $Dir ('.aos-fscase.' + [System.IO.Path]::GetRandomFileName())
    try {
        New-Item -ItemType Directory -Path $probeDir -ErrorAction Stop | Out-Null
    } catch {
        return $true
    }
    try {
        New-Item -ItemType File -Path (Join-Path $probeDir 'probe') -Force -ErrorAction Stop | Out-Null
        return [bool](Test-Path -LiteralPath (Join-Path $probeDir 'PROBE') -PathType Leaf)
    } catch {
        return $true
    } finally {
        # Remove ONLY the unique dir we created — never a pre-existing path.
        Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Move-SubdirsIntoTarget — per-subdir swap of $BUILD/<Name>/* into
# $TARGET/<Name>/*, for any PER_SUBDIR_PATHS member. Mirrors install.sh's
# swap_in per-subdir branch. Returns $true on success, $false if any per-subdir
# Move-Item fails (so the caller rolls back). Orphan cleanup runs only after
# every per-subdir swap succeeded.
function Move-SubdirsIntoTarget {
    param([Parameter(Mandatory)][string]$Name)
    $buildDir  = Join-Path $BUILD $Name
    $targetDir = Join-Path $TARGET $Name
    if (-not (Test-Path -LiteralPath $buildDir -PathType Container)) { return $true }

    # Compute orphans BEFORE the per-subdir swap. $TARGET/.build-manifest.json
    # still holds the OLD content here (it is swapped later in the
    # ManagedPaths order); $BUILD/.build-manifest.json is the NEW manifest. The
    # prefix is parameterized so the same lookup serves any per-subdir path.
    $oldManifest = Join-Path $TARGET '.build-manifest.json'
    $newManifest = Join-Path $BUILD '.build-manifest.json'
    $prefix = "$Name/"
    # old_managed is also reused below for the N1 collision warning (authorship).
    $oldManaged = $null
    if (Test-Path -LiteralPath $oldManifest -PathType Leaf) {
        $oldManaged = Get-SubdirsFromManifest -ManifestPath $oldManifest -Prefix $prefix
    }
    # FS-casing-aware comparer for the orphan set + the N1 authorship set (see
    # Test-FsCaseInsensitive). Only consulted when prior framework state exists; a
    # fresh install has no old-managed set to compare (and so no probe artifact).
    # Probe $targetDir ($TARGET/$Name) — the dir where deletion actually happens —
    # not its parent, since they can be on different-case-sensitivity volumes;
    # fall back to $TARGET when the subdir does not exist yet. Case-insensitive FS
    # -> fold the comparison so a recased-but-same managed subdir is not a false
    # orphan; case-sensitive FS -> Ordinal (distinct dirs).
    $baseCmp = [System.StringComparer]::Ordinal
    if ($null -ne $oldManaged) {
        $probeTarget = if (Test-Path -LiteralPath $targetDir -PathType Container) { $targetDir } else { $TARGET }
        if (Test-FsCaseInsensitive -Dir $probeTarget) { $baseCmp = [System.StringComparer]::OrdinalIgnoreCase }
    }
    $orphans = @()
    if ((Test-Path -LiteralPath $oldManifest -PathType Leaf) -and (Test-Path -LiteralPath $newManifest -PathType Leaf)) {
        $newManaged = Get-SubdirsFromManifest -ManifestPath $newManifest -Prefix $prefix
        # Require BOTH manifests to enumerate cleanly (mirrors the bash twin's
        # `command -v jq` guard around the whole orphan computation). If either
        # jq call failed ($null), skip orphan detection entirely — leaving a
        # stale subdir is far safer than computing a bogus orphan set from an
        # empty new-managed set (which would mark every OLD-managed subdir an
        # orphan; the hash gate would still protect freshly-rewritten managed
        # content, but we fail safe rather than rely on that).
        if (($null -ne $oldManaged) -and ($null -ne $newManaged)) {
            # Orphans = OLD-managed subdirs not present in NEW-managed set.
            # $baseCmp folds case only on a case-insensitive FS (see above).
            $newSet = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList $baseCmp
            foreach ($n in $newManaged) { [void]$newSet.Add($n) }
            $orphans = @($oldManaged | Where-Object { -not $newSet.Contains($_) })
        }
    }

    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

    # <TEAM>-147: per-subdir backups go to a run-private root OUTSIDE the live
    # tree at $TARGET/.install-bak.d/<Name>/<base>/ (parity with install.sh), so
    # an operator subdir named `.install-bak.*` is never treated as a backup. The
    # main flow recovers + removes a leftover .install-bak.d from a crashed prior
    # run before the swap loop, so the root is fresh here (no stale same-base
    # collision — hence no pre-delete of a per-subdir backup is needed). The root
    # is shared across per-subdir paths; each gets its own <Name>/ subtree.
    $bakRoot    = Join-Path $TARGET '.install-bak.d'
    $bakRootSub = Join-Path $bakRoot $Name
    New-Item -ItemType Directory -Path $bakRootSub -Force | Out-Null

    # N1: a set of <base> names a prior framework install authored. Empty when
    # there is no old manifest / jq failed → every pre-existing live subdir is
    # treated as unauthored, which is correct for a fresh install. $baseCmp folds
    # case only on a case-insensitive FS, so a recased managed <base> (which WAS
    # authored by a prior install — same on-disk dir) does not spuriously warn.
    $oldManagedSet = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList $baseCmp
    if ($null -ne $oldManaged) { foreach ($m in $oldManaged) { [void]$oldManagedSet.Add($m) } }

    # Per-subdir swap. Use [string] base names; iterate only directory children.
    $subdirs = @(Get-ChildItem -LiteralPath $buildDir -Directory -ErrorAction SilentlyContinue)
    foreach ($sub in $subdirs) {
        $base       = $sub.Name
        $tgtSub     = Join-Path $targetDir $base
        $bakSub     = Join-Path $bakRootSub $base
        if (Test-Path -LiteralPath $tgtSub) {
            # N1: warn (don't silently overwrite) when replacing a live subdir no
            # prior framework install authored — a framework <base> colliding by
            # name with operator/native content. The framework version still wins.
            if (-not $oldManagedSet.Contains($base)) {
                Warn "replacing $Name/$base which no prior framework install authored (operator/native content with a colliding name)"
            }
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
    Remove-StaleOrphanSubdirs -Orphans $orphans -OldManifest $oldManifest -Name $Name -TargetDir $targetDir

    return $true
}

# Get-SubdirsFromManifest — return the sorted-unique set of <base> names from
# `.generated` keys shaped `<Prefix><base>/...` (Prefix is e.g. `skills/` or
# `plugins/`). Mirrors the bash twin's
# `jq -r --arg p <Prefix> '.generated | keys[] | select(startswith($p)) | split("/")[1]'`.
# Returns $null if jq enumeration fails (caller skips orphan computation).
function Get-SubdirsFromManifest {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$Prefix
    )
    $out = Get-Content -Raw -LiteralPath $ManifestPath |
        & $script:JqBin -r --arg p $Prefix '.generated | keys[] | select(startswith($p)) | split("/")[1]' 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $names = @($out | Where-Object { ($null -ne $_) -and (($_.ToString()) -ne '') })
    return @($names | Sort-Object -Unique -CaseSensitive)
}

# Remove-StaleOrphanSubdirs — delete orphan subdirs behind a hash gate, for any
# per-subdir path (skills, plugins). Mirrors install.sh's swap_in orphan loop. An
# orphan is deleted ONLY if every manifest-tracked file under <Name>/<orphan>/
# still exists on disk AND matches the OLD manifest's recorded hash (positive-
# evidence required via $foundMatch). Unsafe orphan names are rejected before any
# filesystem touch.
function Remove-StaleOrphanSubdirs {
    param(
        [string[]]$Orphans,
        [Parameter(Mandatory)][string]$OldManifest,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TargetDir
    )
    # <TEAM>-294 F7 parity: the OLD-manifest corruptness check runs on manifest
    # PRESENCE, not on a non-empty $Orphans. install.sh's swap_in dumps the
    # manifest UNCONDITIONALLY once it reaches the orphan section (install.sh
    # ~L840) and warns on a non-zero jq exit even when the orphan set is empty —
    # a corrupt manifest yields an empty orphan set upstream (Get-SubdirsFromManifest
    # returns $null → the caller's $null-guard skips orphan computation), so
    # gating this behind $Orphans.Count would silently skip the warning where bash
    # prints it. An ABSENT manifest (first install) is not corrupt — nothing to
    # enumerate, no orphans possible, no warning. Critically, a VALID manifest
    # whose prefix set is simply EMPTY (e.g. an older manifest with no plugins/
    # entries when plugins/ just became per-subdir) also returns $null upstream,
    # but dumps cleanly HERE — so it does NOT warn, matching bash's silent
    # `jq | sort -u` on an empty result. Keying the warning off the .generated
    # dump (not off the prefix enumeration) is what keeps corrupt distinct from
    # empty.
    if (-not (Test-Path -LiteralPath $OldManifest -PathType Leaf)) { return }

    # Stage the OLD manifest's generated {path -> hash} map once. A non-zero jq
    # exit (corrupt JSON / jq crash) or an unparseable dump skips orphan cleanup
    # entirely (defense-in-depth: rather LEAVE a stale subdir than risk a partial
    # validation deleting operator content).
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

    # Manifest is valid; if there is nothing stale to remove, stop here (the
    # corruptness warning above is correctly suppressed for a clean manifest).
    if (-not $Orphans -or $Orphans.Count -eq 0) { return }

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
        # <TEAM>-107 "rather LEAVE a stale subdir than risk operator content" stance.
        if ($orphan.Contains(':')) {
            [Console]::Error.WriteLine("install.ps1: unsafe orphan name skipped (NTFS data-stream colon): $orphan")
            continue
        }
        if ($orphan.EndsWith('.', [StringComparison]::Ordinal)) {
            [Console]::Error.WriteLine("install.ps1: unsafe orphan name skipped (trailing dot — Win32 normalization): $orphan")
            continue
        }
        $orphanPath = Join-Path $TargetDir $orphan
        # The resolved orphan must remain an IMMEDIATE child of $TargetDir
        # (Codex adversarial <TEAM>-135-F5): if Win32 normalization or a sneaky
        # name escapes the <Name>/ dir, refuse. GetFullPath canonicalizes
        # without requiring the path to exist.
        $orphanFull = [System.IO.Path]::GetFullPath($orphanPath)
        $targetDirFull = [System.IO.Path]::GetFullPath($TargetDir)
        $expectedChild = [System.IO.Path]::Combine($targetDirFull, $orphan)
        if ($orphanFull -ne ([System.IO.Path]::GetFullPath($expectedChild)) -or
            -not $orphanFull.StartsWith($targetDirFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
            [Console]::Error.WriteLine("install.ps1: unsafe orphan name skipped (not an immediate child of ${Name}/): $orphan")
            continue
        }
        # Reject symlinks/reparse-points before any read under that path.
        $orphanItem = Get-Item -LiteralPath $orphanPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $orphanItem -and ($orphanItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            [Console]::Error.WriteLine("install.ps1: unsafe orphan name skipped (symlink/reparse-point): $orphan")
            continue
        }
        if (-not (Test-Path -LiteralPath $orphanPath -PathType Container)) { continue }

        # Hash gate: every manifest entry under <Name>/<orphan>/ must exist on
        # disk AND match its recorded hash; at least one must be validated
        # (positive evidence) before deletion.
        $allStale  = $true
        $foundMatch = $false
        $prefix = "$Name/$orphan/"
        foreach ($pair in $manifestPairs) {
            $rel = $pair.rel
            # <TEAM>-147 F6: reject any manifest path with a real `..` component
            # before the prefix match (parity with install.sh's `*/../*` guard).
            # A hand-edited OLD manifest could otherwise make a
            # `<Name>/<orphan>/../<elsewhere>` key satisfy the prefix and validate
            # a hash against a file OUTSIDE <Name>/<orphan>/. Slash-wrap so only a
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
                [Console]::Error.WriteLine("install.ps1: orphan cleanup skipped (nested reparse-point under ${Name}/${orphan} — refusing recursive delete): $orphan")
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
    # <TEAM>-135: PER_SUBDIR_PATHS members use the per-subdir swap (parity with
    # install.sh swap_in). On Windows only skills/ is in ManagedPaths today.
    if ($Script:PerSubdirPaths -contains $Name) { return (Move-SubdirsIntoTarget -Name $Name) }

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
    # <TEAM>-135/147: PER_SUBDIR_PATHS members use per-subdir backups under the
    # shared run-private root $TARGET/.install-bak.d/<name>/<base>/ (parity with
    # install.sh rollback_swaps). Restore each backed-up subdir for every
    # per-subdir path, then drop the shared root ONCE after the loop — never
    # inside a per-name branch, which would discard a sibling path's still-needed
    # backups mid-rollback. Shape C / operator subdirs (incl. any named
    # `.install-bak.*`) were never moved into the root, so they are untouched.
    $anyPerSubdir  = $false
    $rootRestoreOk = $true
    foreach ($n in $Script:ManagedPaths) {
        if ($Script:PerSubdirPaths -contains $n) {
            $anyPerSubdir = $true
            $targetDir  = Join-Path $TARGET $n
            $bakRootSub = Join-Path (Join-Path $TARGET '.install-bak.d') $n
            if (Test-Path -LiteralPath $bakRootSub -PathType Container) {
                $baks = @(Get-ChildItem -LiteralPath $bakRootSub -Directory -Force -ErrorAction SilentlyContinue)
                foreach ($bak in $baks) {
                    $base = $bak.Name
                    $tgtSub = Join-Path $targetDir $base
                    if (Test-Path -LiteralPath $tgtSub) {
                        Remove-Item -LiteralPath $tgtSub -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    try {
                        Move-Item -LiteralPath $bak.FullName -Destination $tgtSub -Force -ErrorAction Stop
                    } catch {
                        $rootRestoreOk = $false
                        Warn "rollback could not restore $n/$base"
                    }
                }
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
    # Codex adversarial <TEAM>-147 F5: only drop the shared run-private backup root
    # once EVERY per-subdir restore (across all per-subdir paths) succeeded —
    # never delete the sole surviving copy on the failure path. Leave
    # .install-bak.d for manual recovery if any restore failed. Dropping it here
    # (after the loop), not inside the per-name branch, keeps sibling backups intact.
    if ($anyPerSubdir) {
        if ($rootRestoreOk) {
            Remove-Item -LiteralPath (Join-Path $TARGET '.install-bak.d') -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Warn "left $TARGET\.install-bak.d after a failed rollback restore"
        }
    }
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

# Managed paths swapped PER-SUBDIR instead of wholesale (mirrors install.sh's
# PER_SUBDIR_PATHS). plugins is hermes-only, so it is never in the claude/codex
# Windows ManagedPaths below and stays dormant here until the hermes port lands;
# it is listed for parity with install.sh, and so the per-subdir swap, rollback,
# crash-recovery, and cleanup all key off the same shared run-private root. The
# N1 collision warning runs live on claude/codex skills/.
$Script:PerSubdirPaths = @('skills', 'plugins')

# Per-harness managed paths + entrypoints (mirrors install.sh:119-126).
switch ($Harness) {
    'claude' {
        $Script:ManagedPaths = @('skills', 'hooks', 'settings.json', 'CLAUDE.md', 'SKILLS.md', '.build-manifest.json')
        $Script:Entrypoints  = @(
            [pscustomobject]@{ tmpl = 'CLAUDE.template.md'; out = 'CLAUDE.md' },
            [pscustomobject]@{ tmpl = 'SKILLS.template.md'; out = 'SKILLS.md' }
        )
    }
    'codex' {
        # Mirrors install.sh:184-185 — codex manages a standalone hooks.json (not
        # settings.json) and a single AGENTS.md entrypoint. The `plugins` per-subdir
        # path stays dormant (codex has no managed plugins, same as claude).
        $Script:ManagedPaths = @('skills', 'hooks', 'hooks.json', 'AGENTS.md', '.build-manifest.json')
        $Script:Entrypoints  = @(
            [pscustomobject]@{ tmpl = 'AGENTS.template.md'; out = 'AGENTS.md' }
        )
    }
    default { Die "harness '$Harness' not implemented on Windows (known: claude, codex)" }
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
        'codex'  { New-CodexHooks }
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
    # install.sh): for EVERY per-subdir path, restore any backed-up subdir whose
    # live counterpart is now missing, then drop the root. A live counterpart that
    # still exists means that subdir's swap completed before the crash, so its
    # backup is stale and discarded. Crash-safe without ever blind-deleting the
    # only surviving copy. The root is shared, so it is dropped ONCE after the loop.
    $recoverRoot = Join-Path $TARGET '.install-bak.d'
    if (Test-Path -LiteralPath $recoverRoot -PathType Container) {
        $recoverOk = $true
        foreach ($rsub in $Script:PerSubdirPaths) {
            $recoverSub = Join-Path $recoverRoot $rsub
            if (-not (Test-Path -LiteralPath $recoverSub -PathType Container)) { continue }
            $targetDir = Join-Path $TARGET $rsub
            $rbaks = @(Get-ChildItem -LiteralPath $recoverSub -Directory -Force -ErrorAction SilentlyContinue)
            foreach ($rbak in $rbaks) {
                $rtgt = Join-Path $targetDir $rbak.Name
                if (-not (Test-Path -LiteralPath $rtgt)) {
                    try {
                        Move-Item -LiteralPath $rbak.FullName -Destination $rtgt -Force -ErrorAction Stop
                    } catch {
                        $recoverOk = $false
                        Warn "could not restore $rsub/$($rbak.Name) from an interrupted prior install"
                    }
                }
            }
        }
        # Codex adversarial <TEAM>-147 F2: never delete the run-private backup root
        # after a FAILED restore — that would discard the sole surviving copy.
        # Abort instead and leave .install-bak.d in place for manual recovery.
        if (-not $recoverOk) {
            Die "interrupted prior install could not be recovered; $TARGET\.install-bak.d left in place — restore its subdirs manually, then re-run"
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

    # All swaps succeeded — drop the backups. <TEAM>-135: PER_SUBDIR_PATHS members
    # share the run-private root $TARGET/.install-bak.d/ (see Move-SubdirsIntoTarget),
    # so it is dropped ONCE after the loop by exact path (never touching an operator
    # subdir named `.install-bak.*`); wholesale paths drop their own .install-bak.<name>.
    foreach ($name in $Script:ManagedPaths) {
        if ($Script:PerSubdirPaths -contains $name) { continue }
        $bak = Join-Path $TARGET (".install-bak.$name")
        if (Test-Path -LiteralPath $bak) {
            Remove-Item -LiteralPath $bak -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath (Join-Path $TARGET '.install-bak.d') -Recurse -Force -ErrorAction SilentlyContinue

    [Console]::Error.WriteLine("install.ps1: built $Harness harness into $TARGET")

    # The codex build is inert until the user trusts the generated hooks.json:
    # Codex does not run a non-managed hooks.json until trusted via the interactive
    # `/hooks` command. install.ps1 cannot trust hooks on the user's behalf, so it
    # surfaces the step (codex adapter.md Fact 2 documents it as surfaced). Mirrors
    # install.sh:1200-1204.
    if ($Harness -eq 'codex') {
        [Console]::Error.WriteLine('install.ps1: NEXT STEP — run the interactive `/hooks` command in codex once')
        [Console]::Error.WriteLine("            to review and trust $TARGET\hooks.json; until trusted, the")
        [Console]::Error.WriteLine('            enforcement hooks will not run. (codex exec runs no hooks at all.)')
    }
} finally {
    if (-not $Script:KeepBuild) {
        if ($BUILD -and (Test-Path -LiteralPath $BUILD)) {
            Remove-Item -LiteralPath $BUILD -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
