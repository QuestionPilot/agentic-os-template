#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# test-tier: slow
# tests/install-hermes.test.ps1 — Windows-native twin of
# tests/install-hermes.test.sh.
#
# install.ps1 now supports the hermes harness on Windows (<TEAM>-296), so the
# build/structure/SOUL/soul-identity/drift/plugin-swap/rollback assertions run
# LIVE here against the .ps1 build output (hermes hooks are .ps1, wired into
# hooks/hooks.yaml via the pwsh -NoProfile -File launcher — see New-HermesHooks).
#
# The hermes HOOK-BEHAVIOR assertions (T5 edit-gate, T6 framework-surface, T7
# autonomy governance) stay _Skip on this lane, per
# [[feedback_port_parity_vs_regression_split]] + the sibling decision in
# tests/hooks-behavior.test.ps1: the .ps1 hooks' run-time behavior is covered in
# tests/hooks-ps-parity.test.ps1 + the dedicated PS hook tests. The bash twin runs
# the .sh hook behavior on the macOS/Linux lanes.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$INSTALL_PS1     = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$CHECK_DRIFT_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'check-drift.ps1'

# Invoke-HermesInstall — full `install.ps1 --harness hermes` into the target named
# by $EnvFile's HERMES_HOME. $ExtraEnv entries are set on THIS process (inherited
# by the child pwsh) for the call, then restored. Returns @{ exit; err }.
function Invoke-HermesInstall {
    param([string]$EnvFile, [hashtable]$ExtraEnv = @{})
    $errFile = [IO.Path]::GetTempFileName()
    $saved = @{}
    foreach ($k in $ExtraEnv.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $ExtraEnv[$k])
    }
    $env:AI_CONFIG_LOCAL_ENV = $EnvFile
    & pwsh -NoProfile -File $INSTALL_PS1 --harness hermes 1>$null 2>$errFile
    $code = $LASTEXITCODE
    foreach ($k in $ExtraEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    $errText = if (Test-Path -LiteralPath $errFile) { Get-Content -Raw -LiteralPath $errFile } else { '' }
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    return @{ exit = $code; err = $errText }
}

$IH_ROOT  = Join-Path ([IO.Path]::GetTempPath()) ("t296-hermes-test-" + [Guid]::NewGuid().Guid.Substring(0,8))
New-Item -ItemType Directory -Path $IH_ROOT -Force | Out-Null
$IH_OUT   = Join-Path $IH_ROOT 'hermes-home'
$IH_VAULT = Join-Path $IH_ROOT 'vault'
$IH_ENV   = Join-Path $IH_ROOT 'local.env'
New-Item -ItemType Directory -Path $IH_OUT, $IH_VAULT -Force | Out-Null
Write-HermesEnvFixture -EnvFile $IH_ENV -HermesHome $IH_OUT -VaultDir $IH_VAULT

try {
    $r = Invoke-HermesInstall -EnvFile $IH_ENV
    Assert-Eq 'install-hermes.test: install.ps1 --harness hermes builds clean' '0' "$($r.exit)"

    # --- T1: build output map (.ps1 hooks on the Windows lane) ---------------
    foreach ($f in @(
        'skills/session-agent/SKILL.md', 'skills/closeout/SKILL.md', 'skills/self-audit/SKILL.md',
        'hooks/framework-surface.ps1', 'hooks/session-agent.ps1', 'hooks/autonomy-drain.ps1',
        'hooks/memory-sanitize.ps1', 'hooks/skill-gate.ps1', 'hooks/steward.ps1', 'hooks/hooks.yaml',
        'plugins/agentic-os-hook-bridge/plugin.yaml', 'plugins/agentic-os-hook-bridge/__init__.py',
        'SOUL.md', '.build-manifest.json')) {
        Assert-File "install-hermes.test: hermes build produced $f" (Join-Path $IH_OUT $f)
    }

    # --- T2: hooks.yaml snippet carries the edit-gate matcher + the bridge ----
    $ih_yaml = if (Test-Path -LiteralPath (Join-Path $IH_OUT 'hooks/hooks.yaml')) { Get-Content -Raw -LiteralPath (Join-Path $IH_OUT 'hooks/hooks.yaml') } else { '' }
    Assert-Contains 'install-hermes.test: hooks.yaml wires the pre_tool_call edit-gate matcher' $ih_yaml 'matcher: "write_file|patch|terminal"'
    Assert-Contains 'install-hermes.test: hooks.yaml wires pre_llm_call to framework-surface' $ih_yaml 'pre_llm_call'
    Assert-Contains 'install-hermes.test: hooks.yaml enables the agentic-os-hook-bridge plugin' $ih_yaml 'agentic-os-hook-bridge'
    # PS-twin: every hooks.yaml entry is a SINGLE `command:` string using the
    # pwsh launcher (a bare .ps1 path is non-executable on Windows). Hermes's
    # ShellHookSpec (agent/shell_hooks.py) has NO `args:` key — an emitted args
    # list is silently ignored, leaving a bare `pwsh` command that never runs
    # the hook. Pin the single-string launcher AND the absence of args:.
    Assert-Contains 'install-hermes.test: hooks.yaml wires a single-string pwsh launcher command' $ih_yaml 'command: "pwsh -NoProfile -File '
    Assert-NotContains 'install-hermes.test: hooks.yaml carries no args: key (ShellHookSpec has none)' $ih_yaml 'args:'

    # --- T3: drift gate passes a fresh build + app-written exemption ----------
    Assert-Exit 'install-hermes.test: check-drift passes the fresh hermes build' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $IH_OUT
    # Hermes writes skills/.bundled_manifest at runtime — must not register as drift.
    Set-Content -LiteralPath (Join-Path $IH_OUT 'skills/.bundled_manifest') -Value '{}' -NoNewline
    Assert-Exit 'install-hermes.test: check-drift exempts the hermes-app-written skills/.bundled_manifest' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $IH_OUT
    Remove-Item -LiteralPath (Join-Path $IH_OUT 'skills/.bundled_manifest') -Force -ErrorAction SilentlyContinue

    # The interpreter writes __pycache__/*.pyc into the managed bridge plugin the
    # first time it imports (e.g. on the first live Hermes session). That runtime
    # bytecode is never a manifest input, so the extra-file scan must EXEMPT it
    # (twin of the bash assertion).
    $ihPycache = Join-Path $IH_OUT 'plugins/agentic-os-hook-bridge/__pycache__'
    New-Item -ItemType Directory -Path $ihPycache -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ihPycache '__init__.cpython-312.pyc') -Value "bytecode`n" -NoNewline
    Assert-Exit 'install-hermes.test: check-drift exempts runtime __pycache__/*.pyc in the bridge plugin' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $IH_OUT
    # Scoped to the __pycache__/ TREE, not the .pyc suffix: a loose *.pyc dropped
    # directly in a managed tree must still register as drift.
    Set-Content -LiteralPath (Join-Path $IH_OUT 'plugins/agentic-os-hook-bridge/loose.pyc') -Value "bytecode`n" -NoNewline
    Assert-Exit 'install-hermes.test: check-drift still fails on a loose *.pyc outside __pycache__ in a managed plugin' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $IH_OUT
    Remove-Item -LiteralPath (Join-Path $IH_OUT 'plugins/agentic-os-hook-bridge/loose.pyc') -Force -ErrorAction SilentlyContinue
    # A non-bytecode untracked file in the SAME managed plugin still registers as drift.
    Set-Content -LiteralPath (Join-Path $IH_OUT 'plugins/agentic-os-hook-bridge/intruder.txt') -Value "rogue`n" -NoNewline
    Assert-Exit 'install-hermes.test: check-drift still fails on a non-bytecode untracked file in the bridge plugin' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $IH_OUT
    Remove-Item -LiteralPath $ihPycache -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $IH_OUT 'plugins/agentic-os-hook-bridge/intruder.txt') -Force -ErrorAction SilentlyContinue

    # --- T4: SOUL.md has the spine directive and no unresolved placeholders ---
    $ih_soul = if (Test-Path -LiteralPath (Join-Path $IH_OUT 'SOUL.md')) { Get-Content -Raw -LiteralPath (Join-Path $IH_OUT 'SOUL.md') } else { '' }
    Assert-Contains 'install-hermes.test: SOUL.md carries the session-agent spine directive' $ih_soul '/session-agent'
    Assert-NotContains 'install-hermes.test: SOUL.md has no unresolved placeholders' $ih_soul '@@'

    # --- T4b: soul-identity overlay neutralizes an adversarial identity payload
    # A 2nd isolated build whose SOUL_IDENTITY_PATH points at a hostile identity:
    # framework tokens in the identity prose (a literal @@CAPABILITY_CATALOG@@ + an
    # overlay marker) must be STRIPPED to empty — not expanded into a second catalog,
    # not left literal — while normal prose + metacharacters render verbatim (PS
    # splices literally; no shell execution). Guards the SOUL-overlay edit.
    # F1 (cross-model panel): the apostrophe in this target name is deliberate —
    # Windows usernames like O'Brien produce HERMES_HOME paths with a single quote,
    # which must NOT break the generated hooks.yaml (the hook paths are double-quoted
    # YAML, so an apostrophe is literal; a single-quoted scalar would break on it).
    $IH_OUT2  = Join-Path $IH_ROOT "hermes-home2'apos"
    $IH_ENV2  = Join-Path $IH_ROOT 'local2.env'
    $IH_IDENT = Join-Path $IH_ROOT 'local.soul-identity.md'
    New-Item -ItemType Directory -Path $IH_OUT2 -Force | Out-Null
    $identLines = @(
        '## Who I am',
        '- Catalog token @@CAPABILITY_CATALOG@@ inline.',
        '- Overlay marker @@OPERATOR_SKILLS_OVERLAY@@ inline.',
        '- Metachars & $HOME `tick` $(echo SUBSHELL) verbatim.'
    )
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($IH_IDENT, (($identLines -join "`n") + "`n"), $utf8NoBom)
    [System.IO.File]::WriteAllText($IH_ENV2, ((@(
        "HERMES_HOME=`"$IH_OUT2`"",
        "OBSIDIAN_VAULT_PATH=`"$IH_VAULT`"",
        "SOUL_IDENTITY_PATH=`"$IH_IDENT`""
    ) -join "`n") + "`n"), $utf8NoBom)

    $r2 = Invoke-HermesInstall -EnvFile $IH_ENV2
    Assert-Eq 'install-hermes.test: install.ps1 --harness hermes builds clean with a soul-identity overlay' '0' "$($r2.exit)"
    $ih_soul2 = if (Test-Path -LiteralPath (Join-Path $IH_OUT2 'SOUL.md')) { Get-Content -Raw -LiteralPath (Join-Path $IH_OUT2 'SOUL.md') } else { '' }
    Assert-NotContains 'install-hermes.test: soul-identity overlay leaves no unresolved/leaked @@ token' $ih_soul2 '@@'
    Assert-Contains 'install-hermes.test: soul-identity overlay splices the identity prose' $ih_soul2 '## Who I am'
    Assert-Contains 'install-hermes.test: an inline @@CAPABILITY_CATALOG@@ is stripped to empty, not expanded' $ih_soul2 'Catalog token  inline.'
    Assert-Contains 'install-hermes.test: an inline overlay marker is stripped to empty' $ih_soul2 'Overlay marker  inline.'
    Assert-Contains 'install-hermes.test: shell metacharacters in the identity render verbatim (not executed)' $ih_soul2 'echo SUBSHELL) verbatim.'
    Assert-Contains 'install-hermes.test: the operating-section spine directive still renders' $ih_soul2 '/session-agent'
    # F1: the apostrophe in the hook path rides inside a POSIX-single-quoted
    # token in the YAML double-quoted `command:` scalar — the embedded
    # apostrophe becomes the '\'' idiom, whose backslash is then YAML-doubled.
    # Compute the expected scalar through the same two layers and pin the whole
    # command line; the shlex round-trip below proves the layering is CORRECT,
    # this pins that it is present.
    $ih_yaml2 = if (Test-Path -LiteralPath (Join-Path $IH_OUT2 'hooks/hooks.yaml')) { Get-Content -Raw -LiteralPath (Join-Path $IH_OUT2 'hooks/hooks.yaml') } else { '' }
    $ih2Hook = ((($IH_OUT2 -replace '\\', '/')) + '/hooks/session-agent.ps1')
    $ih2Tok  = ("'" + $ih2Hook.Replace("'", "'\''") + "'").Replace('\', '\\').Replace('"', '\"')
    Assert-Contains 'install-hermes.test: hooks.yaml single-string command shlex-quotes an apostrophe-containing hook path (valid YAML)' $ih_yaml2 ('command: "pwsh -NoProfile -File ' + $ih2Tok + '"')
    # Shlex round-trip (twin of the bash T2b python3 check): YAML-unescape each
    # command scalar, shlex-split it, and require exactly the launcher argv
    # [pwsh, -NoProfile, -File, <real hook script under the apostrophe path>].
    # Probe python defensively: the MS-Store WindowsApps alias stub and
    # extensionless PATH hits are not runnable interpreters (the same class
    # bootstrap.ps1's Resolve-ExecutableCommand guards against).
    $ih2Py = @(Get-Command python3, python -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandType -eq 'Application' -and $_.Source -and ($_.Source -notmatch 'WindowsApps') -and
        ((-not $IsWindows) -or ([System.IO.Path]::GetExtension($_.Source) -in @('.exe', '.cmd', '.bat', '.com')))
    } | Select-Object -First 1)
    $ih2ShlexLabel = 'install-hermes.test: every hook command in an apostrophe path shlex-splits to the pwsh launcher + its hook script'
    if ($ih2Py.Count -gt 0) {
        $ih2PyLines = @(
            'import os, re, shlex, sys',
            'hdir = os.path.join(os.environ["IH_OUT2"], "hooks").replace("\\", "/")',
            'txt = open(sys.argv[1], encoding="utf-8").read()',
            'cmds = re.findall(r''^\s*command:\s*"(.*)"\s*$'', txt, re.M)',
            'def yaml_dq_unescape(s):',
            '    return s.replace("\\\\", "\x00").replace(''\\"'', ''"'').replace("\x00", "\\")',
            'if not cmds:',
            '    print("NO-COMMANDS"); sys.exit()',
            'bad = []',
            'for c in cmds:',
            '    try:',
            '        toks = shlex.split(yaml_dq_unescape(c))',
            '    except ValueError as e:',
            '        bad.append("shlex-error:%s on %r" % (e, c)); continue',
            '    if (len(toks) != 4 or toks[:3] != ["pwsh", "-NoProfile", "-File"]',
            '            or os.path.dirname(toks[3]) != hdir or not os.path.isfile(toks[3])):',
            '        bad.append("tok=%r" % toks)',
            'print("OK" if not bad else "FAIL " + "; ".join(bad))'
        )
        $ih2PyFile = Join-Path $IH_ROOT 'shlex-check.py'
        [System.IO.File]::WriteAllText($ih2PyFile, (($ih2PyLines -join "`n") + "`n"), $utf8NoBom)
        $ih2SavedOut2 = $env:IH_OUT2
        $env:IH_OUT2 = $IH_OUT2
        $ih2Sp = (& $ih2Py[0].Source $ih2PyFile (Join-Path $IH_OUT2 'hooks/hooks.yaml') 2>$null) -join "`n"
        $env:IH_OUT2 = $ih2SavedOut2
        Assert-Eq $ih2ShlexLabel 'OK' "$ih2Sp"
        Remove-Item -LiteralPath $ih2PyFile -Force -ErrorAction SilentlyContinue
    } else {
        _Skip $ih2ShlexLabel 'no runnable python interpreter on PATH'
    }
    Remove-Item -LiteralPath $IH_OUT2, $IH_ENV2, $IH_IDENT -Recurse -Force -ErrorAction SilentlyContinue

    # --- T5/T6/T7: hermes hook behaviour — _Skip on the Windows lane ----------
    # Per [[feedback_port_parity_vs_regression_split]]: the .ps1 hooks' run-time
    # behavior (edit-gate block/allow, framework-surface injection, autonomy
    # governance) is covered in tests/hooks-ps-parity.test.ps1 + the dedicated PS
    # hook tests; the bash twin exercises the .sh hooks on macOS/Linux.
    $hbreason = 'hermes .ps1 hook behavior covered in hooks-ps-parity.test.ps1 + the PS hook tests; bash twin runs the .sh hooks'
    foreach ($lbl in @(
        'install-hermes.test: gate blocks a write_file before the gate is open',
        'install-hermes.test: gate blocks a terminal call before the gate is open',
        'install-hermes.test: the gate-declaration write is allowed (silent stdout)',
        'install-hermes.test: writes pass once the session gate file is declared',
        'install-hermes.test: CLAUDE_SKIP_SESSION_AGENT=1 bypasses the gate',
        'install-hermes.test: a payload without session_id stays silent',
        'install-hermes.test: framework-surface first turn emits valid JSON context',
        'install-hermes.test: framework-surface first turn carries the session-agent directive',
        'install-hermes.test: framework-surface stays silent on a later turn',
        'install-hermes.test: framework-surface fails silent when is_first_turn AND session_id absent',
        'install-hermes.test: framework-surface treats stringified False as not-first-turn (silent)',
        'install-hermes.test: unattended drain is OFF by default (silent)',
        'install-hermes.test: unattended drain default-off leaves no log',
        'install-hermes.test: enabled drain skips a telegram session (propose-only)',
        'install-hermes.test: telegram session is never drained',
        'install-hermes.test: skill_manage create is blocked pending approval',
        'install-hermes.test: skill_manage read-only verb is gated too (no fast-path)',
        'install-hermes.test: an operator approval marker allows ONE mutation',
        'install-hermes.test: the approval marker is consumed on use',
        'install-hermes.test: memory-sanitize blocks an injection payload shape',
        'install-hermes.test: memory-sanitize passes benign content',
        'install-hermes.test: steward skips when views match regeneration (no-delta)',
        'install-hermes.test: steward enforces the daily run cap')) {
        _Skip $lbl $hbreason
    }
    # steward-not-scheduled is a BUILD assertion (hooks.yaml content), not behavior.
    Assert-NotContains 'install-hermes.test: steward is NOT scheduled in hooks.yaml (operator act)' $ih_yaml 'steward.ps1'

    # --- T8: F7 (operator plugin survives) + N1 (collision warn) + drift -------
    New-Item -ItemType Directory -Path (Join-Path $IH_OUT 'plugins/operator-plugin') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $IH_OUT 'plugins/operator-plugin/plugin.yaml') -Value "name: operator-plugin`nowner: me`n" -NoNewline
    $r8 = Invoke-HermesInstall -EnvFile $IH_ENV
    Assert-Eq 'install-hermes.test: re-install with an operator plugin subdir present builds clean' '0' "$($r8.exit)"
    Assert-File 'install-hermes.test: F7: operator plugin subdir survives hermes re-install' (Join-Path $IH_OUT 'plugins/operator-plugin/plugin.yaml')
    $opcontent = if (Test-Path -LiteralPath (Join-Path $IH_OUT 'plugins/operator-plugin/plugin.yaml')) { Get-Content -Raw -LiteralPath (Join-Path $IH_OUT 'plugins/operator-plugin/plugin.yaml') } else { '' }
    Assert-Contains 'install-hermes.test: F7: operator plugin content preserved verbatim' $opcontent 'owner: me'
    Assert-File 'install-hermes.test: F7: framework bridge plugin still installed after re-install' (Join-Path $IH_OUT 'plugins/agentic-os-hook-bridge/plugin.yaml')
    Assert-Exit 'install-hermes.test: check-drift exempts the operator-added plugin subdir' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $IH_OUT
    # A rogue file inside the FRAMEWORK plugin dir is NOT operator-local -> caught.
    Set-Content -LiteralPath (Join-Path $IH_OUT 'plugins/agentic-os-hook-bridge/rogue.py') -Value "rogue`n" -NoNewline
    $ih_drift_out = & pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $IH_OUT 2>&1
    $ih_drift_rc = $LASTEXITCODE
    Assert-Eq 'install-hermes.test: check-drift flags a rogue file in a framework plugin dir (exit 1)' '1' "$ih_drift_rc"
    Assert-Contains 'install-hermes.test: check-drift names the rogue framework-plugin file' (($ih_drift_out | Out-String)) 'plugins/agentic-os-hook-bridge/rogue.py'
    Remove-Item -LiteralPath (Join-Path $IH_OUT 'plugins/agentic-os-hook-bridge/rogue.py') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $IH_OUT 'plugins/operator-plugin') -Recurse -Force -ErrorAction SilentlyContinue

    # N1: a FRESH hermes install over a pre-existing non-framework plugin whose name
    # collides with the framework bridge must warn (not silently overwrite).
    $IH_N1     = Join-Path $IH_ROOT 'hermes-n1'
    $IH_N1_ENV = Join-Path $IH_ROOT 'n1.env'
    New-Item -ItemType Directory -Path (Join-Path $IH_N1 'plugins/agentic-os-hook-bridge') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $IH_N1 'plugins/agentic-os-hook-bridge/plugin.yaml') -Value "name: native-collision`n" -NoNewline
    Write-HermesEnvFixture -EnvFile $IH_N1_ENV -HermesHome $IH_N1 -VaultDir $IH_VAULT
    $rN1 = Invoke-HermesInstall -EnvFile $IH_N1_ENV
    Assert-Contains 'install-hermes.test: N1: colliding non-framework plugins/ subdir warns on fresh install' $rN1.err 'replacing plugins/agentic-os-hook-bridge which no prior framework install authored'
    Remove-Item -LiteralPath $IH_N1, $IH_N1_ENV -Recurse -Force -ErrorAction SilentlyContinue

    # --- T9: rollback restores BOTH per-subdir trees (skills/ AND plugins/) from
    #          the SHARED .install-bak.d root. Forcing the SOUL.md swap to fail (it
    #          sorts after both skills + plugins in hermes ManagedPaths, so both have
    #          live backups) aborts the install; the rollback must restore the
    #          plugins/ sentinel AND the skills/ tree, then drop the shared root.
    $RB     = Join-Path $IH_ROOT 'hermes-rb'
    $RB_ENV = Join-Path $IH_ROOT 'rb.env'
    New-Item -ItemType Directory -Path $RB -Force | Out-Null
    Write-HermesEnvFixture -EnvFile $RB_ENV -HermesHome $RB -VaultDir $IH_VAULT
    Invoke-HermesInstall -EnvFile $RB_ENV | Out-Null
    Add-Content -LiteralPath (Join-Path $RB 'plugins/agentic-os-hook-bridge/plugin.yaml') -Value "`n# rollback-sentinel"
    $rRb = Invoke-HermesInstall -EnvFile $RB_ENV -ExtraEnv @{ AI_CONFIG_INSTALL_TEST_FAIL_SWAP = 'SOUL.md' }
    Assert-Eq 'install-hermes.test: forced SOUL.md swap failure aborts the hermes install (nonzero)' '1' "$($rRb.exit)"
    $rbPlugin = if (Test-Path -LiteralPath (Join-Path $RB 'plugins/agentic-os-hook-bridge/plugin.yaml')) { Get-Content -Raw -LiteralPath (Join-Path $RB 'plugins/agentic-os-hook-bridge/plugin.yaml') } else { '' }
    Assert-Contains 'install-hermes.test: rollback restores the plugins/ backup from the shared root (timing)' $rbPlugin 'rollback-sentinel'
    Assert-File 'install-hermes.test: rollback restores the skills/ tree from the shared root' (Join-Path $RB 'skills/session-agent/SKILL.md')
    if (Test-Path -LiteralPath (Join-Path $RB '.install-bak.d')) {
        _Fail 'install-hermes.test: run-private backup root removed after a both-paths rollback' '.install-bak.d still present'
    } else {
        _Pass 'install-hermes.test: run-private backup root removed after a both-paths rollback'
    }
    Remove-Item -LiteralPath $RB, $RB_ENV -Recurse -Force -ErrorAction SilentlyContinue
} finally {
    Remove-Item -LiteralPath $IH_ROOT -Recurse -Force -ErrorAction SilentlyContinue
    $env:AI_CONFIG_LOCAL_ENV = $null
}
