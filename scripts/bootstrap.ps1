#Requires -Version 7
# bootstrap.ps1 — sets up a fresh Windows machine for the agentic OS.
#
# Usage:
#   bootstrap.ps1 [-Harness <name>] [-Check] [-DryRun]
#                 [-ClaudeConfigDir <dir>] [-VaultDir <dir>] [-CodexHome <dir>]
#
#   -Harness <name>        target harness (repeatable; default: claude). On
#                          Windows only `claude` is supported — install.ps1
#                          gracefully rejects `codex`. The macOS/Linux
#                          bootstrap.sh supports both; full Windows codex parity
#                          is a tracked follow-on.
#   -Check                 read-only — detect requirements, report, exit 1 on failures
#   -DryRun                print mutations without executing them
#   -ClaudeConfigDir <d>   override CLAUDE_CONFIG_DIR
#   -VaultDir <d>          override OBSIDIAN_VAULT_PATH
#   -CodexHome <d>         override CODEX_HOME (no effect on Windows until the
#                          codex harness port lands — <TEAM>-134)

[CmdletBinding()]
param(
  [string[]]$Harness = @("claude"),
  [switch]$Check,
  [switch]$DryRun,
  [string]$ClaudeConfigDir = "",
  [string]$VaultDir = "",
  [string]$CodexHome = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent

# Dot-source the shared local.env parser (<TEAM>-115 — replaces the inline
# get-content-split parser previously inlined twice in this file). The same
# parser is used by scripts/install.ps1 so bootstrap + install agree on
# quoted-value handling, `export` prefix stripping, and malformed-line
# warnings.
. (Join-Path $PSScriptRoot 'lib/local-env.ps1')

function bs_info([string]$msg) { Write-Host "bootstrap.ps1: $msg" }
function bs_warn([string]$msg) { Write-Warning "bootstrap.ps1: $msg" }
function bs_die([string]$msg)  { Write-Error "bootstrap.ps1: ERROR: $msg"; exit 1 }

# would_mutate <desc> — $true if caller should skip mutations.
function would_mutate([string]$desc) {
  if ($Check) { return $true }
  if ($DryRun) { bs_info "DRY-RUN: $desc"; return $true }
  return $false
}

# CLI spec: minimum version, or "presence" for any version.
# <TEAM>-115: `bash` is NO LONGER required. Invoke-RunInstall + Invoke-SmokeTest
# now route through native `install.ps1` / `validate.ps1` via `pwsh -File`.
# A Windows operator with no Git Bash / WSL can run bootstrap.ps1 end-to-end.
# The framework-REQUIRED CLI set is codex, gh, jq, rg (4). The framework wires no
# operator tools, so nothing else belongs in this required map. Keep in lockstep
# with bootstrap.sh check_clis + the entrypoint prose in CLAUDE.md/AGENTS.md
# (inventory-coupling rule).
$cliMin = @{
  codex     = "0.132.0"
  gh        = "2.40.0"
  jq        = "1.6.0"
  rg        = "13.0.0"
}

# winget package IDs for brew-equivalent installs.
$wingetPkg = @{
  gh = "GitHub.cli"
  jq = "jqlang.jq"
  rg = "BurntSushi.ripgrep.MSVC"
}
# npm packages — verified 2026-05-22 against the reference machine (<TEAM>-40 Task 4.1).
$npmPkg = @{
  codex     = "@openai/codex"
}

function Get-CliVersion([string]$name) {
  try {
    # Native multi-line output is captured as an array; -join makes it a
    # single string so -match populates $Matches.
    $out = (& $name --version 2>$null) -join "`n"
    if ($out -match '(\d+\.\d+(\.\d+)?)') { return $Matches[1] }
  } catch {}
  return $null
}

function Test-VersionGe([string]$v1, [string]$v2) {
  try {
    $a = [System.Version]($v1 -replace '[^0-9.]','')
    $b = [System.Version]($v2 -replace '[^0-9.]','')
    return $a -ge $b
  } catch { return $false }
}

$missingClis  = @()
$outdatedClis = @()

function Invoke-CheckClis {
  $ok = $true
  foreach ($name in $cliMin.Keys) {
    $min = $cliMin[$name]
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
      bs_warn "${name}: not found (required)"; $script:missingClis += $name; $ok = $false
    } elseif ($min -eq "presence") {
      bs_info "${name}: present (presence-only)"
    } else {
      $got = Get-CliVersion $name
      if ($got -and (Test-VersionGe $got $min)) {
        bs_info "${name}: $got >= $min"
      } else {
        $disp = if ($got) { $got } else { "unknown" }
        bs_warn "${name}: $disp < $min (need $min)"
        $script:outdatedClis += $name; $ok = $false
      }
    }
  }
  return $ok
}

function Invoke-CheckAuth {
  $ok = $true
  if (Get-Command gh -ErrorAction SilentlyContinue) {
    # A native command's non-zero exit is not a terminating error in PS 7.x,
    # so try/catch would never fire — check $LASTEXITCODE instead.
    & gh auth status >$null 2>&1
    if ($LASTEXITCODE -eq 0) {
      bs_info "gh: authenticated"
    } else {
      bs_warn "gh: not authenticated — run: gh auth login"; $ok = $false
    }
  }
  return $ok
}

function Invoke-InstallClis {
  $need = $missingClis + $outdatedClis
  if ($need.Count -eq 0) { return }
  foreach ($name in $need) {
    if ($wingetPkg.ContainsKey($name)) {
      if (would_mutate "winget install $($wingetPkg[$name])") { continue }
      & winget install --id $wingetPkg[$name] --silent
    } elseif ($npmPkg.ContainsKey($name)) {
      if (would_mutate "npm install -g $($npmPkg[$name])") { continue }
      & npm install -g $npmPkg[$name]
    } else {
      bs_warn "${name}: no automated install method — install manually and re-run."
    }
  }
}

function Set-ConfigDirEnv([string]$configDir) {
  if (-not $configDir) { bs_warn "CLAUDE_CONFIG_DIR not set — skipping User env write"; return }
  $current = [System.Environment]::GetEnvironmentVariable("CLAUDE_CONFIG_DIR", "User")
  if ($current -eq $configDir) { bs_info "CLAUDE_CONFIG_DIR already set correctly"; return }
  if (would_mutate "setenv User CLAUDE_CONFIG_DIR=$configDir") { return }
  [System.Environment]::SetEnvironmentVariable("CLAUDE_CONFIG_DIR", $configDir, "User")
  bs_info "Set CLAUDE_CONFIG_DIR=$configDir in User environment"
}

function Invoke-SeedLocalEnv {
  $localEnv = Join-Path $repoRoot "local.env"
  $tmpl     = Join-Path $repoRoot "templates\local.env.example"
  if (Test-Path $localEnv) { bs_info "local.env exists — skipping template copy"; return }
  if (would_mutate "copy $tmpl -> $localEnv") { return }
  Copy-Item $tmpl $localEnv
  bs_info "Created local.env from template."
  # Pause for the user to fill in local.env before install runs (parity with
  # bootstrap.sh); skip the prompt in non-interactive sessions.
  if ([Environment]::UserInteractive) {
    Read-Host "bootstrap.ps1: Edit $localEnv now, then press Enter to continue" | Out-Null
  } else {
    bs_info "(non-interactive — fill in $localEnv then re-run bootstrap.)"
  }
}

function Persist-LocalEnvValues {
  # <TEAM>-133 (parity with bootstrap.sh persist_local_env_values): write the
  # resolved values (from -ClaudeConfigDir / -CodexHome / -VaultDir flags or the
  # environment) into the freshly seeded local.env BEFORE the reload below.
  # Otherwise Import-LocalEnv re-imports the template's EMPTY value lines and
  # clobbers any environment-inherited values, leaving install.ps1 nothing to
  # substitute (it ALSO needs OBSIDIAN_VAULT_PATH, which has no install.ps1 flag).
  # Idempotent: replaces each KEY= line in place (or appends). Double-quoted so
  # paths with spaces round-trip through Import-LocalEnv (which strips balanced
  # quotes). Writes CRLF-free LF lines via WriteAllText per the PS-port CRLF trap.
  $localEnv = Join-Path $repoRoot "local.env"
  if (-not (Test-Path $localEnv)) { return }
  if (would_mutate "write resolved values into $localEnv") { return }
  $resolved = [ordered]@{
    CLAUDE_CONFIG_DIR   = $env:CLAUDE_CONFIG_DIR
    CODEX_HOME          = $env:CODEX_HOME
    OBSIDIAN_VAULT_PATH = $env:OBSIDIAN_VAULT_PATH
  }
  $lines = [System.IO.File]::ReadAllLines($localEnv)
  foreach ($key in $resolved.Keys) {
    $val = $resolved[$key]
    if (-not $val) { continue }
    $newLine = "$key=`"$val`""
    $wrote = $false
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
      if ($line -match "^(export\s+)?$([regex]::Escape($key))=") {
        if (-not $wrote) { $out.Add($newLine); $wrote = $true }
      } else {
        $out.Add($line)
      }
    }
    if (-not $wrote) { $out.Add($newLine) }
    $lines = $out.ToArray()
  }
  [System.IO.File]::WriteAllText($localEnv, ($lines -join "`n") + "`n")
}

# Resolve the pwsh binary path ONCE — Codex F-2 (<TEAM>-115 review): invoking
# `& pwsh` by name relies on PATH discovery of a SECOND pwsh, which can
# resolve to a different version (or fail entirely) on operator hosts with
# multiple pwsh installs. `[Environment]::ProcessPath` returns the absolute
# path to the SAME pwsh that's running this script. Captured here so both
# Invoke-RunInstall + Invoke-SmokeTest share it.
$script:PwshBin = if ([Environment]::ProcessPath) {
  [Environment]::ProcessPath
} else {
  # Defensive fallback for PS hosts where ProcessPath is null (unusual but
  # possible under embedded runtimes); use Get-Command resolution as a
  # last resort with explicit error if even that fails.
  $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($cmd) { $cmd.Source }
  else      { bs_die "cannot resolve pwsh binary path (ProcessPath null + 'pwsh' not on PATH)" }
}

function Invoke-RunInstall {
  # <TEAM>-115: native PS route — invoke install.ps1 via the SAME pwsh that's
  # running this script (captured in $script:PwshBin above). Removes the prior
  # bash shell-out + bash-required dependency.
  #
  # Use the POSIX `--harness` / `--out` (double-dash) spellings, NOT the
  # single-dash PS-native forms: on Windows, pwsh.exe consumes a single-dash
  # `-Out <dir>` as its own `-OutputFormat` CLI parameter (prefix match) even
  # after `-File`, so it never reaches install.ps1 and the build dies with no
  # target. The double-dash `--out` is not a pwsh CLI parameter, so it passes
  # through to the script verbatim on every platform. install.ps1 parses both
  # spellings from $args (no param binding), so this is unambiguous under both
  # `pwsh -File` and `pwsh -c "& script.ps1"` invocation modes.
  $installPs1 = Join-Path $repoRoot 'scripts' 'install.ps1'
  foreach ($h in $Harness) {
    # <TEAM>-133: forward the in-memory resolved build target as --out. bootstrap
    # seeds local.env from a template whose CLAUDE_CONFIG_DIR / CODEX_HOME are
    # EMPTY, then install.ps1 re-imports that seeded local.env. Without --out the
    # child sees the empty value and dies — even though bootstrap holds the
    # correct target in memory (from -ClaudeConfigDir / -CodexHome, the
    # environment, or a pre-filled local.env). --out takes precedence over the
    # per-harness env var inside install.ps1, so forwarding it makes first-run
    # install succeed. Parity with bootstrap.sh run_install.
    $target = switch ($h) {
      'claude' { $env:CLAUDE_CONFIG_DIR }
      'codex'  { $env:CODEX_HOME }
      default  { $null }
    }
    $outDesc = if ($target) { " --out $target" } else { "" }
    bs_info "Running install.ps1 --harness $h$outDesc ..."
    if (would_mutate "install.ps1 --harness $h$outDesc") { continue }
    if ($target) {
      & $script:PwshBin -NoProfile -File $installPs1 --harness $h --out $target
    } else {
      & $script:PwshBin -NoProfile -File $installPs1 --harness $h
    }
    if ($LASTEXITCODE -ne 0) { bs_die "install.ps1 failed for harness $h" }
  }
}

function Invoke-SmokeTest {
  # <TEAM>-115: native PS route — invoke validate.ps1 + check-drift.ps1 via
  # the captured pwsh binary. Codex F-3 (<TEAM>-115 review): bootstrap.sh's
  # smoke-test calls validate.sh which tail-invokes check-drift.sh; the
  # PS path needs both calls explicit because validate.ps1 deliberately
  # does NOT call check-drift.ps1 (operator/CI runs it out-of-band).
  # Without the explicit check-drift call here, the no-bash route would
  # have STRICTLY LESS smoke coverage than the bash route — regression.
  $validatePs1   = Join-Path $repoRoot 'scripts' 'validate.ps1'
  $checkDriftPs1 = Join-Path $repoRoot 'scripts' 'check-drift.ps1'
  bs_info "Running smoke tests..."
  & $script:PwshBin -NoProfile -File $validatePs1
  if ($LASTEXITCODE -ne 0) { bs_die "validate.ps1 failed" }
  # check-drift.ps1 takes the target dir as -Manifest. Mirrors
  # `make verify`'s drift gate.
  if ($env:CLAUDE_CONFIG_DIR) {
    & $script:PwshBin -NoProfile -File $checkDriftPs1 -Manifest $env:CLAUDE_CONFIG_DIR
    if ($LASTEXITCODE -ne 0) { bs_die "check-drift.ps1 failed" }
  } else {
    bs_warn "CLAUDE_CONFIG_DIR not set — skipping check-drift smoke gate (operator should run 'make verify' after setup)"
  }
  bs_info "Smoke tests passed."
}

function Write-AuthChecklist {
  Write-Host ""
  Write-Host "========================================="
  Write-Host " Manual auth steps (complete after setup)"
  Write-Host "========================================="
  Write-Host "  1. gh auth login       — GitHub CLI"
  Write-Host "  2. codex login         — Codex CLI"
  Write-Host "  3. MCP connectors      — connect operator-local servers as needed"
  Write-Host ""
}

# --- main ---
bs_info "bootstrap.ps1 — agentic OS machine setup (Windows)"
bs_info "Harnesses: $($Harness -join ', ')"
if ($Check)  { bs_info "(check mode — no mutations)" }
if ($DryRun) { bs_info "(dry-run mode — mutations printed only)" }

# Load local.env if present (<TEAM>-115 — via the shared parser).
$localEnv = Join-Path $repoRoot "local.env"
if (Test-Path $localEnv) { Import-LocalEnv -Path $localEnv }
if ($ClaudeConfigDir) { $env:CLAUDE_CONFIG_DIR  = $ClaudeConfigDir }
if ($VaultDir)        { $env:OBSIDIAN_VAULT_PATH = $VaultDir }
if ($CodexHome)       { $env:CODEX_HOME          = $CodexHome }

$exitCode = 0
if (-not (Invoke-CheckClis))  { $exitCode = 1 }
Invoke-CheckAuth | Out-Null  # auth failures are warnings only

if ($Check) {
  if ($exitCode -eq 0) { bs_info "All checks passed." }
  else                 { bs_info "Some checks failed — see warnings above." }
  exit $exitCode
}

Invoke-InstallClis
Invoke-SeedLocalEnv
# <TEAM>-133: materialise the resolved values (flags merged at lines 316-318 /
# environment) into the freshly seeded local.env BEFORE the reload — otherwise
# Import-LocalEnv re-imports the template's EMPTY value lines and clobbers any
# environment-inherited values, leaving install.ps1 nothing to substitute.
Persist-LocalEnvValues
# Reload local.env after seeding (<TEAM>-115 — via the shared parser).
if (Test-Path $localEnv) { Import-LocalEnv -Path $localEnv }
# Re-apply CLI overrides — they take precedence over the reloaded local.env.
if ($ClaudeConfigDir) { $env:CLAUDE_CONFIG_DIR  = $ClaudeConfigDir }
if ($VaultDir)        { $env:OBSIDIAN_VAULT_PATH = $VaultDir }
if ($CodexHome)       { $env:CODEX_HOME          = $CodexHome }
# Persist CLAUDE_CONFIG_DIR after local.env is seeded + reloaded.
Set-ConfigDirEnv $env:CLAUDE_CONFIG_DIR
Invoke-RunInstall
Invoke-SmokeTest
Write-AuthChecklist
