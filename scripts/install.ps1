#Requires -Version 7
<#
.SYNOPSIS
    Windows-native compiler — compiles capabilities/ + a harness adapter into harness-native output.

.DESCRIPTION
    install.ps1 — Windows-native twin of scripts/install.sh (<TEAM>-100 prototype).

    Usage: pwsh scripts/install.ps1 [-Harness <name>] [--harness <name>]... [-Out <dir>] [-BuildOnly]

    -Harness <name>  target harness (default: claude). WINDOWS: claude, codex, and
                     hermes all build natively.
                     Repeatable via the POSIX --harness form (PowerShell binds
                     the native -Harness to a single value): the documented
                     `--harness claude --harness codex --harness hermes` builds
                     every requested harness in one pass.
    -Out <dir>       override build target (default: $env:CLAUDE_CONFIG_DIR
                     from local.env). Single-harness only — cannot be combined
                     with more than one --harness.
    -BuildOnly       build + validate into a temp dir, print its path, do NOT swap
    -DryRun          build + validate, then REPORT the live target's install state
                     (managed/missing/broken/custom/stale) WITHOUT writing anything.
                     Surfaces a silently-stale installed config. Single-harness only;
                     read-only; always exits 0.

    Args are also accepted in --kebab-case for symmetry with install.sh:
        --harness <name>, --out <dir>, --build-only, --dry-run

    Env: AI_CONFIG_LOCAL_ENV  path to local.env (default: <repo>\local.env)

    The build is idempotent and atomic: builds into a temp dir on the target
    filesystem, validates, then renames the managed subtrees into place.

.NOTES
    Compiles the claude, codex, and hermes harnesses end-to-end on native Windows.

    <TEAM>-135: per-subdir swap (parity with install.sh's swap_in PER_SUBDIR_PATHS
    branch) with an OLD-vs-NEW manifest orphan hash-gate, so re-installs preserve
    operator-authored subdirs (Shape C skills, operator-added plugins) across
    repeated runs instead of clobbering them through a wholesale-directory backup
    that a 2nd consecutive run would overwrite. The set of per-subdir paths is
    $Script:PerSubdirPaths (skills, plugins) — parity with install.sh. claude and
    codex have no managed plugins (the plugins path stays dormant for them); hermes
    manages plugins/ (the agentic-os-hook-bridge), so the per-subdir swap preserves
    operator-added plugins across re-installs. The N1 collision warning runs live on
    every harness's skills/. See Move-SubdirsIntoTarget below.

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
$DryRun = $false         # --dry-run: classify + report the live target, write nothing

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
    # `-?dry-?run` matches --dry-run / -dry-run / -DryRun.
    if ($arg -imatch '^--?dry-?run$') {
        $DryRun = $true
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
    if ($DryRun) {
        Die "--dry-run / -DryRun cannot be combined with multiple --harness values (it reports a single target); run install.ps1 once per harness with -DryRun"
    }
    $pwshExe = (Get-Process -Id $PID).Path
    if (-not $pwshExe) { $pwshExe = 'pwsh' }
    # <TEAM>-296: claude, codex, and hermes all build on Windows, so every requested
    # harness re-execs in its own clean process (no WARN-skip). An unknown harness
    # name is caught up front (validation) and again at the per-harness env switch.
    $built = 0
    foreach ($h in $harnessList) {
        $childArgs = @('-NoProfile', '-File', $PSCommandPath, '--harness', $h)
        & $pwshExe @childArgs
        if ($LASTEXITCODE -ne 0) { Die "install failed for harness '$h' (exit $LASTEXITCODE)" }
        $built++
    }
    if ($built -eq 0) {
        Die "no harness was built (requested: $($harnessList -join ', '))"
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

# The durable-knowledge vault is OPTIONAL — the framework degrades gracefully when
# OBSIDIAN_VAULT_PATH is unset (core/operating-system.md / README: never fail
# closed). Compile-Entrypoint + Add-HookScriptOnly render this ASCII sentinel in
# place of an empty vault path so a fresh clone with no vault still builds; every
# OTHER path placeholder stays required and still dies on empty. Mirrors install.sh.
$VaultUnsetSentinel = '(unset - the durable-knowledge vault is optional; set OBSIDIAN_VAULT_PATH in local.env and re-run install to enable it)'

# ---------------------------------------------------------------------------
# Harness resolution
# ---------------------------------------------------------------------------

# <TEAM>-296: claude, codex, and hermes all build on native Windows now. (Earlier
# prototypes hard-rejected codex/hermes here; the per-harness resolution below
# handles all three, mirroring install.sh's harness_target_env.) A genuinely
# unknown harness still dies at the switch default below, before any target
# resolution or build-dir creation.
$targetEnvVar = switch ($Harness) {
    'claude' { 'CLAUDE_CONFIG_DIR' }
    'codex'  { 'CODEX_HOME' }
    'hermes' { 'HERMES_HOME' }
    default  { Die "unknown harness '$Harness' (known on Windows: claude, codex, hermes)" }
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

# --- live config-dir guard (throwaway/test builds only; mirrors install.sh) ---
# A build driven by a NON-default local.env (a throwaway/test local.env, not
# <repo>\local.env) must NEVER render into a live config dir. When a fixture
# local.env omits the per-harness target var, $TARGET falls back to the INHERITED
# value — in a co-located install that is <repo>\.{claude,codex,hermes}, so the
# build would overwrite the operator's live entrypoint with throwaway test
# content. Forbidden: the repo's own co-located dirs + any AI_CONFIG_FORBID_TARGETS
# entry (PathSeparator-joined). A real install uses <repo>\local.env (guard
# skipped); set AI_CONFIG_ALLOW_LIVE_TARGET=1 to override; skipped under -DryRun.
# Runs BEFORE New-Item below, so a refusal never even CREATES the live dir.
$defaultLocalEnv = Join-Path $repoRoot 'local.env'
$isDefaultEnv = $false
if (Test-Path -LiteralPath $defaultLocalEnv -PathType Leaf) {
    $isDefaultEnv = ((Resolve-Path -LiteralPath $LOCAL_ENV).Path -eq (Resolve-Path -LiteralPath $defaultLocalEnv).Path)
}
if ((-not $DryRun) -and ($env:AI_CONFIG_ALLOW_LIVE_TARGET -ne '1') -and (-not $isDefaultEnv)) {
    # Normalize TARGET for the compare WITHOUT creating it: Resolve-Path if it
    # already exists (a live config dir always does), else GetFullPath; trim a
    # trailing separator so the compare matches the forbidden dirs' normalization.
    $sepTrim = @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $tgtCmp = if (Test-Path -LiteralPath $TARGET -PathType Container) { (Resolve-Path -LiteralPath $TARGET).Path } else { [System.IO.Path]::GetFullPath($TARGET) }
    $tgtCmp = $tgtCmp.TrimEnd($sepTrim)
    $forbiddenTargets = [System.Collections.Generic.List[string]]::new()
    foreach ($sub in @('.claude', '.codex', '.hermes')) { $forbiddenTargets.Add((Join-Path $repoRoot $sub)) }
    if ($env:AI_CONFIG_FORBID_TARGETS) {
        foreach ($ft in ($env:AI_CONFIG_FORBID_TARGETS -split [IO.Path]::PathSeparator)) {
            if ($ft) { $forbiddenTargets.Add($ft) }
        }
    }
    foreach ($colo in $forbiddenTargets) {
        # Canonicalize an existing forbidden dir so the compare matches $tgtCmp's
        # normalization; else GetFullPath the raw string. Trim a trailing separator.
        $coloNorm = if (Test-Path -LiteralPath $colo -PathType Container) { (Resolve-Path -LiteralPath $colo).Path } else { [System.IO.Path]::GetFullPath($colo) }
        $coloNorm = $coloNorm.TrimEnd($sepTrim)
        if ($tgtCmp -eq $coloNorm) {
            Die "refusing to render harness '$Harness' into the live config dir $tgtCmp — this build uses a throwaway local.env ($LOCAL_ENV) but $targetEnvVar resolved to a live config dir (the inherited $targetEnvVar leaked in because that local.env did not set it). Set $targetEnvVar to a temp dir in the local.env or pass -Out; set AI_CONFIG_ALLOW_LIVE_TARGET=1 to override."
        }
    }
}

New-Item -ItemType Directory -Path $TARGET -Force | Out-Null
# Canonicalize $TARGET to an absolute path. A relative -Out would otherwise
# leak relative `command` paths into the generated settings.json hook entries.
$TARGET = (Resolve-Path -LiteralPath $TARGET).Path

# The claude entrypoint templates reference the harness's own config-dir token
# (@@CLAUDE_CONFIG_DIR@@ — the rendered SKILLS.md catalog path). Resolve that
# token from the EFFECTIVE target: under -Out (or a fixture local.env that
# leaves the var unset) the raw env var is empty or points elsewhere, but the
# rendered files live at $TARGET — the only truthful substitution value.
# Process-scoped (default), mirroring the bash twin's export.
[Environment]::SetEnvironmentVariable($targetEnvVar, $TARGET)

# A real install builds under $TARGET so the final swap is an atomic same-
# filesystem rename. A -DryRun never swaps, so it builds in a NEUTRAL system temp
# instead — the live target is then never written to (not even a transient
# .install-build.*), which also lets -DryRun run against a read-only target.
# (cross-model adversarial finding.)
if ($DryRun) {
    $BUILD = Join-Path ([IO.Path]::GetTempPath()) ("aos-dryrun." + [Guid]::NewGuid().Guid.Substring(0,8))
} else {
    $BUILD = Join-Path $TARGET (".install-build." + [Guid]::NewGuid().Guid.Substring(0,8))
}
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
        # @@RESCUE_INVOCATION@@ (stuck-detector): the rescue capability is
        # operator-local (Shape C) — generic phrasing unless local.env names
        # the skill via RESCUE_SKILL_NAME (mirrors install.sh install_hook).
        # Gated on a strict skill-name allowlist: the value lands in GENERATED
        # HOOK SOURCE, so anything but a plain name gets a warning and the
        # generic phrasing, never raw interpolation (panel finding).
        $rescueInvocation = 'invoke your cross-model rescue capability'
        if ($env:RESCUE_SKILL_NAME) {
            if ($env:RESCUE_SKILL_NAME -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
                $rescueInvocation = 'invoke the `' + $env:RESCUE_SKILL_NAME + '` skill'
            } else {
                Warn 'RESCUE_SKILL_NAME is not a plain skill name (allowed: letters/digits/._-, no leading punctuation) - using generic rescue phrasing'
            }
        }
        $resolved = $resolved.Replace('@@RESCUE_INVOCATION@@', $rescueInvocation)
        Write-LfFile -Path $dst -Content $resolved
    }

    # Dedupe on the FULL event+matcher+script record (matches install.sh): one
    # script may be deliberately wired on two events (stuck-detector counts on
    # PostToolUseFailure and resets on PostToolUse), while re-registering an
    # identical triple stays a no-op.
    $already = $false
    foreach ($rec in $Script:HookBlocks) {
        if ($rec.script -eq $Script -and $rec.event -eq $Event -and $rec.matcher -eq $Matcher) { $already = $true; break }
    }
    if (-not $already) {
        $Script:HookBlocks.Add([pscustomobject]@{
            event   = $Event
            matcher = $Matcher
            script  = $Script
        })
    }
}

# install_hook_script_only — copies + substitutes a hook script into the build
# WITHOUT registering any event wiring (no HookBlocks record, so it never lands in
# the generated hooks.yaml). For tooling shipped alongside the hooks whose
# scheduling is a deliberate operator act (the hermes steward). Mirrors
# install.sh:455-477. Substitutes @@AI_CONFIG_DIR@@ and @@OBSIDIAN_VAULT_PATH@@
# (the configured vault path, or the unset sentinel when no vault is set — the
# vault is optional and the steward hook guards on the vault dir existing).
function Add-HookScriptOnly {
    param([Parameter(Mandatory)][string]$Script)
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
        $resolved = $content.Replace('@@AI_CONFIG_DIR@@', $env:AI_CONFIG_DIR)
        # The vault is optional: substitute the configured path, or the unset
        # sentinel when no vault is set (the steward hook guards on the vault dir
        # existing, so a sentinel path simply no-ops). Leaving the token unresolved
        # would trip Test-Build's unresolved-placeholder gate.
        $vaultVal = if ($env:OBSIDIAN_VAULT_PATH) { $env:OBSIDIAN_VAULT_PATH } else { $VaultUnsetSentinel }
        $resolved = $resolved.Replace('@@OBSIDIAN_VAULT_PATH@@', $vaultVal)
        Write-LfFile -Path $dst -Content $resolved
    }
}

# hook_for_class — enforcement-class -> "script event matcher".
function Resolve-HookForClass {
    param([Parameter(Mandatory)][string]$Class)
    # claude + codex on Windows. Each row mirrors install.sh hook_for_class.
    # Hook script names are .ps1 — the <TEAM>-100 Windows-native fix to the
    # generated hook command shape. The codex matcher is `apply_patch` (codex
    # file edits report tool_name "apply_patch"), event PreToolUse — mirrors
    # install.sh:493 (codex:pre-edit-gate). The hermes matcher is
    # `write_file|patch|terminal` on event `pre_tool_call` (terminal is in the set
    # because the shell can write files) — mirrors install.sh:494 (hermes:pre-edit-gate).
    # `session-end-gate` was removed in <TEAM>-211 (closeout Stop hook removed;
    # closeout is now manual-fire) — no row, mirroring install.sh.
    $rows = @{
        'claude:pre-edit-gate'    = @{ script = 'session-agent.ps1'; event = 'PreToolUse'; matcher = 'Write|Edit|NotebookEdit' }
        'codex:pre-edit-gate'     = @{ script = 'session-agent.ps1'; event = 'PreToolUse'; matcher = 'apply_patch' }
        'hermes:pre-edit-gate'    = @{ script = 'session-agent.ps1'; event = 'pre_tool_call'; matcher = 'write_file|patch|terminal' }
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
                $overlay = $overlay.Replace('@@OPERATOR_SOUL_IDENTITY@@', '')
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
                $overlay = $overlay.Replace('@@OPERATOR_SOUL_IDENTITY@@', '')
            } else {
                [Console]::Error.WriteLine("warning: CODEX_RULES_OVERLAY_PATH=$overlayPath is set but the file does not exist — rendering a spine-only $OutName")
            }
        }
        $content = $content.Replace('@@OPERATOR_CODEX_RULES_OVERLAY@@', $overlay)
    }

    # Operator soul-identity overlay — twin of install.sh compile_entrypoint. The
    # hermes SOUL template carries the framework operating section plus a single
    # @@OPERATOR_SOUL_IDENTITY@@ marker; the operator's PERSONAL identity (named by
    # SOUL_IDENTITY_PATH) is NEVER shipped to the public template (it carries
    # operator PII + machine paths). Splice it at the marker, or empty for an
    # identity-less spine render — exactly what a fresh clone with no
    # SOUL_IDENTITY_PATH gets. Strip trailing newlines to match bash's $(cat); done
    # before the @@VAR@@ loop so any path tokens inside the identity resolve. Only
    # the SOUL template carries this marker.
    if ($content.Contains('@@OPERATOR_SOUL_IDENTITY@@')) {
        $overlay = ''
        $overlayPath = [Environment]::GetEnvironmentVariable('SOUL_IDENTITY_PATH')
        if ($overlayPath) {
            if (Test-Path -LiteralPath $overlayPath -PathType Leaf) {
                $overlay = (Get-RawText -Path $overlayPath) -replace '(\r?\n)+\z', ''
                # Never let the identity payload reintroduce ANY overlay marker
                # (single-pass splice). Also strip @@CAPABILITY_CATALOG@@: the @@VAR@@
                # loop SKIPS that token, so a literal catalog marker in the identity
                # prose would survive to the final catalog substitution and graft a
                # second capability table into the identity section. Mirrors
                # install.sh:398-408.
                $overlay = $overlay.Replace('@@OPERATOR_SOUL_IDENTITY@@', '')
                $overlay = $overlay.Replace('@@OPERATOR_SKILLS_OVERLAY@@', '')
                $overlay = $overlay.Replace('@@OPERATOR_CODEX_RULES_OVERLAY@@', '')
                $overlay = $overlay.Replace('@@CAPABILITY_CATALOG@@', '')
            } else {
                # SET-but-missing — warn loudly, still render an identity-less spine.
                [Console]::Error.WriteLine("warning: SOUL_IDENTITY_PATH=$overlayPath is set but the file does not exist — rendering an identity-less spine $OutName")
            }
        }
        $content = $content.Replace('@@OPERATOR_SOUL_IDENTITY@@', $overlay)
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
        # The vault is optional: render the unset sentinel rather than dying so a
        # no-vault clone still builds. Every other path placeholder stays required.
        if (-not $val -and $var -eq 'OBSIDIAN_VAULT_PATH') {
            $val = $VaultUnsetSentinel
        }
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
# generate_hermes_hooks — emits hooks/hooks.yaml (the copy-paste wiring snippet,
# since config.yaml is user-owned) + copies the agentic-os-hook-bridge plugin.
#
# Mirrors install.sh:596-630, with two PS-twin divergences:
#  - Command shape: each entry uses the pwsh launcher (command 'pwsh' + args
#    [-NoProfile, -File, <abs>.ps1]) instead of bash's bare `command: "<abs>.sh"`,
#    since a .ps1 path is non-executable on Windows. Hermes's config.yaml hooks are
#    Claude-Code-compatible (adapter Fact 2), so the same command/args shape the
#    claude New-Settings ships applies.
#  - The hook path is forward-slashed: pwsh -File accepts '/' on Windows, and
#    forward slashes mean the baked path carries NO backslashes — so command/args
#    use DOUBLE-quoted YAML scalars. (A backslash would be a YAML escape; an
#    apostrophe in the path — common in Windows usernames like O'Brien — is literal
#    in double-quotes but would PREMATURELY CLOSE a single-quoted scalar unless
#    doubled. Windows forbids '"' in path names, so double-quotes are fully safe.)
#    The matcher is double-quoted too (regex, no backslashes), matching the bash
#    snippet's quoting.
# Events are grouped (YAML forbids duplicate mapping keys) in first-seen order,
# identical to the bash double-loop, so the snippet structure stays in parity.
# ---------------------------------------------------------------------------

function New-HermesHooks {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Generated by install.ps1 --harness hermes — DO NOT hand-edit.')
    $lines.Add("# Merge this block into $TARGET/config.yaml (hooks: + plugins.enabled),")
    $lines.Add('# then approve the hooks on first use (TTY prompt or --accept-hooks).')
    $lines.Add('hooks:')
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($rec in $Script:HookBlocks) {
        if (-not $seen.Add($rec.event)) { continue }   # one header per event
        $lines.Add("  $($rec.event):")
        foreach ($e in $Script:HookBlocks) {
            if ($e.event -ne $rec.event) { continue }
            # Absolute path in the FINAL target, forward-slashed (no YAML escaping).
            $hookAbs = (Join-Path $TARGET 'hooks' $e.script) -replace '\\', '/'
            if ($e.matcher) {
                $lines.Add("    - matcher: `"$($e.matcher)`"")
                $lines.Add("      command: `"pwsh`"")
            } else {
                $lines.Add("    - command: `"pwsh`"")
            }
            $lines.Add('      args:')
            $lines.Add("        - `"-NoProfile`"")
            $lines.Add("        - `"-File`"")
            $lines.Add("        - `"$hookAbs`"")
        }
    }
    $lines.Add('plugins:')
    $lines.Add('  enabled:')
    $lines.Add('    - agentic-os-hook-bridge')

    $outYaml = Join-Path (Join-Path $BUILD 'hooks') 'hooks.yaml'
    Write-LfFile -Path $outYaml -Content (($lines -join "`n") + "`n")

    # Copy the bridge plugin into plugins/ (the desktop app's dashboard entrypoint
    # does not register config.yaml shell hooks natively; the plugin restores
    # engine-level pre_tool_call / pre_llm_call dispatch in the GUI — adapter Fact 2).
    $pluginSrc    = Join-Path (Join-Path (Join-Path $repoRoot 'harnesses') 'hermes' 'plugins') 'agentic-os-hook-bridge'
    $pluginDstDir = Join-Path $BUILD 'plugins'
    if (-not (Test-Path -LiteralPath $pluginDstDir -PathType Container)) {
        New-Item -ItemType Directory -Path $pluginDstDir -Force | Out-Null
    }
    try {
        Copy-Item -LiteralPath $pluginSrc -Destination (Join-Path $pluginDstDir 'agentic-os-hook-bridge') -Recurse -Force -ErrorAction Stop
    } catch {
        Die "failed to copy the agentic-os-hook-bridge plugin: $($_.Exception.Message)"
    }
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

    # Harness plugin sources (hermes: agentic-os-hook-bridge) are installed verbatim
    # — hash every file so a hand-edit registers as source drift. Mirrors
    # install.sh:672-680. No-op for claude/codex (no harnesses/<h>/plugins dir).
    $harnessPlugins = Join-Path $harnessRoot 'plugins'
    if (Test-Path -LiteralPath $harnessPlugins -PathType Container) {
        Get-ChildItem -LiteralPath $harnessPlugins -Recurse -File -ErrorAction SilentlyContinue |
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

# Invoke-AgentsCorender — mirrors the just-installed codex spine skills into
# the repo-level Gemini overlay dir ($env:AGENTS_DIR, conventionally
# <repo>/.agents) byte-identically, with an "agents"-harness manifest so
# check-drift -Auto governs the copy like any other render. Mirrors
# install.sh's corender_agents — see that function for the full rationale
# (Codex >=0.14x discovers repo-root .agents/skills alongside
# $CODEX_HOME/skills; byte-identity keeps the duplicate-name collision
# harmless while Gemini stays fully equipped; the manifest makes hand-edits
# visible as drift instead of a silent re-divergence). Runs only for
# -Harness codex on a real install, and only when AGENTS_DIR is set.
function Invoke-AgentsCorender {
    $adir = $env:AGENTS_DIR.TrimEnd('/', '\')
    $mani = Join-Path $TARGET '.build-manifest.json'
    if (-not (Test-Path -LiteralPath $mani -PathType Leaf)) {
        Die ".agents co-render: codex manifest missing at $mani"
    }

    # A relative AGENTS_DIR resolves against an unpredictable CWD — and a
    # relative spelling of the live overlay would slip past the compare guard
    # below (panel finding). Absolute only, like every other target var.
    if (-not [System.IO.Path]::IsPathRooted($adir)) {
        Die ".agents co-render: AGENTS_DIR must be an absolute path (got '$adir') — set it absolute in local.env"
    }

    # Canonicalize even when the leaf does not exist yet: physically resolve
    # the deepest EXISTING ancestor, then re-append the remainder. A plain
    # exists-only canonicalization lets a symlinked ancestor or dot-segments
    # in a not-yet-created path alias the live overlay past the guard (panel
    # finding). Mirrors the bash twin.
    $acmp = $adir
    $walk = $adir; $tail = ''
    while (-not (Test-Path -LiteralPath $walk -PathType Container)) {
        $parent = Split-Path -Parent $walk
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $walk) { break }
        $leaf = Split-Path -Leaf $walk
        $tail = if ($tail) { Join-Path $leaf $tail } else { $leaf }
        $walk = $parent
    }
    if (Test-Path -LiteralPath $walk -PathType Container) {
        $walkResolved = (Resolve-Path -LiteralPath $walk).Path
        $acmp = if ($tail) { Join-Path $walkResolved $tail } else { $walkResolved }
    }
    $acmp = $acmp.TrimEnd('/', '\')

    # The overlay must be disjoint from the codex target: with
    # AGENTS_DIR == CODEX_HOME the manifest rewrite below would replace the
    # codex manifest with the narrowed agents one, destroying drift
    # governance for the codex home (panel finding). Nested either way is
    # the same corruption class. Mirrors the bash twin.
    $tgtResolved = if (Test-Path -LiteralPath $TARGET -PathType Container) {
        (Resolve-Path -LiteralPath $TARGET).Path.TrimEnd('/', '\')
    } else { $TARGET.TrimEnd('/', '\') }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if (($acmp -eq $tgtResolved) -or $acmp.StartsWith("$tgtResolved$sep", [StringComparison]::Ordinal)) {
        Die ".agents co-render: AGENTS_DIR ($acmp) must be disjoint from the codex target ($tgtResolved) — the mirror cannot live at or inside `$CODEX_HOME"
    }
    if ($tgtResolved.StartsWith("$acmp$sep", [StringComparison]::Ordinal)) {
        Die ".agents co-render: the codex target ($tgtResolved) lies inside AGENTS_DIR ($acmp) — the mirror must be disjoint from `$CODEX_HOME"
    }

    # Same live-dir guard rule as the main target (bash twin parity): a
    # throwaway local.env build must never write the repo's live overlay.
    if (($env:AI_CONFIG_ALLOW_LIVE_TARGET -ne '1') -and (-not $isDefaultEnv)) {
        $liveAgents = Join-Path $repoRoot '.agents'
        if (Test-Path -LiteralPath $liveAgents -PathType Container) {
            $liveAgents = (Resolve-Path -LiteralPath $liveAgents).Path
        }
        if ($acmp -eq $liveAgents.TrimEnd('/', '\')) {
            Die "refusing the .agents co-render into the live overlay $acmp — this build uses a throwaway local.env ($LOCAL_ENV) but AGENTS_DIR resolved to the live dir. Set AGENTS_DIR to a temp dir in the local.env; set AI_CONFIG_ALLOW_LIVE_TARGET=1 to override."
        }
    }

    $maniObj = Get-Content -LiteralPath $mani -Raw | ConvertFrom-Json
    $bases = @($maniObj.generated.PSObject.Properties.Name |
        Where-Object { $_.StartsWith('skills/', [StringComparison]::Ordinal) } |
        ForEach-Object { ($_ -split '/')[1] } |
        Select-Object -Unique)
    [Array]::Sort($bases, [System.StringComparer]::Ordinal)
    if ($bases.Count -eq 0) {
        Warn ".agents co-render: codex build generated no skills — nothing to mirror"
        return
    }

    $adirSkills = Join-Path $adir 'skills'
    New-Item -ItemType Directory -Path $adirSkills -Force -ErrorAction Stop | Out-Null

    # Stage the full copy before touching any live subdir, so a mid-copy
    # failure leaves the overlay exactly as it was.
    $stage = Join-Path $adir ('.agents-corender.' + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $stage -Force -ErrorAction Stop | Out-Null
    foreach ($b in $bases) {
        try {
            Copy-Item -LiteralPath (Join-Path (Join-Path $TARGET 'skills') $b) `
                -Destination (Join-Path $stage $b) -Recurse -ErrorAction Stop
        } catch {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            Die ".agents co-render: staging copy of skills/$b failed: $($_.Exception.Message)"
        }
    }

    # N1-style honesty (mirrors the swap path): replacing a live subdir no
    # prior co-render authored is a name collision with operator content —
    # warn, but the framework copy still wins (lockstep with $CODEX_HOME is
    # the contract).
    $oldManaged = @()
    $oldMani = Join-Path $adir '.build-manifest.json'
    if (Test-Path -LiteralPath $oldMani -PathType Leaf) {
        try {
            $oldObj = Get-Content -LiteralPath $oldMani -Raw | ConvertFrom-Json
            $oldManaged = @($oldObj.generated.PSObject.Properties.Name |
                Where-Object { $_.StartsWith('skills/', [StringComparison]::Ordinal) } |
                ForEach-Object { ($_ -split '/')[1] } |
                Select-Object -Unique)
        } catch { $oldManaged = @() }
    }
    foreach ($b in $bases) {
        $live = Join-Path $adirSkills $b
        if ((Test-Path -LiteralPath $live) -and ($oldManaged -notcontains $b)) {
            Warn ".agents co-render: replacing $live (existed but no prior co-render authored it — the mirror must stay in lockstep with the codex render)"
        }
        if (Test-Path -LiteralPath $live) {
            Remove-Item -LiteralPath $live -Recurse -Force -ErrorAction SilentlyContinue
        }
        try {
            Move-Item -LiteralPath (Join-Path $stage $b) -Destination $live -ErrorAction Stop
        } catch {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            Die ".agents co-render: activate of skills/$b failed: $($_.Exception.Message)"
        }
    }
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue

    # Prune bases a PRIOR co-render authored that this build no longer
    # produces — a removed/renamed spine capability must not survive in the
    # overlay as an unmanaged skill (panel finding). Only prior-manifest-
    # managed bases are ever deleted; operator content is untouched. Mirrors
    # the bash twin.
    foreach ($ob in $oldManaged) {
        if ([string]::IsNullOrEmpty($ob)) { continue }
        if ($bases -contains $ob) { continue }
        $stalePath = Join-Path $adirSkills $ob
        if (Test-Path -LiteralPath $stalePath) {
            Remove-Item -LiteralPath $stalePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        [Console]::Error.WriteLine("install.ps1: .agents co-render: pruned stale mirrored skill skills/$ob (authored by a prior co-render, absent from this build)")
    }

    # The agents manifest = the codex manifest narrowed to its skills/ outputs,
    # re-labeled. jq -S keeps the emission byte-parity with the bash twin.
    $json = Get-Content -LiteralPath $mani -Raw
    $sortedOut = $json | & $script:JqBin -S '.harness = "agents" | .generated |= with_entries(select(.key | startswith("skills/")))'
    if ($LASTEXITCODE -ne 0) { Die ".agents co-render: manifest write failed" }
    $sorted = if ($sortedOut -is [array]) { $sortedOut -join "`n" } else { $sortedOut }
    if (-not $sorted) { Die ".agents co-render: manifest canonicalization produced empty output" }
    Write-LfFile -Path (Join-Path $adir '.build-manifest.json') -Content $sorted
    [Console]::Error.WriteLine("install.ps1: co-rendered $($bases.Count) codex spine skill(s) into $adir (byte-identical, drift-governed)")
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
# Get-StateClassification — read-only --dry-run reporter (mirrors install.sh
# classify_state). Compares the LIVE target against the NEW build manifest
# ($BUILD, just written) and the OLD installed manifest ($TARGET\.build-manifest.json,
# if a prior install left one), and prints a classification of every framework-
# managed file. Writes nothing; always succeeds.
#   managed  present and byte-identical to the NEW build (up to date)
#   stale    matches the OLD installed manifest but the NEW build differs — a
#            re-install would UPDATE it (the silently-stale-config gap)
#   broken   present but matches NEITHER manifest — hand-modified/corrupted
#   missing  the NEW build produces it but the target lacks it
#   custom   an operator-authored skills/ or plugins/ subdir the NEW build does
#            not produce — Shape C content the installer PRESERVES, never clobbers
# ---------------------------------------------------------------------------
function Get-StateClassification {
    $newManifest = Join-Path $BUILD '.build-manifest.json'
    $oldManifest = Join-Path $TARGET '.build-manifest.json'
    $haveOld = Test-Path -LiteralPath $oldManifest -PathType Leaf

    $managed = 0; $stale = 0; $broken = 0; $missing = 0; $custom = 0
    $staleList   = New-Object System.Collections.Generic.List[string]
    $brokenList  = New-Object System.Collections.Generic.List[string]
    $missingList = New-Object System.Collections.Generic.List[string]

    # 1) Every generated file the NEW build produces → managed/stale/broken/missing.
    $entries = Get-Content -Raw -LiteralPath $newManifest |
        & $script:JqBin -r '.generated | to_entries[] | "\(.key)\t\(.value)"' 2>$null
    foreach ($line in @($entries)) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        $parts = $line -split "`t", 2
        $rel = $parts[0]
        $newHash = if ($parts.Count -ge 2) { $parts[1] } else { '' }
        $tgtPath = Join-Path $TARGET $rel
        if (-not (Test-Path -LiteralPath $tgtPath)) {
            $missing++; [void]$missingList.Add($rel); continue
        }
        # Present but not a readable regular file (a dir where a file is expected,
        # or an unreadable file) → broken. Never hash it: Get-FileHash on a dir
        # throws a terminating error under StrictMode and aborts the report.
        # (cross-model finding.)
        if (-not (Test-Path -LiteralPath $tgtPath -PathType Leaf)) {
            $broken++; [void]$brokenList.Add($rel); continue
        }
        $got = $null
        try { $got = Get-FileSha256Hex -Path $tgtPath } catch { $got = $null }
        if ($got -and ($got -eq $newHash)) { $managed++; continue }
        $oldHash = ''
        if ($haveOld) {
            $oldHash = Get-Content -Raw -LiteralPath $oldManifest |
                & $script:JqBin -r --arg k $rel '.generated[$k] // empty' 2>$null
            if ($LASTEXITCODE -ne 0) { $oldHash = '' }
        }
        if ($got -and $oldHash -and ($got -eq $oldHash)) {
            $stale++; [void]$staleList.Add($rel)
        } else {
            $broken++; [void]$brokenList.Add($rel)
        }
    }

    # 2) Operator Shape C: a skills/<base>/ or plugins/<base>/ subdir present in the
    # target but NOT produced by the NEW build is operator-authored — PRESERVED.
    # Mirrors check-drift.sh / classify_state's per-subdir managed-set exemption.
    foreach ($name in $Script:PerSubdirPaths) {
        $tgtSub = Join-Path $TARGET $name
        if (-not (Test-Path -LiteralPath $tgtSub -PathType Container)) { continue }
        $mbase = Get-SubdirsFromManifest -ManifestPath $newManifest -Prefix ($name + '/')
        if ($null -eq $mbase) { $mbase = @() }
        $subs = @(Get-ChildItem -LiteralPath $tgtSub -Directory -Force -ErrorAction SilentlyContinue)
        foreach ($sub in $subs) {
            $b = $sub.Name
            # App-written bookkeeping the drift gate exempts is not "custom".
            if ($name -eq 'skills' -and $b.StartsWith('.')) { continue }
            if ($mbase -notcontains $b) { $custom++ }
        }
    }

    # Report (read-only) — to stdout, mirrors the bash twin.
    Write-Output "install.ps1: dry-run state for $Harness at $TARGET"
    if (-not $haveOld) { Write-Output '  (no prior .build-manifest.json — target looks uninstalled; files that differ report as broken)' }
    Write-Output ("  managed: {0}  (present and current)" -f $managed)
    Write-Output ("  stale:   {0}  (an install would UPDATE — framework moved on)" -f $stale)
    foreach ($r in $staleList) { Write-Output "    - $r" }
    Write-Output ("  broken:  {0}  (modified/corrupted on disk — an install would overwrite)" -f $broken)
    foreach ($r in $brokenList) { Write-Output "    - $r" }
    Write-Output ("  missing: {0}  (absent — an install would create)" -f $missing)
    foreach ($r in $missingList) { Write-Output "    - $r" }
    Write-Output ("  custom:  {0}  (operator skills/plugins — PRESERVED, never clobbered)" -f $custom)
    if (($stale + $broken + $missing) -gt 0) {
        Write-Output 'install.ps1: re-run without --dry-run to reconcile managed files (custom content is preserved).'
    } else {
        Write-Output 'install.ps1: target is in sync with the current framework.'
    }
    Write-Output 'install.ps1: no changes written (dry-run).'
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

# Managed paths swapped PER-SUBDIR instead of wholesale (mirrors install.sh's
# PER_SUBDIR_PATHS). plugins is hermes-only (in the hermes ManagedPaths below, not
# claude/codex), so the per-subdir swap, rollback, crash-recovery, and cleanup all
# key off the same shared run-private root and preserve operator-added plugins
# across re-installs. The N1 collision warning runs live on every harness's skills/.
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
    'hermes' {
        # Mirrors install.sh:194-195 — hermes manages a SOUL.md entrypoint, the
        # hooks/ dir (the .ps1 hooks + the generated hooks/hooks.yaml snippet), and
        # the plugins/ dir (the agentic-os-hook-bridge). plugins is in PerSubdirPaths
        # so operator-added plugins survive a re-install. No settings.json/hooks.json
        # — config.yaml is user-owned, so wiring is a surfaced hooks.yaml snippet.
        $Script:ManagedPaths = @('skills', 'hooks', 'plugins', 'SOUL.md', '.build-manifest.json')
        $Script:Entrypoints  = @(
            [pscustomobject]@{ tmpl = 'SOUL.template.md'; out = 'SOUL.md' }
        )
    }
    default { Die "harness '$Harness' not implemented on Windows (known: claude, codex, hermes)" }
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

    # Non-capability hooks (mirrors install.sh:1103-1118). claude + codex wire
    # framework-surface on SessionStart. hermes wires its autonomy-governance set:
    # framework-surface on `pre_llm_call` (NOT SessionStart — Hermes discards the
    # {context} return of on_session_start; pre_llm_call is the injection point),
    # plus autonomy-drain / memory-sanitize / skill-gate (all disabled-by-default or
    # hard-gated), and copies the steward script with NO event wiring (cron
    # registration is a deliberate operator act).
    switch ($Harness) {
        'hermes' {
            Add-Hook -Script 'framework-surface.ps1' -Event 'pre_llm_call'  -Matcher ''
            Add-Hook -Script 'autonomy-drain.ps1'    -Event 'on_session_end' -Matcher ''
            Add-Hook -Script 'memory-sanitize.ps1'   -Event 'pre_tool_call'  -Matcher 'memory'
            Add-Hook -Script 'skill-gate.ps1'        -Event 'pre_tool_call'  -Matcher 'skill_manage'
            Add-HookScriptOnly -Script 'steward.ps1'
        }
        default {
            Add-Hook -Script 'framework-surface.ps1' -Event 'SessionStart' -Matcher 'startup|clear|compact'
        }
    }

    # stuck-detector is a non-capability hook (its declaring capability,
    # cross-model-review, is operator-local Shape C). Claude-only for now; ONE
    # script on TWO events — failure counts the streak, success resets it
    # (mirrors install.sh).
    if ($Harness -eq 'claude') {
        Add-Hook -Script 'stuck-detector.ps1' -Event 'PostToolUseFailure' -Matcher 'Bash'
        Add-Hook -Script 'stuck-detector.ps1' -Event 'PostToolUse'        -Matcher 'Bash'
    }

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
        'hermes' { New-HermesHooks }
        default  { Die "harness '$Harness' has no settings generator" }
    }

    Write-Manifest
    Test-Build

    # --dry-run: classify the live target against the just-built NEW manifest and
    # report, then stop. The finally block removes $BUILD; the live target is never
    # touched. Placed before BuildOnly so a --dry-run report wins if both passed.
    if ($DryRun) {
        Get-StateClassification
        return
    }

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

    # Gemini/.agents co-render (codex-only; see Invoke-AgentsCorender for the
    # full rationale). Gated on AGENTS_DIR so operators without a Gemini
    # overlay are untouched; the skip is loud so a configured-but-forgotten
    # overlay is visible, never silently stale. Mirrors install.sh.
    if ($Harness -eq 'codex') {
        if ($env:AGENTS_DIR) {
            Invoke-AgentsCorender
        } else {
            [Console]::Error.WriteLine('install.ps1: AGENTS_DIR not set — skipping the .agents co-render (set it in local.env if a Gemini/.agents overlay should mirror the codex spine skills)')
        }
    }

    # Catalog-honesty warn (claude-only): every skill dir living under
    # $TARGET/skills/ should appear backtick-quoted in the rendered SKILLS.md —
    # an installed-but-uncataloged skill makes the catalog under-report what
    # this harness can actually do. Advisory only: operator skills arrive
    # outside install.ps1's control, so warn and name the overlay fix, never
    # fail the install. Ordinal sort mirrors the bash twin's LC_ALL=C order.
    $skillsMd = Join-Path $TARGET 'SKILLS.md'
    $skillsDirPath = Join-Path $TARGET 'skills'
    if ($Harness -eq 'claude' -and (Test-Path -LiteralPath $skillsMd) -and (Test-Path -LiteralPath $skillsDirPath)) {
        # -Raw returns $null for a zero-byte file — coalesce so .Contains below
        # cannot throw and crash an otherwise-complete install (advisory warn
        # must never fail the install).
        $catalogText = Get-Content -LiteralPath $skillsMd -Raw
        if ($null -eq $catalogText) { $catalogText = '' }
        $uncataloged = @(Get-ChildItem -LiteralPath $skillsDirPath -Directory |
            Where-Object { -not $catalogText.Contains('`' + $_.Name + '`') } |
            ForEach-Object { $_.Name })
        [Array]::Sort($uncataloged, [System.StringComparer]::Ordinal)
        if ($uncataloged.Count -gt 0) {
            Warn ("skills installed under $TARGET\skills but absent from the rendered SKILLS.md catalog: " + ($uncataloged -join ' ') + " — list them in your skills overlay (SKILLS_OVERLAY_PATH in local.env) so the catalog reports what is actually installed")
        }
    }

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

    # The hermes build is inert until the operator merges the generated wiring into
    # the user-owned config.yaml and consents to the hooks (first-use allowlist).
    # Re-renders rewrite the hook scripts, invalidating prior consent — re-approve
    # after every install. Mirrors install.sh:1210-1217.
    if ($Harness -eq 'hermes') {
        [Console]::Error.WriteLine("install.ps1: NEXT STEP — merge $TARGET\hooks\hooks.yaml into $TARGET\config.yaml")
        [Console]::Error.WriteLine('            (hooks: block + plugins.enabled), then approve the hooks on first')
        [Console]::Error.WriteLine('            use (TTY prompt or `hermes --accept-hooks`); re-approval is needed')
        [Console]::Error.WriteLine('            after every re-render. The agentic-os-hook-bridge plugin restores')
        [Console]::Error.WriteLine('            hook firing in the desktop app (its dashboard entrypoint does not')
        [Console]::Error.WriteLine('            register config.yaml shell hooks natively).')
    }
} finally {
    if (-not $Script:KeepBuild) {
        if ($BUILD -and (Test-Path -LiteralPath $BUILD)) {
            Remove-Item -LiteralPath $BUILD -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
