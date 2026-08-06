#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/stuck-detector.test.ps1 — Windows-native twin of tests/stuck-detector.test.sh.
#
# Behavioral acceptance for stuck-detector.ps1 (the PS hook install.ps1 renders)
# plus the install.ps1 settings wiring (one script on two events — the
# full-record Add-Hook dedupe must keep both registrations). Mirrors the .sh
# twin 1:1: same scenarios, same assertion labels, same AC count.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$SD_DIR = Join-Path ([IO.Path]::GetTempPath()) ('sd-fix-' + [Guid]::NewGuid().Guid.Substring(0,8))
$SD_OUT = Join-Path $SD_DIR 'target'
New-Item -ItemType Directory -Path $SD_OUT -Force | Out-Null
$SD_ENV = Join-Path $SD_DIR 'local.env'
Write-LocalEnvFixture -EnvFile $SD_ENV -ConfigDir $SD_OUT -VaultDir (Join-Path $SD_DIR 'vault')

$env:AI_CONFIG_LOCAL_ENV = $SD_ENV
try {
    & pwsh -NoProfile -File (Join-Path $env:REPO_ROOT 'scripts' 'install.ps1') --harness claude *>$null
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
$SD_HOOK = Join-Path $SD_OUT 'hooks' 'stuck-detector.ps1'
$SD_STATE_DIR = Join-Path $SD_OUT 'agentic-os'

Assert-File 'stuck-detector: hook rendered into the build' $SD_HOOK

# --- settings.json wiring: one script, two events, both matcher Bash ---------
$sdSettings = Get-Content -LiteralPath (Join-Path $SD_OUT 'settings.json') -Raw | ConvertFrom-Json
function Get-SdMatcher([object]$Entries) {
    # install.ps1 emits the pwsh launcher shape: command 'pwsh' with the script
    # path in args — a bare .ps1 path in `command` is non-executable on Windows.
    foreach ($e in @($Entries)) {
        foreach ($h in @($e.hooks)) {
            $joined = ([string]$h.command) + ' ' + (@($h.args) -join ' ')
            if ($joined -like '*stuck-detector.ps1*') { return [string]$e.matcher }
        }
    }
    return ''
}
Assert-Eq 'stuck-detector: wired on PostToolUseFailure with matcher Bash' 'Bash' (Get-SdMatcher $sdSettings.hooks.PostToolUseFailure)
Assert-Eq 'stuck-detector: wired on PostToolUse with matcher Bash' 'Bash' (Get-SdMatcher $sdSettings.hooks.PostToolUse)

# --- payload builders + runner ------------------------------------------------
function New-SdFailPayload {
    param([string]$Command, [string]$Session = 'sess-A', [string]$ErrorText = "Exit code 1`nboom", [bool]$Interrupt = $false)
    @{ hook_event_name = 'PostToolUseFailure'; tool_name = 'Bash'; session_id = $Session
       tool_input = @{ command = $Command }; error = $ErrorText; is_interrupt = $Interrupt } | ConvertTo-Json -Compress -Depth 4
}
function New-SdOkPayload {
    param([string]$Command, [string]$Session = 'sess-A')
    @{ hook_event_name = 'PostToolUse'; tool_name = 'Bash'; session_id = $Session
       tool_input = @{ command = $Command }
       tool_response = @{ stdout = 'x'; stderr = ''; interrupted = $false } } | ConvertTo-Json -Compress -Depth 4
}
# Invoke-SdHook <payload> [extra env hashtable] -> "<exit>|<stdout>"
function Invoke-SdHook {
    param([string]$Payload, [hashtable]$ExtraEnv = @{})
    foreach ($k in $ExtraEnv.Keys) { Set-Item -Path "Env:$k" -Value $ExtraEnv[$k] }
    try {
        $out = ($Payload | & pwsh -NoProfile -File $SD_HOOK 2>$null) -join "`n"
        $status = $LASTEXITCODE
    } finally {
        foreach ($k in $ExtraEnv.Keys) { Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue }
    }
    return "$status|$out"
}
function Get-SdFired([string]$Result) {
    if (($Result -split '\|', 2)[1] -match '"additionalContext"') { 'fired' } else { 'silent' }
}
function Reset-SdState { Remove-Item -Path (Join-Path $SD_STATE_DIR 'stuck-*') -Force -ErrorAction SilentlyContinue }

# --- fire on the 3rd same-hash failure, silent before, exactly once ----------
Reset-SdState
$r1 = Invoke-SdHook (New-SdFailPayload 'make verify')
$r2 = Invoke-SdHook (New-SdFailPayload 'make verify')
$r3 = Invoke-SdHook (New-SdFailPayload 'make verify')
$r4 = Invoke-SdHook (New-SdFailPayload 'make verify')
Assert-Eq 'stuck-detector: 1st failure exits 0'          '0'      (($r1 -split '\|')[0])
Assert-Eq 'stuck-detector: 1st failure silent'           'silent' (Get-SdFired $r1)
Assert-Eq 'stuck-detector: 2nd failure silent'           'silent' (Get-SdFired $r2)
Assert-Eq 'stuck-detector: 3rd failure fires'            'fired'  (Get-SdFired $r3)
Assert-Eq 'stuck-detector: 3rd failure exits 0'          '0'      (($r3 -split '\|')[0])
Assert-Eq 'stuck-detector: 4th failure silent (once per hash)' 'silent' (Get-SdFired $r4)

# The reminder must carry the rescue invocation (default generic phrasing —
# RESCUE_SKILL_NAME unset in the fixture local.env) and be valid hook JSON.
$sdCtxOk = 'bad'
try {
    $sdJson = (($r3 -split '\|', 2)[1]) | ConvertFrom-Json
    if ($sdJson.hookSpecificOutput.hookEventName -eq 'PostToolUseFailure' -and
        $sdJson.hookSpecificOutput.additionalContext -match 'invoke your cross-model rescue capability' -and
        $sdJson.hookSpecificOutput.additionalContext -match 'CLAUDE_SKIP_STUCK_DETECTOR') { $sdCtxOk = 'ok' }
} catch { $sdCtxOk = 'bad' }
Assert-Eq 'stuck-detector: reminder shape + rescue invocation + kill switch' 'ok' $sdCtxOk

# No unresolved render token may survive into the built hook, and a local.env
# that names the operator's rescue skill must land the name in the reminder.
$sdTokenLeft = @(Select-String -LiteralPath $SD_HOOK -Pattern '@@RESCUE_INVOCATION@@' -SimpleMatch).Count
Assert-Eq 'stuck-detector: rescue token resolved in the rendered hook' '0' "$sdTokenLeft"
$SD_NM_DIR = Join-Path ([IO.Path]::GetTempPath()) ('sd-nm-' + [Guid]::NewGuid().Guid.Substring(0,8))
$SD_NM_OUT = Join-Path $SD_NM_DIR 'target'
New-Item -ItemType Directory -Path $SD_NM_OUT -Force | Out-Null
$SD_NM_ENV = Join-Path $SD_NM_DIR 'local.env'
Write-LocalEnvFixture -EnvFile $SD_NM_ENV -ConfigDir $SD_NM_OUT -VaultDir (Join-Path $SD_NM_DIR 'vault')
Add-Content -LiteralPath $SD_NM_ENV -Value 'RESCUE_SKILL_NAME=test-rescue-skill'
$env:AI_CONFIG_LOCAL_ENV = $SD_NM_ENV
try {
    & pwsh -NoProfile -File (Join-Path $env:REPO_ROOT 'scripts' 'install.ps1') --harness claude *>$null
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
$sdNamed = @(Select-String -LiteralPath (Join-Path $SD_NM_OUT 'hooks' 'stuck-detector.ps1') -Pattern 'invoke the `test-rescue-skill` skill' -SimpleMatch).Count
Assert-Eq 'stuck-detector: RESCUE_SKILL_NAME renders the named invocation' '1' "$sdNamed"

# --- success resets the streak ------------------------------------------------
Reset-SdState
Invoke-SdHook (New-SdFailPayload 'curl -s http://x') | Out-Null
Invoke-SdHook (New-SdFailPayload 'curl -s http://x') | Out-Null
Invoke-SdHook (New-SdOkPayload   'curl -s http://x') | Out-Null
$r5 = Invoke-SdHook (New-SdFailPayload 'curl -s http://x')
$r6 = Invoke-SdHook (New-SdFailPayload 'curl -s http://x')
Assert-Eq 'stuck-detector: post-reset 1st failure silent' 'silent' (Get-SdFired $r5)
Assert-Eq 'stuck-detector: post-reset 2nd failure silent' 'silent' (Get-SdFired $r6)
$r7 = Invoke-SdHook (New-SdFailPayload 'curl -s http://x')
Assert-Eq 'stuck-detector: post-reset 3rd consecutive failure fires' 'fired' (Get-SdFired $r7)

# --- distinct commands never trigger ------------------------------------------
Reset-SdState
$ra = Invoke-SdHook (New-SdFailPayload 'ls -la')
$rb = Invoke-SdHook (New-SdFailPayload 'git status')
$rc = Invoke-SdHook (New-SdFailPayload 'pwd')
Assert-Eq 'stuck-detector: three distinct failing commands stay silent' 'silentsilentsilent' `
    ((Get-SdFired $ra) + (Get-SdFired $rb) + (Get-SdFired $rc))

# --- interleaving: per-hash streaks survive other commands in between ---------
Reset-SdState
Invoke-SdHook (New-SdFailPayload 'probe A') | Out-Null
Invoke-SdHook (New-SdFailPayload 'probe B') | Out-Null
Invoke-SdHook (New-SdFailPayload 'probe A') | Out-Null
Invoke-SdHook (New-SdFailPayload 'probe B') | Out-Null
$ri = Invoke-SdHook (New-SdFailPayload 'probe A')
Assert-Eq 'stuck-detector: interleaved distinct command does not break the streak' 'fired' (Get-SdFired $ri)

# --- whitespace variants normalize to the same command ------------------------
Reset-SdState
Invoke-SdHook (New-SdFailPayload 'echo  a') | Out-Null
Invoke-SdHook (New-SdFailPayload 'echo a') | Out-Null
$rw = Invoke-SdHook (New-SdFailPayload '  echo   a ')
Assert-Eq 'stuck-detector: whitespace variants count as the same command' 'fired' (Get-SdFired $rw)

# --- qualification guards: interrupts and non-exit errors never count ---------
Reset-SdState
Invoke-SdHook (New-SdFailPayload 'flaky' 'sess-A' 'Exit code 1' $true) | Out-Null
Invoke-SdHook (New-SdFailPayload 'flaky' 'sess-A' 'Exit code 1' $true) | Out-Null
$rq = Invoke-SdHook (New-SdFailPayload 'flaky' 'sess-A' 'Exit code 1' $true)
Assert-Eq 'stuck-detector: interrupted failures never count' 'silent' (Get-SdFired $rq)
Reset-SdState
Invoke-SdHook (New-SdFailPayload 'denied' 'sess-A' 'Permission to use Bash denied') | Out-Null
Invoke-SdHook (New-SdFailPayload 'denied' 'sess-A' 'Permission to use Bash denied') | Out-Null
$rp = Invoke-SdHook (New-SdFailPayload 'denied' 'sess-A' 'Permission to use Bash denied')
Assert-Eq "stuck-detector: non-'Exit code' errors (denials) never count" 'silent' (Get-SdFired $rp)

# --- kill switch --------------------------------------------------------------
Reset-SdState
Invoke-SdHook (New-SdFailPayload 'kswitch') | Out-Null
Invoke-SdHook (New-SdFailPayload 'kswitch') | Out-Null
$rk = Invoke-SdHook (New-SdFailPayload 'kswitch') @{ CLAUDE_SKIP_STUCK_DETECTOR = '1' }
Assert-Eq 'stuck-detector: kill switch silences the firing call' 'silent' (Get-SdFired $rk)
Assert-Eq 'stuck-detector: kill switch exits 0' '0' (($rk -split '\|')[0])

# --- per-session isolation ----------------------------------------------------
Reset-SdState
Invoke-SdHook (New-SdFailPayload 'shared cmd' 'sess-A') | Out-Null
Invoke-SdHook (New-SdFailPayload 'shared cmd' 'sess-A') | Out-Null
$rs = Invoke-SdHook (New-SdFailPayload 'shared cmd' 'sess-B')
Assert-Eq "stuck-detector: another session's counter is independent" 'silent' (Get-SdFired $rs)

# --- hostile session id: no path escape, no state, silent ---------------------
Reset-SdState
$rh = Invoke-SdHook (New-SdFailPayload 'x' '../../etc/passwd')
Assert-Eq 'stuck-detector: hostile session id exits 0 silent' '0|' $rh
$sdEscaped = @(Get-ChildItem -Path $SD_OUT -Recurse -Filter 'stuck-*' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -notlike '*hooks*' }).Count
Assert-Eq 'stuck-detector: hostile session id writes no state' '0' "$sdEscaped"

# --- reap: stale per-session state older than 7 days is deleted ---------------
Reset-SdState
New-Item -ItemType Directory -Path $SD_STATE_DIR -Force | Out-Null
$sdOld = Join-Path $SD_STATE_DIR 'stuck-old-session'
Set-Content -LiteralPath $sdOld -Value 'x 1 0'
(Get-Item -LiteralPath $sdOld).LastWriteTime = (Get-Date).AddDays(-30)
Invoke-SdHook (New-SdFailPayload 'reaper probe') | Out-Null
$sdReaped = if (Test-Path -LiteralPath $sdOld) { 'stale' } else { 'reaped' }
Assert-Eq 'stuck-detector: stale session state is reaped' 'reaped' $sdReaped

# --- fail-open: the .sh twin's no-jq guard has no PS analogue (ConvertFrom-Json
# is built in), so the two no-jq ACs are mirrored as skips with rationale.
_Skip 'stuck-detector: missing jq fails open (exit 0)' 'jq guard is bash-twin-only; PS parses JSON natively'
_Skip 'stuck-detector: missing jq stays silent' 'jq guard is bash-twin-only; PS parses JSON natively'

# --- non-Bash tools and foreign events are ignored ----------------------------
Reset-SdState
$rt = Invoke-SdHook (@{ hook_event_name = 'PostToolUseFailure'; tool_name = 'Read'; session_id = 'sess-A'; tool_input = @{ command = 'x' }; error = 'Exit code 1' } | ConvertTo-Json -Compress)
Assert-Eq 'stuck-detector: non-Bash tool is ignored' '0|' $rt
$rv = Invoke-SdHook (@{ hook_event_name = 'PreToolUse'; tool_name = 'Bash'; session_id = 'sess-A'; tool_input = @{ command = 'x' } } | ConvertTo-Json -Compress)
Assert-Eq 'stuck-detector: foreign event is ignored' '0|' $rv

# --- varied-work dry run: a realistic mixed stream never fires ----------------
Reset-SdState
$sdDryFired = 0
$sdStream = @(
    @('O', 'git status'), @('O', 'ls -la src'), @('F', 'grep -n missing_symbol src/main.c'),
    @('O', 'grep -rn init src'), @('F', 'cat /tmp/notes-from-last-time.md'), @('O', 'make build'),
    @('F', 'make test'), @('O', 'make test'), @('O', 'git add -A'), @('O', 'git commit -m wip'),
    @('F', 'curl -s https://api.example.com/health'), @('O', 'curl -s https://api.example.com/health'),
    @('O', 'jq . package.json'), @('O', 'npm run lint')
)
foreach ($step in $sdStream) {
    $p = if ($step[0] -eq 'F') { New-SdFailPayload $step[1] 'sess-dry' } else { New-SdOkPayload $step[1] 'sess-dry' }
    if ((Get-SdFired (Invoke-SdHook $p)) -eq 'fired') { $sdDryFired++ }
}
Assert-Eq 'stuck-detector: varied-work dry run never fires' '0' "$sdDryFired"

# --- twin parity: the fired reminder string is byte-identical in the .sh twin --
$sdBash = Get-Command bash -ErrorAction SilentlyContinue
$sdJq   = Get-Command jq -ErrorAction SilentlyContinue
if ($sdBash -and $sdJq) {
    $sdShDir = Join-Path ([IO.Path]::GetTempPath()) ('sd-sh-' + [Guid]::NewGuid().Guid.Substring(0,8))
    New-Item -ItemType Directory -Path (Join-Path $sdShDir 'hooks') -Force | Out-Null
    # The source .sh still carries the render token — apply the same default
    # substitution the installers apply before comparing reminder strings.
    $sdShSrc = Get-Content -LiteralPath (Join-Path $env:REPO_ROOT 'harnesses' 'claude' 'hooks' 'stuck-detector.sh') -Raw
    Set-Content -LiteralPath (Join-Path $sdShDir 'hooks' 'stuck-detector.sh') `
        -Value ($sdShSrc.Replace('@@RESCUE_INVOCATION@@', 'invoke your cross-model rescue capability')) -NoNewline
    $sdShLast = ''
    foreach ($i in 1..3) {
        $sdShLast = ((New-SdFailPayload 'make verify' 'sess-sh') | & bash (Join-Path $sdShDir 'hooks' 'stuck-detector.sh') 2>$null) -join "`n"
    }
    $sdPsMsg = ((($r3 -split '\|', 2)[1]) | ConvertFrom-Json).hookSpecificOutput.additionalContext
    $sdShMsg = try { ($sdShLast | ConvertFrom-Json).hookSpecificOutput.additionalContext } catch { '' }
    Assert-Eq 'stuck-detector: PS twin reminder is byte-identical' $sdShMsg $sdPsMsg
} else {
    _Skip 'stuck-detector: PS twin reminder is byte-identical' 'bash or jq not on PATH'
}

# ============================ panel-driven cases ==============================

# --- cross-command isolation: success of B must not disturb A's streak -------
Reset-SdState
Invoke-SdHook (New-SdFailPayload 'probe iso-A') | Out-Null
Invoke-SdHook (New-SdFailPayload 'probe iso-A') | Out-Null
Invoke-SdHook (New-SdOkPayload   'probe iso-B') | Out-Null
$rx = Invoke-SdHook (New-SdFailPayload 'probe iso-A')
Assert-Eq 'stuck-detector: success of another command preserves the streak' 'fired' (Get-SdFired $rx)

# --- successes never create state records ------------------------------------
Reset-SdState
Invoke-SdHook (New-SdFailPayload 'seed fail') | Out-Null
Invoke-SdHook (New-SdOkPayload 'unseen ok one') | Out-Null
Invoke-SdHook (New-SdOkPayload 'unseen ok two') | Out-Null
$sdLines = @(Get-Content -LiteralPath (Join-Path $SD_STATE_DIR 'stuck-sess-A') -ErrorAction SilentlyContinue).Count
Assert-Eq 'stuck-detector: successes never create state records' '1' "$sdLines"

# --- full reset drops the record; sticky fired survives a success ------------
Reset-SdState
Invoke-SdHook (New-SdFailPayload 'reset drop') | Out-Null
Invoke-SdHook (New-SdOkPayload   'reset drop') | Out-Null
$sdDropped = @(Get-Content -LiteralPath (Join-Path $SD_STATE_DIR 'stuck-sess-A') -ErrorAction SilentlyContinue | Where-Object { $_ }).Count
Assert-Eq 'stuck-detector: a fully-reset record is dropped from state' '0' "$sdDropped"
Reset-SdState
foreach ($i in 1..3) { Invoke-SdHook (New-SdFailPayload 'sticky keep') | Out-Null }
Invoke-SdHook (New-SdOkPayload 'sticky keep') | Out-Null
$sdStickyLine = (Get-Content -LiteralPath (Join-Path $SD_STATE_DIR 'stuck-sess-A') -ErrorAction SilentlyContinue | Select-Object -First 1) -split ' '
Assert-Eq 'stuck-detector: sticky fired flag survives a success reset' '0 1' ($sdStickyLine[1] + ' ' + $sdStickyLine[2])

# --- malformed state lines are filtered on rewrite ---------------------------
Reset-SdState
New-Item -ItemType Directory -Path $SD_STATE_DIR -Force | Out-Null
Set-Content -LiteralPath (Join-Path $SD_STATE_DIR 'stuck-sess-A') -Value "garbage-not-a-record`n"
Invoke-SdHook (New-SdFailPayload 'filter probe') | Out-Null
$sdBad = @(Get-Content -LiteralPath (Join-Path $SD_STATE_DIR 'stuck-sess-A') | Where-Object { $_ -and $_ -notmatch '^[0-9a-f]{64} [0-9]+ [01]$' }).Count
Assert-Eq 'stuck-detector: malformed state lines are filtered on rewrite' '0' "$sdBad"

# --- a fresh contended lock skips the event (fail open, no state change) -----
Reset-SdState
$sdLock = Join-Path $SD_STATE_DIR 'stuck-sess-A.lock'
New-Item -ItemType Directory -Path $sdLock -Force | Out-Null
$rl = Invoke-SdHook (New-SdFailPayload 'locked out')
Assert-Eq 'stuck-detector: contended lock skips silently' '0|' $rl
$sdLockState = if (Test-Path -LiteralPath (Join-Path $SD_STATE_DIR 'stuck-sess-A') -PathType Leaf) { 'written' } else { 'untouched' }
Assert-Eq 'stuck-detector: contended lock leaves state untouched' 'untouched' $sdLockState
Remove-Item -LiteralPath $sdLock -Force -Recurse

# --- storage failure stays silent: chmod semantics are bash-lane coverage ----
_Skip 'stuck-detector: storage failure stays silent' 'read-only-dir simulation is bash-lane coverage (chmod semantics)'
_Skip 'stuck-detector: storage failure does not record fired' 'read-only-dir simulation is bash-lane coverage (chmod semantics)'

# --- absent is_interrupt field still counts ----------------------------------
Reset-SdState
function New-SdNoIntrPayload([string]$Command) {
    @{ hook_event_name = 'PostToolUseFailure'; tool_name = 'Bash'; session_id = 'sess-A'
       tool_input = @{ command = $Command }; error = 'Exit code 1' } | ConvertTo-Json -Compress -Depth 4
}
Invoke-SdHook (New-SdNoIntrPayload 'no intr field') | Out-Null
Invoke-SdHook (New-SdNoIntrPayload 'no intr field') | Out-Null
$rni = Invoke-SdHook (New-SdNoIntrPayload 'no intr field')
Assert-Eq 'stuck-detector: absent is_interrupt field still counts' 'fired' (Get-SdFired $rni)

# --- backticks in the failing command are stripped from the reminder snippet -
Reset-SdState
$rbt = ''
foreach ($i in 1..3) { $rbt = Invoke-SdHook (New-SdFailPayload 'echo `date` now') }
$sdBtCtx = ((($rbt -split '\|', 2)[1]) | ConvertFrom-Json).hookSpecificOutput.additionalContext
# .Contains, not -like: backtick is the ESCAPE character in wildcard patterns,
# so a -like pattern can never express a literal backtick plainly.
$sdBtOk = if ($sdBtCtx.Contains(': `echo date now`. Rescue rule')) { 'ok' } else { "bad: $sdBtCtx" }
Assert-Eq 'stuck-detector: snippet strips backticks (code span stays intact)' 'ok' $sdBtOk

# --- reap deletes stale sessions but preserves the current one ---------------
Reset-SdState
New-Item -ItemType Directory -Path $SD_STATE_DIR -Force | Out-Null
$sdOld2 = Join-Path $SD_STATE_DIR 'stuck-old-two'
Set-Content -LiteralPath $sdOld2 -Value 'x 1 0'
(Get-Item -LiteralPath $sdOld2).LastWriteTime = (Get-Date).AddDays(-30)
Invoke-SdHook (New-SdFailPayload 'reap keep probe') | Out-Null
$sdReapOld = if (Test-Path -LiteralPath $sdOld2) { 'stale' } else { 'reaped' }
$sdReapCur = if (Test-Path -LiteralPath (Join-Path $SD_STATE_DIR 'stuck-sess-A')) { 'kept' } else { 'lost' }
$sdReapPair = $sdReapOld + '-' + $sdReapCur
Assert-Eq 'stuck-detector: reap drops stale sessions and keeps the current one' 'reaped-kept' $sdReapPair

# --- hostile RESCUE_SKILL_NAME falls back to generic phrasing, hook parses ---
$SD_HO_DIR = Join-Path ([IO.Path]::GetTempPath()) ('sd-ho-' + [Guid]::NewGuid().Guid.Substring(0,8))
$SD_HO_OUT = Join-Path $SD_HO_DIR 'target'
New-Item -ItemType Directory -Path $SD_HO_OUT -Force | Out-Null
$SD_HO_ENV = Join-Path $SD_HO_DIR 'local.env'
Write-LocalEnvFixture -EnvFile $SD_HO_ENV -ConfigDir $SD_HO_OUT -VaultDir (Join-Path $SD_HO_DIR 'vault')
Add-Content -LiteralPath $SD_HO_ENV -Value 'RESCUE_SKILL_NAME=bad name with spaces'
$env:AI_CONFIG_LOCAL_ENV = $SD_HO_ENV
try {
    & pwsh -NoProfile -File (Join-Path $env:REPO_ROOT 'scripts' 'install.ps1') --harness claude *>$null
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
    Remove-Item Env:RESCUE_SKILL_NAME -ErrorAction SilentlyContinue
}
$sdHoHook = Join-Path $SD_HO_OUT 'hooks' 'stuck-detector.ps1'
$sdHoGeneric = @(Select-String -LiteralPath $sdHoHook -Pattern 'invoke your cross-model rescue capability' -SimpleMatch).Count
Assert-Eq 'stuck-detector: hostile RESCUE_SKILL_NAME falls back to generic phrasing' '1' "$sdHoGeneric"
$sdHoParses = 'bad'
try { [scriptblock]::Create((Get-Content -Raw -LiteralPath $sdHoHook)) | Out-Null; $sdHoParses = 'ok' } catch { $sdHoParses = 'bad' }
Assert-Eq 'stuck-detector: hook rendered from hostile name still parses' 'ok' $sdHoParses

# --- install idempotency: re-install keeps single wiring per event -----------
$env:AI_CONFIG_LOCAL_ENV = $SD_ENV
try {
    & pwsh -NoProfile -File (Join-Path $env:REPO_ROOT 'scripts' 'install.ps1') --harness claude *>$null
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
$sdSettings2 = Get-Content -LiteralPath (Join-Path $SD_OUT 'settings.json') -Raw | ConvertFrom-Json
function Get-SdWireCount([object]$Entries, [string]$Needle) {
    $n = 0
    foreach ($e in @($Entries)) {
        foreach ($h in @($e.hooks)) {
            $joined = ([string]$h.command) + ' ' + (@($h.args) -join ' ')
            if ($joined -like "*$Needle*") { $n++ }
        }
    }
    return $n
}
$sdWireCounts = (Get-SdWireCount $sdSettings2.hooks.PostToolUseFailure 'stuck-detector').ToString() + ',' +
    (Get-SdWireCount $sdSettings2.hooks.PostToolUse 'stuck-detector').ToString() + ',' +
    (Get-SdWireCount $sdSettings2.hooks.SessionStart 'framework-surface').ToString()
Assert-Eq 'stuck-detector: re-install keeps exactly one wiring per event' '1,1,1' $sdWireCounts
