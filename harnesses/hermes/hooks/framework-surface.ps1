#Requires -Version 7
# Framework-changes surfacing hook (Hermes pre_llm_call event, first turn only)
# — Windows twin of framework-surface.sh. Surfaces recent agentic-os-template
# commits, a config-freshness nudge, and the session-agent auto-fire directive
# as Hermes context injection ({"context": "..."}).
#
# Wired to pre_llm_call (NOT on_session_start, whose {"context":...} return
# Hermes discards). pre_llm_call fires before every model call, so this hook
# self-gates to the first turn via .extra.is_first_turn. See adapter.md Fact 2.
#
# Kill switches (same env names as the bash twin / other harnesses):
#   CLAUDE_SKIP_FRAMEWORK_SURFACE=1, CLAUDE_SKIP_FRESHNESS_CHECK=1,
#   CLAUDE_SKIP_DISTILLATION_NUDGE=1, CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1,
#   CLAUDE_FRAMEWORK_SINCE_DAYS=N
#
# stdin:  pre_llm_call event JSON — .session_id, .cwd, .extra.is_first_turn
# stdout: on the first turn only, {"context": "..."}; silent on later turns
# exit:   always 0 (fail-open; surfacing hook)

$ErrorActionPreference = 'SilentlyContinue'

if ($env:CLAUDE_SKIP_FRAMEWORK_SURFACE -eq '1') { exit 0 }

$AI_CONFIG_DIR = '@@AI_CONFIG_DIR@@'
$days = if ($env:CLAUDE_FRAMEWORK_SINCE_DAYS) { $env:CLAUDE_FRAMEWORK_SINCE_DAYS } else { '10' }

# Read stdin — the event JSON carries session_id, which the model cannot see
# anywhere else and needs to name its per-session gate file (the edit-gate's
# declaration channel — see hooks/session-agent.ps1).
$inputRaw = [Console]::In.ReadToEnd()
$sessionId = ''
try { $sessionId = [string](($inputRaw | ConvertFrom-Json).session_id) } catch { }

# --- First-turn gate --------------------------------------------------------
# pre_llm_call fires before EVERY model call, so surface ONLY on the first turn.
# Primary signal: .extra.is_first_turn (a JSON boolean → 'True'/'False' once
# stringified). Fallback when the signal is absent (defensive): a per-session
# sentinel so the directive is never injected twice. Mirrors framework-surface.sh.
$isFirst = 'absent'
try {
    $obj = $inputRaw | ConvertFrom-Json
    if ($null -ne $obj.extra -and ($obj.extra.PSObject.Properties.Name -contains 'is_first_turn')) {
        $isFirst = [string]$obj.extra.is_first_turn
    } elseif ($obj.PSObject.Properties.Name -contains 'is_first_turn') {
        $isFirst = [string]$obj.is_first_turn
    }
} catch { }

$sentinel = ''
if ($isFirst -ieq 'false') {
    exit 0
} elseif ($isFirst -ine 'true') {
    # No reliable first-turn signal → dedup via a per-session sentinel. Without a
    # session id we cannot dedup, so fail SAFE (stay silent) rather than re-inject
    # the directive on every model call. Mirrors framework-surface.sh.
    $gateDir = Split-Path -Parent $PSScriptRoot
    if (-not $gateDir -or -not $sessionId) { exit 0 }
    $sentinel = Join-Path $gateDir 'agentic-os' "surfaced-$sessionId"
    if (Test-Path -LiteralPath $sentinel) { exit 0 }
}

# --- 1. agentic-os-template git-log block ---------------------------------
$gitBlock = ''
if (Test-Path -LiteralPath (Join-Path $AI_CONFIG_DIR '.git')) {
    $changes = git -C $AI_CONFIG_DIR log --since="$days.days.ago" --pretty=format:'- %ad %s (%h)' --date=short 2>$null
    if ($changes) {
        $changesText = ($changes -join "`n")
        $gitBlock = @"
# Recent agentic-os-template (framework) changes — last $days days

The agentic OS framework has had the following commits recently. Use this to pick
up improvements from prior sessions and know what changed in the operating-system
layer itself:

$changesText

Full details: ``git -C "`$AI_CONFIG_DIR" log --since=$days.days.ago``
Override window: env ``CLAUDE_FRAMEWORK_SINCE_DAYS=N``. Disable: env ``CLAUDE_SKIP_FRAMEWORK_SURFACE=1``.
"@
    }
}

# --- 1b. Config-freshness nudge --------------------------------------------
$freshBlock = ''
if ($env:CLAUDE_SKIP_FRESHNESS_CHECK -ne '1') {
    $installDir = Split-Path -Parent $PSScriptRoot
    $freshnessScript = Join-Path $AI_CONFIG_DIR 'scripts' 'check-freshness.ps1'
    $manifest = Join-Path $installDir '.build-manifest.json'
    if ($installDir -and (Test-Path -LiteralPath $manifest) -and (Test-Path -LiteralPath $freshnessScript)) {
        # Resolve the running pwsh from $PID (the claude/codex twins already do
        # this) instead of a bare `& pwsh` that relies on PATH — on Windows
        # pwsh.exe is often absent from PATH, so the freshness probe would
        # silently never run. Fail-open: fall back to the PATH name.
        $pwshExe = try { (Get-Process -Id $PID).Path } catch { $null }
        if (-not $pwshExe) { $pwshExe = 'pwsh' }
        $staleList = & $pwshExe -NoProfile -File $freshnessScript -Manifest $installDir -List 2>$null
        $freshRc = $LASTEXITCODE
        if ($freshRc -eq 1 -and $staleList) {
            $staleLines = ($staleList | ForEach-Object { "- $_" }) -join "`n"
            $staleCount = @($staleList).Count
            $freshBlock = @"


## ⚠ Installed config is stale — re-run install.ps1

$staleCount framework source file(s) changed since your last install render, so
your live config may be running outdated hooks/capabilities. Re-sync:

    pwsh `$AI_CONFIG_DIR/scripts/install.ps1 -Harness hermes

Stale source(s):
$staleLines

Disable this check: env ``CLAUDE_SKIP_FRESHNESS_CHECK=1``.
"@
        }
    }
}

# --- 1c. Distillation-lag nudge ---------------------------------
# READ-ONLY kickoff surfacing of scripts/check-distillation-completeness.ps1
# (<TEAM>-364; mirrors the claude twin's block 2b): when one or more
# feedback/decision memory notes have not been distilled into the vault's
# 04-Lessons layer, say so at session start instead of letting the lapse sit
# invisible until a wipe/migration boundary. A design panel explicitly
# REJECTED a background auto-distillation writer (a silent-write +
# prompt-injection surface), so this block only reads and reports — it never
# writes to the vault or the memory store; the distillation itself stays with
# the operator-driven closeout capability. Invokes the .ps1 twin checker so
# Windows stays self-contained (no bash dependency); nested pwsh resolved
# from $PID like the freshness probe. Fail-open: missing checker,
# unresolvable dirs (checker exit 2), or any rc other than 1 → block omitted.
$distBlock = ''
if ($env:CLAUDE_SKIP_DISTILLATION_NUDGE -ne '1') {
    # Slash-joined child (not multi-arg Join-Path) — matches the claude/codex
    # twins so the three dist blocks stay textually parallel.
    $distScript = Join-Path $AI_CONFIG_DIR 'scripts/check-distillation-completeness.ps1'
    if (Test-Path -LiteralPath $distScript) {
        # The checker derives its dirs from CLAUDE_CONFIG_DIR + OBSIDIAN_VAULT_PATH,
        # either of which may be unset in the hook environment. Resolve both
        # fail-open from the framework repo's local.env — read as DATA, never
        # sourced/executed (that would run arbitrary operator-file code inside
        # a session-start hook, and a hostile PATH= line could poison every
        # command lookup here; modeled on scripts/self-audit.ps1
        # Get-SaLocalEnvValue, deliberately smaller). Unlike the claude twin
        # there is NO install-dir fallback for the config dir: this hook's
        # install dir is HERMES_HOME, which does not hold the
        # projects/*/memory store the checker scans. LAST KEY= assignment
        # wins (like bash sourcing); trailing whitespace trimmed; one
        # surrounding quote pair stripped.
        $distLocalEnv = Join-Path $AI_CONFIG_DIR 'local.env'
        function Get-DistLocalEnvValue {
            param([string]$Key)
            $v = ''
            foreach ($distLn in @(Get-Content -LiteralPath $distLocalEnv -ErrorAction SilentlyContinue)) {
                if ("$distLn" -cmatch "^\s*(export\s+)?$Key=(.*)$") {
                    $v = $Matches[2] -replace '\s+$', ''
                }
            }
            if ($v -and $v.Length -ge 2) {
                $dvF = $v[0]; $dvL = $v[$v.Length - 1]
                if (($dvF -eq '"' -and $dvL -eq '"') -or ($dvF -eq "'" -and $dvL -eq "'")) {
                    $v = $v.Substring(1, $v.Length - 2)
                }
            }
            return $v
        }
        $distCfg = $env:CLAUDE_CONFIG_DIR
        if (-not $distCfg) { $distCfg = Get-DistLocalEnvValue -Key 'CLAUDE_CONFIG_DIR' }
        $distVault = $env:OBSIDIAN_VAULT_PATH
        if (-not $distVault) { $distVault = Get-DistLocalEnvValue -Key 'OBSIDIAN_VAULT_PATH' }
        # A dir left unresolved is NOT pre-guarded beyond the cheap fallbacks
        # above — the checker itself exits 2 on an unresolvable path, which
        # stays silent here. Invoke with the resolved dirs as explicit env,
        # restored afterwards (assigning $null/'' to $env: removes the var, so
        # an originally-unset var stays unset for later blocks).
        $pwshExeD = try { (Get-Process -Id $PID).Path } catch { $null }
        if (-not $pwshExeD) { $pwshExeD = 'pwsh' }
        $prevDistCfg = $env:CLAUDE_CONFIG_DIR
        $prevDistVault = $env:OBSIDIAN_VAULT_PATH
        $env:CLAUDE_CONFIG_DIR = $distCfg
        $env:OBSIDIAN_VAULT_PATH = $distVault
        $distOut = & $pwshExeD -NoProfile -File $distScript 2>&1
        $distRc = $LASTEXITCODE
        $env:CLAUDE_CONFIG_DIR = $prevDistCfg
        $env:OBSIDIAN_VAULT_PATH = $prevDistVault
        # ONLY a confirmed lapse (rc 1) surfaces; 0 (all distilled), 2 (usage /
        # unresolvable dirs), and any other rc stay silent.
        if ($distRc -eq 1) {
            # `FAIL undistilled: <name> — …` lines carry the note names in
            # field 3 (memory-note filenames are slugs — never spaces).
            $distNames = @()
            foreach ($distOutLn in @($distOut)) {
                $distS = "$distOutLn"
                if ($distS -cmatch '^FAIL undistilled: ') {
                    $distNames += ($distS -split '\s+')[2]
                }
            }
            # Sorted for cross-twin determinism: the bash checker walks find
            # order, the PS twin sorts — sorting here keeps the surfaced top-5
            # excerpt identical on both sides. StringComparer.Ordinal is the
            # byte-order twin of the bash side's LC_ALL=C sort (Sort-Object's
            # culture-aware comparison can weight `-` differently).
            $distNames = [string[]]$distNames
            [Array]::Sort($distNames, [System.StringComparer]::Ordinal)
            if ($distNames.Count -gt 0) {
                $distCount = $distNames.Count
                $distShown = @($distNames | Select-Object -First 5 | ForEach-Object { "- $_" })
                if ($distCount -gt 5) { $distShown += "- … and $($distCount - 5) more" }
                $distList = $distShown -join "`n"
                $distBlock = @"


## Distillation lag — $distCount feedback/decision note(s) not yet distilled

$distList

These feedback/decision memory notes have not been promoted into the vault's
04-Lessons layer. Promote each into its thematic 04-Lessons note at the next
closeout (capabilities/closeout.md → "Distill this session's feedback"). This
nudge is a read-only lint — it changed nothing. Full list: ``bash
scripts/check-distillation-completeness.sh``.
Disable this nudge: env ``CLAUDE_SKIP_DISTILLATION_NUDGE=1``.
"@
            }
        }
    }
}

# --- 2. Session-agent invocation directive ----------------------------------
$saBlock = ''
if ($env:CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE -ne '1') {
    $saBlock = @"


## Session-agent — invoke now (Mode 1: kickoff orient)

The ``/session-agent`` skill is the spine. **Your first action this session
must be to invoke ``/session-agent``** — Mode 1 fires the kickoff orient
(memory body-reads + Linear projects-first query + vault ``START.md`` +
reconcile this session-start window's commits against memory headlines), then
routes the user's first request.

On every subsequent non-trivial prompt, re-invoke ``/session-agent`` (Mode 2:
route only — Mode 1's orient outputs are still live in context).

Skip this directive if you have already invoked session-agent this session.
Disable the directive entirely: env ``CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1``.
"@
    # Surface the per-session gate path: the edit-gate hook keys on session_id,
    # which the model cannot discover on its own.
    if ($sessionId) {
        $installDirSa = Split-Path -Parent $PSScriptRoot
        if ($installDirSa) {
            $gatePath = Join-Path $installDirSa 'agentic-os' "gate-$sessionId"
            $saBlock += @"


After the R5 routing declaration, open the edit-gate by writing the file
``$gatePath`` via the write_file tool with the full declaration (including the
``Linear gate:`` line) as its content.
"@
        }
    }
}

if (-not $gitBlock -and -not $freshBlock -and -not $distBlock -and -not $saBlock) { exit 0 }

# Sentinel dedup applies only when the first-turn signal was absent (above);
# mark this session surfaced so a later turn stays silent. Best-effort.
if ($sentinel) {
    try {
        $sdir = Split-Path -Parent $sentinel
        if (-not (Test-Path -LiteralPath $sdir)) { New-Item -ItemType Directory -Force -Path $sdir | Out-Null }
        Set-Content -LiteralPath $sentinel -Value '' -NoNewline
    } catch { }
}

$context = "$gitBlock$freshBlock$distBlock$saBlock"
@{ context = $context } | ConvertTo-Json -Compress
exit 0
