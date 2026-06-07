#Requires -Version 7
# tests/killswitch-ps.test.ps1 — behavioral PS coverage for the
# CLAUDE_SKIP_* kill switches on the GENERATED.ps1 hooks.
#
# Before the Windows lane had ZERO CLAUDE_SKIP_* kill-switch coverage:
# tests/hooks-behavior.test.ps1 SKIPs every kill-switch label (it covers the
# sh hooks built by install.sh, deferred to the bash twin), and no PS test
# exercised the kill switches at all. An operator on Windows who set
# CLAUDE_SKIP_SESSION_AGENT=1 / CLAUDE_SKIP_FRAMEWORK_SURFACE=1 / etc. had no
# test that the generated.ps1 hooks actually honor the switch.
# (CLAUDE_SKIP_CLOSEOUT was removed — closeout is now manual-fire.)
#
# This file builds the claude harness via `install.ps1 --build-only` and runs
# the GENERATED $BUILD/hooks/*.ps1 (what an operator actually executes on
# Windows), asserting:
# - With the kill switch set, each gate hook EXITS 0 and emits NO block.
# - Without it, the gate hook fails closed / blocks (positive control), so
# the kill-switch PASS is not a vacuous one (the hook would block otherwise).
#
# Per [[reference_ps_port_traps]] #2: external-command output via pipe returns
# array-of-lines; collapse with -join. Per trap #15: -ceq for byte comparison.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$ks_install = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$utf8NoBom  = [System.Text.UTF8Encoding]::new($false)

# --- Build the claude harness into a temp dir via --build-only -------------
$ksTmp = Join-Path ([IO.Path]::GetTempPath()) ('killswitch-ps-' + [Guid]::NewGuid().Guid.Substring(0,8))
New-Item -ItemType Directory -Path $ksTmp -Force | Out-Null
$ksTgt   = Join-Path $ksTmp 'claude-config'
$ksEnv   = Join-Path $ksTmp 'fixture.local.env'
$ksVault = Join-Path $ksTmp 'vault'
New-Item -ItemType Directory -Path $ksTgt   -Force | Out-Null
New-Item -ItemType Directory -Path $ksVault -Force | Out-Null
Write-LocalEnvFixture -EnvFile $ksEnv -ConfigDir $ksTgt -VaultDir $ksVault

$ksGenHooks = $null
try {
    $env:AI_CONFIG_LOCAL_ENV = $ksEnv
    $bo = & pwsh -NoProfile -File $ks_install --harness claude --build-only 2>&1
    $boExit = $LASTEXITCODE
    if ($boExit -eq 0) {
        $lines = @($bo | Where-Object { ($null -ne $_) -and (($_.ToString().Trim()) -ne '') })
        $ksBuildDir = $lines[-1].ToString().Trim()
        $ksGenHooks = Join-Path $ksBuildDir 'hooks'
    }
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}

if (-not $ksGenHooks -or -not (Test-Path -LiteralPath $ksGenHooks -PathType Container)) {
    _Fail 'killswitch-ps.test: --build-only produced generated hooks dir' "build dir/hooks not found"
    foreach ($lbl in @(
        'killswitch-ps.test: session-agent: blocks without kill switch (positive control)',
        'killswitch-ps.test: session-agent: CLAUDE_SKIP_SESSION_AGENT=1 allows (exit 0, no block)',
        'killswitch-ps.test: framework-surface: CLAUDE_SKIP_FRAMEWORK_SURFACE=1 is silent (exit 0, no output)'
    )) { _Skip $lbl 'build did not produce hooks' }
    Remove-Item -LiteralPath $ksTmp -Recurse -Force -ErrorAction SilentlyContinue
    return
}
_Pass 'killswitch-ps.test: --build-only produced generated hooks dir'

# Invoke-Hook — pipe $Payload to `pwsh -File <hook>` with optional env-var
# overrides, capture stdout + exit code. Mirrors the bash run_hook helper.
function Invoke-Hook {
    param(
        [Parameter(Mandatory)][string]$HookPath,
        [string]$Payload = '{}',
        [hashtable]$Env = @{}
    )
    $tmp = [IO.Path]::GetTempFileName()
    $applied = @{}
    try {
        [System.IO.File]::WriteAllText($tmp, $Payload, $utf8NoBom)
        foreach ($k in $Env.Keys) {
            $applied[$k] = [System.Environment]::GetEnvironmentVariable($k)
            [System.Environment]::SetEnvironmentVariable($k, $Env[$k])
        }
        $out = Get-Content -LiteralPath $tmp -Raw | & pwsh -NoProfile -File $HookPath 2>$null
        $code = $LASTEXITCODE
        if ($out -is [array]) { $out = $out -join "`n" }
        $outStr = if ($null -eq $out) { '' } else { [string]$out }
        return [pscustomobject]@{ Out = $outStr; Exit = $code }
    } finally {
        foreach ($k in $applied.Keys) {
            [System.Environment]::SetEnvironmentVariable($k, $applied[$k])
        }
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

# A transcript with NO session-agent invocation + a PreToolUse payload pointing
# at it makes session-agent.ps1 fail closed (block) — the positive control.
$ksTrans = Join-Path $ksTmp 'transcript-empty.jsonl'
[System.IO.File]::WriteAllText($ksTrans, "no skills invoked here`n", $utf8NoBom)
$saPayload = (@{ transcript_path = $ksTrans; tool_name = 'Write' } | ConvertTo-Json -Compress)

$saHook = Join-Path $ksGenHooks 'session-agent.ps1'

# Positive control: WITHOUT the kill switch, session-agent.ps1 blocks.
# Claude Code PreToolUse honors the modern hookSpecificOutput.permissionDecision
# ("deny") channel — NOT the legacy top-level {"decision":"block"} form (a no-op
# on PreToolUse). Key the block detection on the deny shape.
$saNoKill = Invoke-Hook -HookPath $saHook -Payload $saPayload
if ($saNoKill.Exit -eq 0 -and $saNoKill.Out.Contains('"permissionDecision":"deny"')) {
    _Pass 'killswitch-ps.test: session-agent: blocks without kill switch (positive control)'
} else {
    _Fail 'killswitch-ps.test: session-agent: blocks without kill switch (positive control)' "exit=$($saNoKill.Exit) out=$($saNoKill.Out)"
}

# Kill switch: CLAUDE_SKIP_SESSION_AGENT=1 → exit 0, NO block emitted.
$saKill = Invoke-Hook -HookPath $saHook -Payload $saPayload -Env @{ CLAUDE_SKIP_SESSION_AGENT = '1' }
if ($saKill.Exit -eq 0 -and -not $saKill.Out.Contains('"permissionDecision":"deny"')) {
    _Pass 'killswitch-ps.test: session-agent: CLAUDE_SKIP_SESSION_AGENT=1 allows (exit 0, no block)'
} else {
    _Fail 'killswitch-ps.test: session-agent: CLAUDE_SKIP_SESSION_AGENT=1 allows (exit 0, no block)' "exit=$($saKill.Exit) out=$($saKill.Out)"
}

# framework-surface.ps1 — surfacing hook (fail-open). With
# CLAUDE_SKIP_FRAMEWORK_SURFACE=1 it must exit 0 and emit NO additionalContext.
$fsHook = Join-Path $ksGenHooks 'framework-surface.ps1'
$fsKill = Invoke-Hook -HookPath $fsHook -Payload '{}' -Env @{ CLAUDE_SKIP_FRAMEWORK_SURFACE = '1' }
if ($fsKill.Exit -eq 0 -and -not $fsKill.Out.Contains('additionalContext')) {
    _Pass 'killswitch-ps.test: framework-surface: CLAUDE_SKIP_FRAMEWORK_SURFACE=1 is silent (exit 0, no output)'
} else {
    _Fail 'killswitch-ps.test: framework-surface: CLAUDE_SKIP_FRAMEWORK_SURFACE=1 is silent (exit 0, no output)' "exit=$($fsKill.Exit) out=$($fsKill.Out)"
}

Remove-Item -LiteralPath $ksTmp -Recurse -Force -ErrorAction SilentlyContinue
