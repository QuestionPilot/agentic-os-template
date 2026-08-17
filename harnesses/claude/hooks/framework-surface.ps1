#Requires -Version 7
<#
.SYNOPSIS
    Framework-changes + MCP-health + session-agent-directive surfacing
    (Claude Code SessionStart event) — PowerShell port.

.DESCRIPTION
    <TEAM>-100 Windows-native prototype port of harnesses/claude/hooks/framework-surface.sh.

    Three independent blocks emitted in one additionalContext payload:
      1. agentic-os-template git log (last N days) — picks up improvements from prior
         sessions
      2. `claude mcp list` ✓ Connected MCPs — surfaces the <TEAM>-59 silent-
         empty-tools failure mode
      3. session-agent invocation directive

    Filtered to startup/clear/compact via the settings.json matcher.

    @@AI_CONFIG_DIR@@ is a build placeholder — install.ps1 substitutes the
    absolute path to the agentic-os-template checkout from local.env.

    Kill switches:
      CLAUDE_SKIP_FRAMEWORK_SURFACE=1           disables the whole hook
      CLAUDE_SKIP_FRESHNESS_CHECK=1             disables the config-freshness nudge
      CLAUDE_SKIP_LOCAL_HOOK_CHECK=1            disables the orphaned-local-hook check
      CLAUDE_SKIP_MCP_PROBE=1                   disables the MCP-health block
      CLAUDE_SKIP_DISTILLATION_NUDGE=1          disables the distillation-lag nudge
      CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1     disables the session-agent block

    Window:
      CLAUDE_FRAMEWORK_SINCE_DAYS=N             overrides git-log window
                                                (default 10)

    stdin:  SessionStart event JSON — `.source` (startup/clear/compact via the
            matcher) selects the session-agent directive variant; rest unused
    stdout: when surfacing, JSON with hookSpecificOutput.additionalContext
    exit:   always 0 (fail-open; non-zero is a hook error)
#>

$ErrorActionPreference = 'Continue'

if ($env:CLAUDE_SKIP_FRAMEWORK_SURFACE -eq '1') {
    exit 0
}

# jq contract — surfacing hook fails OPEN: missing jq → quiet exit.
if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    exit 0
}

$AI_CONFIG_DIR = '@@AI_CONFIG_DIR@@'
$DAYS = if ($env:CLAUDE_FRAMEWORK_SINCE_DAYS) { $env:CLAUDE_FRAMEWORK_SINCE_DAYS } else { '10' }

# Capture the SessionStart event JSON. Its `source` field (startup/clear/
# compact, per the matcher) selects the session-agent directive variant below —
# a compacted session needs a RE-ORIENT directive, not the "first action this
# session" kickoff. jq is guaranteed here (checked above); on malformed/empty
# input `.source` resolves to empty → kickoff directive (the safe default,
# identical to prior behavior).
$EVENT_JSON = [Console]::In.ReadToEnd()
$SESSION_SOURCE = ''
if ($EVENT_JSON) {
    # Lowercase-normalize for bash↔PS parity (the bash twin canonicalizes via tr).
    $SESSION_SOURCE = "$($EVENT_JSON | & jq -r '.source // empty' 2>$null)".Trim().ToLowerInvariant()
}

# --- 1. agentic-os-template git-log block --------------------------------------------
$GIT_BLOCK = ''
if (Test-Path -LiteralPath (Join-Path $AI_CONFIG_DIR '.git')) {
    $changes = & git -C $AI_CONFIG_DIR log --since="${DAYS}.days.ago" --pretty=format:'- %ad %s (%h)' --date=short 2>$null
    if ($changes) {
        $changesText = if ($changes -is [array]) { $changes -join "`n" } else { $changes }
        $GIT_BLOCK = @"
# Recent agentic-os-template (framework) changes — last $DAYS days

The agentic OS framework has had the following commits recently. Use this to pick
up improvements from prior sessions and know what changed in the operating-system
layer itself:

$changesText

Full details: ``git -C "`$AI_CONFIG_DIR" log --since=$DAYS.days.ago``
Override window: env ``CLAUDE_FRAMEWORK_SINCE_DAYS=N``. Disable: env ``CLAUDE_SKIP_FRAMEWORK_SURFACE=1``.
"@
    }
}

# --- 1b. Config-freshness nudge --------------------------------------------
# Warn when the installed config was rendered from now-stale sources — a fixed
# hook/capability merged to main but install was never re-run, so it sits
# un-activated on this machine. check-drift CANNOT see this (it compares the
# install against its own build-time manifest, never the repo). This block diffs
# the manifest's recorded SOURCE hashes vs the current repo via
# scripts/check-freshness.ps1 and surfaces a soft "re-run install.sh" nudge.
# Soft signal only — never blocks. Fail-open: any error/indeterminate → silent.
$FRESH_BLOCK = ''
if ($env:CLAUDE_SKIP_FRESHNESS_CHECK -ne '1') {
    # Install dir is this hook's own parent (hooks live at <install>/hooks/).
    $INSTALL_DIR = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..') -ErrorAction SilentlyContinue).Path
    $FRESHNESS_SCRIPT = Join-Path $AI_CONFIG_DIR 'scripts/check-freshness.ps1'
    if ($INSTALL_DIR -and (Test-Path -LiteralPath (Join-Path $INSTALL_DIR '.build-manifest.json')) -and (Test-Path -LiteralPath $FRESHNESS_SCRIPT)) {
        # Use the CURRENTLY-RUNNING pwsh executable (resolved from $PID) rather
        # than a bare 'pwsh', so the nested call does not depend on PATH — a
        # PATH miss would leak a command-resolution error to stderr and leave
        # $LASTEXITCODE unset. Fall back to 'pwsh' if the path can't resolve.
        $pwshExe = try { (Get-Process -Id $PID).Path } catch { $null }
        if (-not $pwshExe) { $pwshExe = 'pwsh' }
        $staleList = & $pwshExe -NoProfile -File $FRESHNESS_SCRIPT --manifest $INSTALL_DIR --list 2>$null
        $freshRc = $LASTEXITCODE
        $staleArr = @($staleList | Where-Object { $null -ne $_ -and "$_".Trim() -ne '' })
        # exit 1 = stale (clean non-empty list). 0 = fresh, 2 = indeterminate:
        # both stay silent (fail-open) — only surface a confirmed-stale install.
        if ($freshRc -eq 1 -and $staleArr.Count -gt 0) {
            $staleCount = $staleArr.Count
            $staleBullets = ($staleArr | ForEach-Object { "- $_" }) -join "`n"
            $FRESH_BLOCK = @"


## ⚠ Installed config is stale — re-run install.sh

$staleCount framework source file(s) changed since your last ``install.sh``
render, so your live config may be running outdated hooks/capabilities.
check-drift won't catch this (it detects hand-edits, not staleness). Re-sync:

    pwsh -File `$AI_CONFIG_DIR/scripts/install.ps1 --harness claude

Stale source(s):
$staleBullets

Disable this check: env ``CLAUDE_SKIP_FRESHNESS_CHECK=1``.
"@
        }
    }
}

# --- 1c. Orphaned operator-local hook check ---------------------
# Catch the silent-drop failure mode: an operator-local hook wired in
# settings.local.json whose target script no longer exists on disk (e.g. a
# migration moved the config dir but didn't carry the operator-local file).
# Claude loads settings.local.json hooks, but a missing command file silently
# no-ops — so a dropped hook (a lost SessionStart nudge, a vanished safety
# gate) dies with no error. Warn on any LITERAL ABSOLUTE hook command that does
# not exist (whole path tested first, so embedded spaces are handled; first-token
# fallback for path-plus-args). Relative, $VAR/${VAR}/~, and inline commands are
# left unchecked — they can't be proven missing, so no false positives.
# Fail-open: no settings file / no jq / parse error → silent.
$LOCALHOOK_BLOCK = ''
if ($env:CLAUDE_SKIP_LOCAL_HOOK_CHECK -ne '1') {
    # settings.local.json sits beside the hooks dir (<install>/settings.local.json;
    # this hook lives at <install>/hooks/). Resolve independently of block 1b's
    # INSTALL_DIR — each block carries its own kill switch and must stand alone.
    $LH_INSTALL_DIR = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..') -ErrorAction SilentlyContinue).Path
    if ($LH_INSTALL_DIR) {
        $LH_SETTINGS = Join-Path $LH_INSTALL_DIR 'settings.local.json'
        if (Test-Path -LiteralPath $LH_SETTINGS) {
            # jq emits one command string per line; malformed JSON → empty → silent.
            $lhCmds = & jq -r '.hooks // {} | to_entries[]? | .value[]? | .hooks[]? | .command // empty' $LH_SETTINGS 2>$null
            $lhMissing = @()
            foreach ($lhCmd in @($lhCmds)) {
                if (-not $lhCmd) { continue }
                # Only a ROOTED absolute command is decisively testable. IsPathRooted
                # accepts the native absolute forms of whatever OS runs the .ps1 —
                # Unix '/x', Windows drive 'C:\x', and UNC '\\server\x' — so the PS
                # twin doesn't silently miss native Windows hook paths the way a bare
                # '/*' match would. A Claude hook `command` is a bare script path
                # (args live in a separate "args" field), so test the WHOLE string
                # first (Test-Path -LiteralPath handles embedded spaces — for a
                # config dir whose folder name contains a space); fall back to the first
                # token for the rare "exec arg1 arg2" form. Warn naming the FULL
                # command. Relative / $VAR / ~ forms are out of scope (no false pos).
                if ([System.IO.Path]::IsPathRooted($lhCmd) -and -not (Test-Path -LiteralPath $lhCmd)) {
                    $lhFirst = ("$lhCmd".Trim() -split '\s+', 2)[0]
                    if (-not (Test-Path -LiteralPath $lhFirst)) {
                        $lhMissing += "- $lhCmd"
                    }
                }
            }
            if ($lhMissing.Count -gt 0) {
                $lhBullets = ($lhMissing -join "`n")
                $LOCALHOOK_BLOCK = @"


## ⚠ Operator-local hook is missing its script

``settings.local.json`` wires one or more hooks whose target file does not exist
on disk. Claude loads these settings, but a missing command silently no-ops — so
the hook is dead with no error. This usually means a migration or cleanup moved
the config dir without carrying the operator-local script. Restore the file(s),
or remove the stale entry from ``settings.local.json``:

$lhBullets

Disable this check: env ``CLAUDE_SKIP_LOCAL_HOOK_CHECK=1``.
"@
            }
        }
    }
}

# --- 2. MCP-health probe block ------------------------------------
$MCP_BLOCK = ''
# Resolve `claude` to a shape `&` can execute natively BEFORE probing — on
# Windows an extensionless PATH hit (e.g. a test-planted sh stub) passes a
# presence-only Get-Command check but falls through to ShellExecute inside the
# probe job, popping a GUI "Select an app" dialog. Walk all
# candidates so a rejected hit cannot shadow a real claude.exe later on PATH.
$claudeCmd = $null
foreach ($cand in @(Get-Command claude -All -ErrorAction SilentlyContinue)) {
    # Only file-backed shapes survive into the Start-Job child (an alias/
    # function/cmdlet has an empty or module-valued Source there).
    if ($cand.CommandType -notin @('Application', 'ExternalScript')) { continue }
    if ([string]::IsNullOrEmpty($cand.Source)) { continue }
    if ($IsWindows -and $cand.CommandType -eq 'Application') {
        $ext = [System.IO.Path]::GetExtension($cand.Source)
        if ($ext -notin @('.exe', '.cmd', '.bat', '.com')) { continue }
    }
    $claudeCmd = $cand; break
}
if ($env:CLAUDE_SKIP_MCP_PROBE -ne '1' -and $claudeCmd) {
    # Bound the probe via Start-Job with a 5-second timeout — pwsh-portable
    # equivalent of gtimeout/timeout. Start-Job is available on Windows /
    # macOS / Linux. Capture both stdout AND the wrapped command's
    # $LASTEXITCODE so a non-zero rc (e.g. claude mcp list partial output)
    # discards data — parity with bash framework-surface.sh:79-89.
    #
    # Per Codex confirmation review C-3: $job.State='Completed' is not a
    # rc-of-0 proxy. The job state is Completed even when the wrapped
    # command exited non-zero. Capture $LASTEXITCODE inside the script
    # block via a sentinel object so the consumer can distinguish.
    $job = Start-Job -ScriptBlock {
        param($claudePath)
        $out = & $claudePath mcp list 2>$null
        # Emit a sentinel envelope (last line) so the consumer can split
        # rc from output without re-evaluating $LASTEXITCODE in the parent
        # scope (which is a different scope from the job's $LASTEXITCODE).
        $rc = $LASTEXITCODE
        [pscustomobject]@{ kind = 'mcp-probe-envelope'; out = $out; rc = $rc }
    } -ArgumentList $claudeCmd.Source
    $mcpOut = $null
    if (Wait-Job -Job $job -Timeout 5) {
        $received = Receive-Job -Job $job -ErrorAction SilentlyContinue
        # Filter to the envelope (the job may emit other objects from the
        # wrapped command if claude misbehaves).
        $envelope = $received | Where-Object {
            ($_ -is [pscustomobject]) -and ($_.PSObject.Properties.Name -contains 'kind') -and ($_.kind -eq 'mcp-probe-envelope')
        } | Select-Object -First 1
        if ($envelope -and $envelope.rc -eq 0) {
            $mcpOut = $envelope.out
        }
        if ($job.State -ne 'Completed') { $mcpOut = $null }
    } else {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        $mcpOut = $null
    }
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

    if ($mcpOut) {
        # `claude mcp list` lines:  <source-prefix>: <url-or-cmd> - <glyph> Connected
        # Match the CONNECTED status WITHOUT depending on the leading health
        # glyph (✓). On Windows, native `claude mcp list` stdout is decoded as
        # the console OEM/ANSI codepage rather than UTF-8, so the ✓ arrives as
        # mojibake and a glyph match (the bash twin's `grep -E ' - ✓ Connected$'`,
        # fine under UTF-8) never fires — silently dropping every connector.
        # Key off the ASCII status instead: split on the FINAL ' - ', strip the
        # leading glyph token, and require the REMAINDER to be exactly "Connected".
        # Faithful to bash's exact "✓ Connected" (glyph + the word) — it rejects
        # multi-word failure statuses ("Failed to connect", "✗ Disconnected",
        # "x Not really Connected") that a looser last-token match would surface.
        # -ceq is case-SENSITIVE (PowerShell -match is case-insensitive + unanchored,
        # so a regex would also wrongly accept "disconnected"); the parse avoids both.
        $connected = @($mcpOut | ForEach-Object { $_.ToString() } |
            Where-Object {
                $sepIdx = $_.LastIndexOf(' - ')
                if ($sepIdx -ge 0) {
                    $status = ($_.Substring($sepIdx + 3)).Trim()
                    $sp = $status.IndexOf(' ')
                    if ($sp -ge 0) { ($status.Substring($sp + 1).Trim()) -ceq 'Connected' } else { $false }
                } else {
                    $false
                }
            } |
            ForEach-Object { ($_ -split ': ', 2)[0] } |
            Sort-Object -Unique
        )
        if ($connected.Count -gt 0) {
            $count = $connected.Count
            $items = ($connected | ForEach-Object { "- $_" }) -join "`n"
            $MCP_BLOCK = @"


## MCP connectors (per ``claude mcp list``) — $count ✓ Connected

$items

If any of these MCPs are missing their tools from your session (``ToolSearch``
returns no matches for known tool names), this is the <TEAM>-59 silent-empty-tools
failure mode. Restart Claude Code to populate the deferred-tool catalog.
See ``reference_mcp_silent_empty_tools`` for the full pattern. Disable this probe: env ``CLAUDE_SKIP_MCP_PROBE=1``.
"@
        }
    }
}

# --- 2b. Distillation-lag nudge ---------------------------------
# READ-ONLY kickoff surfacing of scripts/check-distillation-completeness.ps1
# (<TEAM>-364): when one or more feedback/decision memory notes have not been
# distilled into the vault's 04-Lessons layer, say so at session start instead
# of letting the lapse sit invisible until a wipe/migration boundary. A design
# panel explicitly REJECTED a background auto-distillation writer (a
# silent-write + prompt-injection surface), so this block only reads and
# reports — it never writes to the vault or the memory store; the distillation
# itself stays with the operator-driven closeout capability. Invokes the .ps1
# twin checker so Windows stays self-contained (no bash dependency); nested
# pwsh resolved from $PID per block 1b's pattern. Fail-open: missing checker,
# unresolvable dirs (checker exit 2), or any rc other than 1 → block omitted,
# never a hook failure.
$DIST_BLOCK = ''
if ($env:CLAUDE_SKIP_DISTILLATION_NUDGE -ne '1') {
    $DIST_SCRIPT = Join-Path $AI_CONFIG_DIR 'scripts/check-distillation-completeness.ps1'
    if (Test-Path -LiteralPath $DIST_SCRIPT) {
        # The checker derives its dirs from CLAUDE_CONFIG_DIR + OBSIDIAN_VAULT_PATH,
        # either of which may be unset in the hook environment. Resolve both
        # fail-open: the config dir falls back to this hook's own install dir
        # (hooks live at <install>/hooks/, and for the claude harness the
        # install dir IS the config dir); the vault path falls back to the
        # OBSIDIAN_VAULT_PATH key in the framework repo's local.env.
        $distCfg = $env:CLAUDE_CONFIG_DIR
        if (-not $distCfg) {
            $distCfg = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..') -ErrorAction SilentlyContinue).Path
        }
        $distVault = $env:OBSIDIAN_VAULT_PATH
        $distLocalEnv = Join-Path $AI_CONFIG_DIR 'local.env'
        if (-not $distVault -and (Test-Path -LiteralPath $distLocalEnv)) {
            # Minimal no-exec read of ONE key (modeled on scripts/self-audit.ps1
            # Get-SaLocalEnvValue, deliberately smaller). Sourcing/executing
            # local.env here is forbidden: it would run arbitrary operator-file
            # code inside a SessionStart hook, and a hostile PATH= line could
            # poison every command lookup in this hook. Read the LAST
            # OBSIDIAN_VAULT_PATH= assignment as DATA (last wins, like bash
            # sourcing), trim trailing whitespace, and strip one matching
            # surrounding quote pair.
            foreach ($distLn in @(Get-Content -LiteralPath $distLocalEnv -ErrorAction SilentlyContinue)) {
                if ("$distLn" -cmatch '^\s*(export\s+)?OBSIDIAN_VAULT_PATH=(.*)$') {
                    $distVault = $Matches[2] -replace '\s+$', ''
                }
            }
            if ($distVault -and $distVault.Length -ge 2) {
                $dvF = $distVault[0]; $dvL = $distVault[$distVault.Length - 1]
                if (($dvF -eq '"' -and $dvL -eq '"') -or ($dvF -eq "'" -and $dvL -eq "'")) {
                    $distVault = $distVault.Substring(1, $distVault.Length - 2)
                }
            }
        }
        # A dir left unresolved is NOT pre-guarded beyond the cheap fallbacks
        # above — the checker itself exits 2 on an unresolvable path, which
        # stays silent here. Invoke with the resolved dirs as explicit env,
        # restored afterwards (assigning $null/'' to $env: removes the var, so
        # an originally-unset var stays unset for later blocks). Direct nested
        # pwsh, block 1b's pattern — a local file scan needs no Start-Job
        # timeout (that pattern is for the external `claude` CLI probe).
        $pwshExeD = try { (Get-Process -Id $PID).Path } catch { $null }
        if (-not $pwshExeD) { $pwshExeD = 'pwsh' }
        $prevDistCfg = $env:CLAUDE_CONFIG_DIR
        $prevDistVault = $env:OBSIDIAN_VAULT_PATH
        $env:CLAUDE_CONFIG_DIR = $distCfg
        $env:OBSIDIAN_VAULT_PATH = $distVault
        $distOut = & $pwshExeD -NoProfile -File $DIST_SCRIPT 2>&1
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
                $DIST_BLOCK = @"


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

# --- 3. Session-agent invocation directive (<TEAM>-71 + <TEAM>-241) --------------
$SA_BLOCK = ''
if ($env:CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE -ne '1') {
    if ($SESSION_SOURCE -eq 'compact') {
        # Post-compaction re-orient. The SessionStart matcher includes
        # `compact`, so this hook re-fires after a compaction and re-injects — but
        # the stock kickoff directive's "skip if already invoked this session"
        # clause can make the model SKIP re-orienting right when its Mode 1 orient
        # outputs were just summarized out of context. Emit an IDEMPOTENT re-orient
        # instead: re-run Mode 1 ONLY if the orient outputs are gone, else a cheap
        # Mode 2 route — so it cannot blindly double-orient on every compaction.
        # (`resume` is NOT in the matcher, so it never reaches this hook — and a
        # resumed session reloads its transcript, keeping the orient in context.)
        $SA_BLOCK = @"


## Session-agent — re-orient after compacted session

This session was just compacted; your earlier ``session-agent`` Mode 1 orient
context (memory bodies, Linear project/issue state, vault ``START.md``) may have
been summarized out of context. Re-establish orientation:

- If those orient outputs are NO LONGER in your context, re-invoke
  ``session-agent`` (Mode 1) to rebuild them.
- If they are still present, do NOT re-run the orient — a Mode 2 route on the
  next non-trivial prompt is enough.

Disable this directive entirely: env ``CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1``.
"@
    } else {
        # Fresh session (startup / clear / unknown source): the kickoff directive.
        # Per-session gate-marker pointer (<TEAM>-365): the pre-edit gate accepts
        # the R5 declaration from a marker file at <install>/agentic-os/
        # gate-<session_id> — the ONLY channel that works on harness variants
        # (desktop/SDK) whose transcript does not persist assistant text blocks.
        # The model cannot reliably learn its own session_id, so this directive
        # is the canonical place the exact path is surfaced (the pre-edit deny
        # message repeats it as a recovery path). session_id is sanitized to the
        # path-safe alphabet (letters/digits/hyphen) before being embedded in a path; a non-conforming id
        # just drops the pointer (fail-open — the transcript channel still
        # applies). -cmatch: case-sensitive, parity with the bash twin's =~.
        $SA_GATE_NOTE = ''
        $saSessionId = ''
        if ($EVENT_JSON) {
            $saSessionId = "$($EVENT_JSON | & jq -r '.session_id // empty' 2>$null)".Trim()
        }
        if ($saSessionId -cmatch '^[A-Za-z0-9-]+$') {
            $saInstallDir = Split-Path -Parent $PSScriptRoot
            if ($saInstallDir) {
                $saGatePath = Join-Path (Join-Path $saInstallDir 'agentic-os') "gate-$saSessionId"
                $SA_GATE_NOTE = @"


After emitting the R5 routing declaration, ALSO persist it to the pre-edit
gate's marker file — on harness variants that do not persist assistant text
into the transcript (desktop/SDK), the marker is the only declaration channel
the gate can see; elsewhere it is a harmless no-op. Write the declaration
(including the ``Linear gate:`` and ``Lessons:`` lines) to:

    $saGatePath

via a Bash heredoc (mkdir -p the directory first) or the Write tool — a Write
to that exact path is allowed through the gate.
"@
            }
        }
        $SA_BLOCK = @"


## Session-agent — invoke now (Mode 1: kickoff orient)

The ``session-agent`` capability is the spine. **Your first action this session
must be to invoke ``session-agent`` via the Skill tool** — Mode 1 fires the
kickoff orient (memory body-reads + Linear projects-first query + vault
``START.md`` + reconcile this session-start window's commits against memory
headlines), then routes the user's first request.

On every subsequent non-trivial prompt, re-invoke ``session-agent`` (Mode 2:
route only — Mode 1's orient outputs are still live in context).
$SA_GATE_NOTE
Skip this directive if you have already invoked session-agent this session.
Disable the directive entirely: env ``CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1``.
"@
    }
}

if (-not $GIT_BLOCK -and -not $FRESH_BLOCK -and -not $LOCALHOOK_BLOCK -and -not $MCP_BLOCK -and -not $DIST_BLOCK -and -not $SA_BLOCK) {
    exit 0
}

$CONTEXT = "${GIT_BLOCK}${FRESH_BLOCK}${LOCALHOOK_BLOCK}${MCP_BLOCK}${DIST_BLOCK}${SA_BLOCK}"

# Emit JSON via jq for safe escaping (parity with bash hook). Pass the
# multiline context via --arg so jq escapes newlines + quotes correctly.
$jsonOut = & jq -n --arg ctx $CONTEXT '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
Write-Output $jsonOut
exit 0
