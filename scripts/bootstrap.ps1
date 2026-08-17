#Requires -Version 7
# bootstrap.ps1 — sets up a fresh Windows machine for the agentic OS.
#
# Usage:
#   bootstrap.ps1 [-Harness <name>] [-Check] [-DryRun]
#                 [-ClaudeConfigDir <dir>] [-VaultDir <dir>] [-CodexHome <dir>]
#
#   -Harness <name>        target harness. Default: claude. On Windows claude,
#                          codex, and hermes all build; pass a single `-Harness
#                          claude` / `-Harness codex` / `-Harness hermes`. Do NOT
#                          repeat the flag: PowerShell rejects `-Harness claude
#                          -Harness codex` with "specified more than once", and a
#                          comma value like `-Harness claude,codex` does NOT split
#                          under the documented `pwsh -File` invocation (it binds as
#                          a single literal and is rejected as an unknown harness).
#                          To bootstrap several on Windows, run bootstrap.ps1 once
#                          per harness. The macOS/Linux bootstrap.sh builds all three
#                          via the repeatable POSIX `--harness` form; richer Windows
#                          multi-harness arg handling here is a tracked follow-on.
#   -Check                 read-only — detect requirements, report, exit 1 on failures
#   -DryRun                print mutations without executing them
#   -Scattered             opt out of the co-located default: put claude/codex config
#                          under your home dir (~\.claude, ~\.codex) instead of in the
#                          framework folder. For the maintainer's clean-push clones.
#   -ClaudeConfigDir <d>   override CLAUDE_CONFIG_DIR
#   -VaultDir <d>          override OBSIDIAN_VAULT_PATH
#   -CodexHome <d>         override CODEX_HOME (used when -Harness codex builds on
#                          Windows — <TEAM>-296)
#   -HermesHome <d>        override HERMES_HOME (used when -Harness hermes builds on
#                          Windows — <TEAM>-296; required to build the hermes harness)

[CmdletBinding()]
param(
  [string[]]$Harness = @("claude"),
  [switch]$Check,
  [switch]$DryRun,
  [switch]$Scattered,
  [string]$ClaudeConfigDir = "",
  [string]$VaultDir = "",
  [string]$CodexHome = "",
  [string]$HermesHome = ""
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

# Confirm-HarnessNames — twin of bootstrap.sh validate_harnesses. Reject unknown
# harness names up front, in -Check too. The known set mirrors install.ps1's
# resolution (claude, codex, hermes); keep in lockstep per the inventory-coupling
# rule. Case-insensitive — install.ps1 lowercases names (CLAUDE == claude). claude,
# codex, and hermes all build on Windows now (<TEAM>-296), so this guard only
# catches genuine typos before any check or mutation. Without it, `-Harness typo
# -Check` passes (Invoke-CheckClis never validates names) and only a real run dies,
# deep in install.ps1.
function Confirm-HarnessNames {
  foreach ($h in $Harness) {
    if ($h.ToLower() -notin @('claude','codex','hermes')) {
      bs_die "unknown harness '$h' (known: claude, codex, hermes)"
    }
  }
}

# CLI spec: minimum version, or "presence" for any version.
# <TEAM>-115: `bash` is NO LONGER required. Invoke-RunInstall + Invoke-SmokeTest
# now route through native `install.ps1` / `validate.ps1` via `pwsh -File`.
# A Windows operator with no Git Bash / WSL can run bootstrap.ps1 end-to-end.
# The universal CLIs checked on this (Windows) path are gh, jq, rg. `codex` is
# required ONLY when the codex harness is a build target (<TEAM>-296 — codex now
# builds on Windows): a claude-only operator must not need a second AI harness
# installed. Invoke-CheckClis adds codex to the required set when -Harness codex is
# requested. Keep the universal set in lockstep with bootstrap.sh check_clis + the
# README / new-machine-bootstrap.md prose (inventory-coupling rule).
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

function Resolve-ExecutableCommand([string]$name) {
  # On Windows, PATH can resolve a name to a file PowerShell cannot execute
  # directly (e.g. an extensionless shebang script planted by a test fixture,
  # or a stray datafile named like a CLI). Invoking it falls through to
  # ShellExecute, which pops a GUI "Select an app to open" dialog per probe
  # and returns nothing. Walk ALL candidates in precedence order and return
  # the first shape `&` executes natively — a rejected extensionless hit must
  # not shadow a real <name>.exe later on PATH (cross-model panel finding).
  # Anything left counts as absent; a native PE binary shipped WITHOUT an
  # extension is also rejected — an accepted tradeoff, that shape is
  # vanishingly rare on Windows. POSIX hosts keep plain resolution — an
  # extensionless executable is the normal shape there.
  $candidates = @(Get-Command $name -All -ErrorAction SilentlyContinue)
  foreach ($cmd in $candidates) {
    # Only file-backed shapes are invocable by path everywhere (an alias/
    # function/cmdlet has an empty or module-valued Source and cannot shadow
    # a real executable here).
    if ($cmd.CommandType -notin @('Application', 'ExternalScript')) { continue }
    if ([string]::IsNullOrEmpty($cmd.Source)) { continue }
    if ($IsWindows -and $cmd.CommandType -eq 'Application') {
      $ext = [System.IO.Path]::GetExtension($cmd.Source)
      if ($ext -notin @('.exe', '.cmd', '.bat', '.com')) { continue }
    }
    return $cmd
  }
  return $null
}

function Get-CliVersion([string]$name) {
  try {
    $cmd = Resolve-ExecutableCommand $name
    if (-not $cmd) { return $null }
    # Native multi-line output is captured as an array; -join makes it a
    # single string so -match populates $Matches.
    $out = (& $cmd --version 2>$null) -join "`n"
    if ($out -match '(\d+\.\d+(\.\d+)?)') { return $Matches[1] }
  } catch {}
  return $null
}

function Test-VersionGe([string]$v1, [string]$v2) {
  # Field-compare dot-separated numerics, padding missing segments with 0 — a
  # faithful port of bash version_ge (scripts/bootstrap.sh). NOT [System.Version]:
  # it treats unspecified components as -1, so "2.40" sorts BELOW "2.40.0" (a
  # 2-segment tool version spuriously fails a 3-segment floor), and a single-
  # segment string ("13") throws FormatException — both diverge from bash.
  $a = [regex]::Match($v1, '^[0-9]+(\.[0-9]+)*').Value
  $b = [regex]::Match($v2, '^[0-9]+(\.[0-9]+)*').Value
  if (-not $a) { return $false }   # empty v1 → not >= (bash: return 1)
  if (-not $b) { return $true }    # empty v2 → >=     (bash: return 0)
  $aSeg = $a -split '\.'
  $bSeg = $b -split '\.'
  for ($i = 0; $i -lt 3; $i++) {
    # [double] (not [long]) matches bash version_ge's awk `+0` float coercion and
    # cannot overflow — a pathological huge segment yields +Inf, never a throw (a
    # bare [long] cast would, and the old [System.Version] path crashed too).
    $x = if ($i -lt $aSeg.Count) { [double]$aSeg[$i] } else { 0 }
    $y = if ($i -lt $bSeg.Count) { [double]$bSeg[$i] } else { 0 }
    if ($x -gt $y) { return $true }
    if ($x -lt $y) { return $false }
  }
  return $true   # all 3 segments equal → >=
}

$missingClis  = @()
$outdatedClis = @()

function Invoke-CheckClis {
  $ok = $true
  # gh/jq/rg are the universal requirements. codex is required ONLY when the codex
  # harness is a build target (<TEAM>-296 — codex now builds on Windows): a
  # claude-only operator must not need a second AI harness installed to bootstrap.
  # Mirrors bootstrap.sh check_clis; keep in lockstep per the inventory-coupling
  # rule. $Harness is lowercased at accumulation (CODEX == codex), so an exact
  # -contains test is case-safe and avoids false matches on tokens like 'codex2'.
  $required = @('gh','jq','rg')
  if ($Harness -contains 'codex') { $required = @('codex') + $required }
  foreach ($name in $required) {
    $min = $cliMin[$name]
    if (-not (Resolve-ExecutableCommand $name)) {
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
  $ghCmd = Resolve-ExecutableCommand 'gh'
  if ($ghCmd) {
    # A native command's non-zero exit is not a terminating error in PS 7.x,
    # so try/catch would never fire — check $LASTEXITCODE instead.
    & $ghCmd auth status >$null 2>&1
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

function Set-UserEnvVar([string]$name, [string]$value) {
  # Generalized core of Set-ConfigDirEnv: co-located operation (<TEAM>-297) needs
  # CODEX_HOME persisted to the User environment the same way CLAUDE_CONFIG_DIR
  # always has been, so the codex CLI finds the in-folder config dir. User-scope
  # SetEnvironmentVariable reaches GUI apps too (the Windows GUI bridge — macOS
  # has no equivalent, hence the documented CLI-only ceiling there).
  if (-not $value) { bs_warn "$name not set — skipping User env write"; return }
  $current = [System.Environment]::GetEnvironmentVariable($name, "User")
  if ($current -eq $value) { bs_info "$name already set correctly"; return }
  if (would_mutate "setenv User $name=$value") { return }
  [System.Environment]::SetEnvironmentVariable($name, $value, "User")
  bs_info "Set $name=$value in User environment"
}
function Set-ConfigDirEnv([string]$configDir) {
  Set-UserEnvVar 'CLAUDE_CONFIG_DIR' $configDir
}

function Invoke-SeedLocalEnv {
  $localEnv = Join-Path $repoRoot "local.env"
  $tmpl     = Join-Path $repoRoot "templates\local.env.example"
  if (Test-Path $localEnv) { bs_info "local.env exists — skipping template copy"; return }
  if (would_mutate "copy $tmpl -> $localEnv") { return }
  Copy-Item $tmpl $localEnv
  bs_info "Created local.env from template."
  bs_info "Leave CLAUDE_CONFIG_DIR / CODEX_HOME empty to use the co-located defaults"
  bs_info "(dirs under the framework folder); run with -Scattered for ~\.claude, ~\.codex."
  # Pause for the user to fill in local.env before install runs (parity with
  # bootstrap.sh); skip the prompt in non-interactive sessions.
  if ([Environment]::UserInteractive) {
    Read-Host "bootstrap.ps1: Edit $localEnv now (or press Enter for co-located defaults)" | Out-Null
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
    HERMES_HOME         = $env:HERMES_HOME
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
      'hermes' { $env:HERMES_HOME }
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

function Resolve-ConfigTargets {
  # Twin of bootstrap.sh resolve_config_targets (<TEAM>-297). Fill the stateless
  # claude + codex targets: co-located ($env:AI_CONFIG_DIR\.claude|.codex) by
  # default, or the home dir under -Scattered. -Scattered applies when the target is
  # unset OR still at the co-located default (un-doing a prior default run), but
  # NEVER over an explicit -ClaudeConfigDir/-CodexHome flag or an operator-authored
  # custom path. Hermes is excluded. Called twice in the main flow (before persist +
  # after the reload) so a -DryRun — where persist is skipped and the reload
  # re-imports empty values — still resolves. Idempotent. $ClaudeConfigDir /
  # $CodexHome / $Scattered / $repoRoot are script-scoped + visible here.
  if (-not $env:AI_CONFIG_DIR) { $env:AI_CONFIG_DIR = $repoRoot }
  $coLocClaude = Join-Path $env:AI_CONFIG_DIR '.claude'
  $coLocCodex  = Join-Path $env:AI_CONFIG_DIR '.codex'
  if ($Scattered) {
    $bsHome = [Environment]::GetFolderPath('UserProfile')
    $claudeDefault = Join-Path $bsHome '.claude'
    $codexDefault  = Join-Path $bsHome '.codex'
  } else {
    $claudeDefault = $coLocClaude
    $codexDefault  = $coLocCodex
  }
  if (-not $ClaudeConfigDir) {
    if (-not $env:CLAUDE_CONFIG_DIR) {
      $env:CLAUDE_CONFIG_DIR = $claudeDefault
    } elseif ($Scattered -and $env:CLAUDE_CONFIG_DIR -eq $coLocClaude) {
      $env:CLAUDE_CONFIG_DIR = $claudeDefault   # un-do a prior co-located default
    }
  }
  if (-not $CodexHome) {
    if (-not $env:CODEX_HOME) {
      $env:CODEX_HOME = $codexDefault
    } elseif ($Scattered -and $env:CODEX_HOME -eq $coLocCodex) {
      $env:CODEX_HOME = $codexDefault
    }
  }
}

# --- main ---
# Lowercase harness names on accumulation — parity with bootstrap.sh's --harness
# fold + install.ps1 (CLAUDE == claude). Every downstream consumer
# (Confirm-HarnessNames, Invoke-RunInstall switch) then matches canonically;
# without this a `-Harness Codex` slips past the switch arms to a $null target.
$Harness = @($Harness | ForEach-Object { "$_".ToLower() })

bs_info "bootstrap.ps1 — agentic OS machine setup (Windows)"
bs_info "Harnesses: $($Harness -join ', ')"
if ($Check)  { bs_info "(check mode — no mutations)" }
if ($DryRun) { bs_info "(dry-run mode — mutations printed only)" }

# Reject unknown harness names before any check or mutation, so -Check catches a
# typo too (not just a real run dying later in install.ps1).
Confirm-HarnessNames

# Load local.env if present (<TEAM>-115 — via the shared parser).
$localEnv = Join-Path $repoRoot "local.env"
if (Test-Path $localEnv) { Import-LocalEnv -Path $localEnv }
if ($ClaudeConfigDir) { $env:CLAUDE_CONFIG_DIR  = $ClaudeConfigDir }
if ($VaultDir)        { $env:OBSIDIAN_VAULT_PATH = $VaultDir }
if ($CodexHome)       { $env:CODEX_HOME          = $CodexHome }
if ($HermesHome)      { $env:HERMES_HOME         = $HermesHome }

# Co-located-by-default (<TEAM>-297) — resolve the stateless claude+codex config
# targets (see Resolve-ConfigTargets). Called here so Persist-LocalEnvValues writes
# the resolved value into local.env, AND again after the reload below so a -DryRun
# (where persist is skipped and the reload re-imports an existing local.env's empty
# values) still resolves the target rather than previewing an empty one.
Resolve-ConfigTargets

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
if ($HermesHome)      { $env:HERMES_HOME         = $HermesHome }
# Re-resolve after the reload (<TEAM>-297): in -DryRun the reload re-imports an
# existing local.env's empty values, so re-apply the co-located default here too.
Resolve-ConfigTargets
# Persist CLAUDE_CONFIG_DIR + CODEX_HOME after local.env is seeded + reloaded
# (<TEAM>-297) so a co-located codex dir is picked up by the codex CLI, not merely
# built into the folder. User-scope reaches GUI apps too. Hermes has no env
# export — the app reads its own home dir.
Set-ConfigDirEnv $env:CLAUDE_CONFIG_DIR
Set-UserEnvVar 'CODEX_HOME' $env:CODEX_HOME
Invoke-RunInstall
Invoke-SmokeTest
Write-AuthChecklist
