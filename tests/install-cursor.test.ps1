#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# test-tier: slow
# tests/install-cursor.test.ps1 — Windows-native twin of
# tests/install-cursor.test.sh.
#
# Runs LIVE against the .ps1 build output: build/structure, the Cursor-native
# hooks.json v1 shape (version, FLAT entries, the pwsh launcher command string,
# an omitted empty matcher, failClosed ONLY on the blocking event), drift-gate
# pass, and AGENTS.md placeholder resolution.
#
# The cursor HOOK-BEHAVIOR assertions stay _Skip on this lane, per
# [[feedback_port_parity_vs_regression_split]] + the sibling decision in
# tests/install-hermes.test.ps1: the .ps1 hooks' run-time behavior belongs in
# tests/hooks-ps-parity.test.ps1. The bash twin runs the .sh hook behavior on
# the macOS/Linux lanes.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$INSTALL_PS1     = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$CHECK_DRIFT_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'check-drift.ps1'

# Invoke-CursorInstall — full `install.ps1 --harness cursor` into the target
# named by $EnvFile's CURSOR_CONFIG_DIR. Returns @{ exit; err }.
function Invoke-CursorInstall {
    param([string]$EnvFile)
    $errFile = [IO.Path]::GetTempFileName()
    $env:AI_CONFIG_LOCAL_ENV = $EnvFile
    & pwsh -NoProfile -File $INSTALL_PS1 --harness cursor 1>$null 2>$errFile
    $code = $LASTEXITCODE
    $errText = if (Test-Path -LiteralPath $errFile) { Get-Content -Raw -LiteralPath $errFile } else { '' }
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    return @{ exit = $code; err = $errText }
}

$IC_ROOT  = Join-Path ([IO.Path]::GetTempPath()) ("cursor-test-" + [Guid]::NewGuid().Guid.Substring(0, 8))
New-Item -ItemType Directory -Path $IC_ROOT -Force | Out-Null
$IC_OUT   = Join-Path $IC_ROOT 'cursor-home'
$IC_VAULT = Join-Path $IC_ROOT 'vault'
$IC_ENV   = Join-Path $IC_ROOT 'local.env'
New-Item -ItemType Directory -Path $IC_OUT, $IC_VAULT -Force | Out-Null
Write-CursorEnvFixture -EnvFile $IC_ENV -CursorConfigDir $IC_OUT -VaultDir $IC_VAULT

try {
    $r = Invoke-CursorInstall -EnvFile $IC_ENV
    Assert-Eq 'install-cursor.test: install.ps1 --harness cursor builds clean' '0' "$($r.exit)"

    # --- T1: build output map (.ps1 hooks on the Windows lane) ---------------
    foreach ($f in @(
            'skills/session-agent/SKILL.md',
            'skills/closeout/SKILL.md',
            'skills/self-audit/SKILL.md',
            'hooks/framework-surface.ps1',
            'hooks/session-agent.ps1',
            'hooks.json',
            'AGENTS.md',
            '.build-manifest.json')) {
        Assert-File "install-cursor.test: cursor build produced $f" (Join-Path $IC_OUT $f)
    }

    # Files the build must NEVER write (adapter Fact 5 — user-owned).
    foreach ($f in @('cli-config.json', 'permissions.json', 'sandbox.json', 'mcp.json')) {
        if (Test-Path -LiteralPath (Join-Path $IC_OUT $f)) {
            _Fail "install-cursor.test: cursor build leaves the user-owned $f alone" "build wrote $f"
        } else {
            _Pass "install-cursor.test: cursor build leaves the user-owned $f alone"
        }
    }

    # --- T2: hooks.json is valid, v1-shaped, fail-closed on the gate ONLY ----
    $hooksPath = Join-Path $IC_OUT 'hooks.json'
    $hooks = $null
    try { $hooks = Get-Content -Raw -LiteralPath $hooksPath | ConvertFrom-Json } catch { $hooks = $null }
    if ($null -eq $hooks) {
        _Fail 'install-cursor.test: cursor hooks.json is valid JSON' 'ConvertFrom-Json failed'
    } else {
        _Pass 'install-cursor.test: cursor hooks.json is valid JSON'
        Assert-Eq 'install-cursor.test: hooks.json declares schema version 1' '1' "$($hooks.version)"

        $gate = $hooks.hooks.preToolUse[0]
        Assert-Eq 'install-cursor.test: the pre-edit gate is wired on preToolUse with the Write|Delete matcher' `
            'Write|Delete' "$($gate.matcher)"
        # Cursor's DEFAULT is fail-OPEN on a hook crash/timeout/bad-JSON. A gate
        # shipped without failClosed silently degrades to "allow" the moment
        # anything goes wrong — this is the regression guard for that class.
        Assert-Eq 'install-cursor.test: the gate entry sets failClosed (Cursor defaults to fail-OPEN)' `
            'True' "$($gate.failClosed)"
        # A bare .ps1 path in `command` is non-executable on Windows, and Cursor's
        # entry has no args array — the launcher must be ONE shell string with the
        # hook path quoted so a space in CURSOR_CONFIG_DIR stays one argument.
        $expectedGateCmd = 'pwsh -NoProfile -File "' + (Join-Path $IC_OUT 'hooks' 'session-agent.ps1') + '"'
        Assert-Eq 'install-cursor.test: the gate command is a quoted pwsh launcher string' `
            $expectedGateCmd "$($gate.command)"

        $surface = $hooks.hooks.sessionStart[0]
        $expectedSurfaceCmd = 'pwsh -NoProfile -File "' + (Join-Path $IC_OUT 'hooks' 'framework-surface.ps1') + '"'
        Assert-Eq 'install-cursor.test: framework-surface is wired on sessionStart via the pwsh launcher' `
            $expectedSurfaceCmd "$($surface.command)"
        # A failed context injection must never break a session — the surfacing
        # hook must NOT be fail-closed. Absent property is the correct state.
        if ($surface.PSObject.Properties.Name -contains 'failClosed') {
            _Fail 'install-cursor.test: framework-surface is NOT fail-closed (surfacing hooks fail open)' `
                'failClosed present on the sessionStart entry'
        } else {
            _Pass 'install-cursor.test: framework-surface is NOT fail-closed (surfacing hooks fail open)'
        }
        # sessionStart has no documented matcher field — the key must be OMITTED,
        # not emitted as an empty string (an empty regex is a meaningless filter).
        if ($surface.PSObject.Properties.Name -contains 'matcher') {
            _Fail 'install-cursor.test: sessionStart entry omits the matcher key entirely' `
                'matcher present on the sessionStart entry'
        } else {
            _Pass 'install-cursor.test: sessionStart entry omits the matcher key entirely'
        }
        # Flat entry shape: Cursor's entry IS {command,...} — no nested hooks
        # array and no `type` field (that is the claude/codex shape).
        $nested = @($hooks.hooks.PSObject.Properties.Value |
            ForEach-Object { $_ } |
            Where-Object { $_.PSObject.Properties.Name -contains 'hooks' })
        Assert-Eq 'install-cursor.test: cursor entries are FLAT (no nested hooks array)' '0' "$($nested.Count)"
    }

    # --- T3: drift gate passes a fresh build ---------------------------------
    & pwsh -NoProfile -File $CHECK_DRIFT_PS1 -Manifest $IC_OUT 1>$null 2>$null
    Assert-Eq 'install-cursor.test: check-drift passes the fresh cursor build' '0' "$LASTEXITCODE"

    # A hand-edit to a generated file is drift.
    Add-Content -LiteralPath (Join-Path $IC_OUT 'AGENTS.md') -Value "`n<!-- hand edit -->"
    & pwsh -NoProfile -File $CHECK_DRIFT_PS1 -Manifest $IC_OUT 1>$null 2>$null
    Assert-Eq 'install-cursor.test: check-drift flags a hand-edited cursor AGENTS.md' '1' "$LASTEXITCODE"
    Invoke-CursorInstall -EnvFile $IC_ENV | Out-Null

    # Operator (Shape C) skills survive a re-render and are exempt from the gate.
    $opSkill = Join-Path $IC_OUT 'skills' 'operator-skill'
    New-Item -ItemType Directory -Path $opSkill -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $opSkill 'SKILL.md') `
        -Value "---`nname: operator-skill`ndescription: operator-local`n---`n`nbody`n"
    $r2 = Invoke-CursorInstall -EnvFile $IC_ENV
    Assert-Eq 'install-cursor.test: re-install with an operator skill subdir builds clean' '0' "$($r2.exit)"
    Assert-File 'install-cursor.test: operator skill subdir survives a cursor re-install' `
        (Join-Path $opSkill 'SKILL.md')
    & pwsh -NoProfile -File $CHECK_DRIFT_PS1 -Manifest $IC_OUT 1>$null 2>$null
    Assert-Eq 'install-cursor.test: check-drift exempts the operator-added cursor skill subdir' '0' "$LASTEXITCODE"
    Remove-Item -LiteralPath $opSkill -Recurse -Force -ErrorAction SilentlyContinue

    # --- T4: AGENTS.md placeholder resolution + the catalog ------------------
    $agents = Get-Content -Raw -LiteralPath (Join-Path $IC_OUT 'AGENTS.md')
    Assert-NotContains 'install-cursor.test: AGENTS.md has no unresolved placeholders' $agents '@@'
    Assert-Contains 'install-cursor.test: AGENTS.md carries the session-agent spine directive' `
        $agents '/session-agent'
    Assert-Contains 'install-cursor.test: AGENTS.md carries the generated capability catalog' `
        $agents '| `closeout` |'

    # --- T5/T6: hook behavior — covered on the bash lane + hooks-ps-parity ---
    _Skip 'install-cursor.test: cursor preToolUse gate behavior' `
        'PS hook behavior is covered in tests/hooks-ps-parity.test.ps1; the .sh twin covers it on the bash lanes'
    _Skip 'install-cursor.test: cursor sessionStart surfacing behavior' `
        'PS hook behavior is covered in tests/hooks-ps-parity.test.ps1; the .sh twin covers it on the bash lanes'
} finally {
    Remove-Item -LiteralPath $IC_ROOT -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Function:Invoke-CursorInstall -ErrorAction SilentlyContinue
}
