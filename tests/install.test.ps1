#Requires -Version 7
# tests/install.test.ps1 — Windows-native prototype install acceptance.
#
# Verifies `pwsh scripts/install.ps1 --harness claude --build-only` for the
# claude harness:
#
# 1. install.ps1 exists and is non-empty.
# 2. --build-only on a clean fixture exits 0 and prints a build dir path.
# 3. The build dir contains the managed-paths surface: CLAUDE.md, SKILLS.md,
# settings.json, skills/, hooks/,.build-manifest.json.
# 4. Generated settings.json is valid JSON.
# 5. Generated settings.json hook `command` field references the
# pwsh-callable `pwsh -File <abs>\hooks\<script>.ps1` shape, NOT the
# legacy `.sh` shape. This is the Windows blocker that Codex
# surfaced — the bash install.sh hardcodes `.sh` in install_hook /
# generate_settings, which is non-executable on Windows.
# 6. No unresolved @@VAR@@ placeholders survive into the build (parity
# with install.sh's validate_build).
#
# Mirrors the install acceptance shape from
# tests/install-render-stable.test.sh (claude lane only).

# tests/lib.ps1 is dot-sourced by tests/run.ps1 BEFORE each test file is
# dot-sourced — so Assert-* helpers and counters are already in scope. Test
# files MUST NOT re-dot-source lib.ps1: that would reset the global counters
# ($script:TESTS_RUN / $script:TESTS_FAILED) mid-suite and hide earlier
# failures. Mirrors tests/run.sh's "source once" model.

$INSTALL_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'

# --- AC 1: install.ps1 exists -----------------------------------------------
Assert-File 'install.test: scripts/install.ps1 exists' $INSTALL_PS1

if (-not (Test-Path -LiteralPath $INSTALL_PS1 -PathType Leaf)) {
    # The remaining tests depend on install.ps1 being on disk; skip them.
    _Skip 'install.test: --build-only exits 0'                 'install.ps1 missing'
    _Skip 'install.test: build contains CLAUDE.md'            'install.ps1 missing'
    _Skip 'install.test: build contains SKILLS.md'            'install.ps1 missing'
    _Skip 'install.test: build contains settings.json'        'install.ps1 missing'
    _Skip 'install.test: build contains skills/'              'install.ps1 missing'
    _Skip 'install.test: build contains hooks/'               'install.ps1 missing'
    _Skip 'install.test: build contains .build-manifest.json' 'install.ps1 missing'
    _Skip 'install.test: settings.json is valid JSON'         'install.ps1 missing'
    _Skip 'install.test: hooks command uses pwsh -File shape' 'install.ps1 missing'
    _Skip 'install.test: hooks command points at .ps1 script' 'install.ps1 missing'
    _Skip 'install.test: no unresolved @@VAR@@ in build'      'install.ps1 missing'
    return
}

# --- Per-run fixture --------------------------------------------------------
# pwsh's New-TemporaryFile gives us a file; we want a dir. Use [IO.Path] for
# a cross-platform Temp dir + a New-Guid suffix so we can run alongside the
# bash suite without collisions.
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("t100-install-test-" + [Guid]::NewGuid().Guid.Substring(0,8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$claudeTgt = Join-Path $tmpRoot 'claude-config'
$envFile   = Join-Path $tmpRoot 'fixture.local.env'
$vaultDir  = Join-Path $tmpRoot 'vault'
New-Item -ItemType Directory -Path $claudeTgt -Force | Out-Null
New-Item -ItemType Directory -Path $vaultDir  -Force | Out-Null

Write-LocalEnvFixture -EnvFile $envFile -ConfigDir $claudeTgt -VaultDir $vaultDir

try {
    # --- AC 2: --build-only exits 0 and prints a build dir path -------------
    $env:AI_CONFIG_LOCAL_ENV = $envFile
    $output = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --build-only 2>&1
    $exit   = $LASTEXITCODE

    if ($exit -ne 0) {
        _Fail 'install.test: --build-only exits 0' "exit=$exit", "stdout/err:", ($output -join "`n")
        _Skip 'install.test: build contains CLAUDE.md'            'build did not run'
        _Skip 'install.test: build contains SKILLS.md'            'build did not run'
        _Skip 'install.test: build contains settings.json'        'build did not run'
        _Skip 'install.test: build contains skills/'              'build did not run'
        _Skip 'install.test: build contains hooks/'               'build did not run'
        _Skip 'install.test: build contains .build-manifest.json' 'build did not run'
        _Skip 'install.test: settings.json is valid JSON'         'build did not run'
        _Skip 'install.test: hooks command uses pwsh -File shape' 'build did not run'
        _Skip 'install.test: hooks command points at .ps1 script' 'build did not run'
        _Skip 'install.test: no unresolved @@VAR@@ in build'      'build did not run'
        return
    }
    _Pass 'install.test: --build-only exits 0'

    # The last non-empty line of stdout is the build dir path. Lines may be
    # interleaved on Windows so filter to non-empty trimmed lines.
    $lines = @($output | Where-Object { ($_ -ne $null) -and (($_.ToString().Trim()) -ne '') })
    $buildDir = $lines[-1].ToString().Trim()

    # --- AC 3: managed-paths surface present in build -----------------------
    Assert-File 'install.test: build contains CLAUDE.md'            (Join-Path $buildDir 'CLAUDE.md')
    Assert-File 'install.test: build contains SKILLS.md'            (Join-Path $buildDir 'SKILLS.md')
    Assert-File 'install.test: build contains settings.json'        (Join-Path $buildDir 'settings.json')
    if (Test-Path (Join-Path $buildDir 'skills')) {
        _Pass 'install.test: build contains skills/'
    } else {
        _Fail 'install.test: build contains skills/' "skills/ not found in $buildDir"
    }
    if (Test-Path (Join-Path $buildDir 'hooks')) {
        _Pass 'install.test: build contains hooks/'
    } else {
        _Fail 'install.test: build contains hooks/' "hooks/ not found in $buildDir"
    }
    Assert-File 'install.test: build contains .build-manifest.json' (Join-Path $buildDir '.build-manifest.json')

    # --- AC 4: settings.json valid JSON -------------------------------------
    $settingsPath = Join-Path $buildDir 'settings.json'
    try {
        $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json -ErrorAction Stop
        _Pass 'install.test: settings.json is valid JSON'
    } catch {
        _Fail 'install.test: settings.json is valid JSON' $_.Exception.Message
        $settings = $null
    }

    # --- AC 5: hooks command uses pwsh -File <abs>.ps1 shape ----------------
    # The Windows blocker — install.sh:244/270-273/337/540 hardcodes
    # `.sh` so the generated settings.json carries `command: ".../hooks/<x>.sh"`,
    # which Windows can't execute. install.ps1 must emit
    # `command: "pwsh" args: ["-NoProfile","-File","<abs>\hooks\<x>.ps1"]`
    # or the equivalent `command: "pwsh -NoProfile -File <abs>\hooks\<x>.ps1"`
    # single-string shape. We accept either.
    if ($settings -ne $null) {
        $hookEvents = $settings.hooks.PSObject.Properties.Name
        $allShapesOk = $true
        $shapeProblems = @()
        foreach ($evt in $hookEvents) {
            $matcherEntries = $settings.hooks.$evt
            foreach ($me in $matcherEntries) {
                foreach ($h in $me.hooks) {
                    # Acceptable shapes:
                    # (a) h.command = 'pwsh' AND h.args includes -File and a.ps1 path
                    # (b) h.command = 'pwsh -NoProfile -File <abs>.ps1' single-string
                    $cmdRaw = $h.command
                    $argsArr = @()
                    if ($h.PSObject.Properties.Name -contains 'args' -and $h.args) {
                        $argsArr = @($h.args)
                    }
                    $isPwsh   = ($cmdRaw -eq 'pwsh') -or ($cmdRaw -like 'pwsh*-File*.ps1')
                    $isPs1    = $false
                    foreach ($a in $argsArr) {
                        if ($a -like '*.ps1') { $isPs1 = $true; break }
                    }
                    if (-not $isPs1 -and ($cmdRaw -like '*.ps1')) { $isPs1 = $true }
                    $isNotSh  = ($cmdRaw -notlike '*.sh') -and ($argsArr -notcontains '*.sh')
                    foreach ($a in $argsArr) {
                        if ($a -like '*.sh') { $isNotSh = $false }
                    }
                    if (-not ($isPwsh -and $isPs1 -and $isNotSh)) {
                        $allShapesOk = $false
                        $shapeProblems += "event=$evt command=$cmdRaw args=[$($argsArr -join ',')]"
                    }
                }
            }
        }
        if ($allShapesOk) {
            _Pass 'install.test: hooks command uses pwsh -File shape'
            _Pass 'install.test: hooks command points at .ps1 script'
        } else {
            _Fail 'install.test: hooks command uses pwsh -File shape' $shapeProblems
            _Fail 'install.test: hooks command points at .ps1 script' $shapeProblems
        }
    } else {
        _Skip 'install.test: hooks command uses pwsh -File shape' 'settings.json not parseable'
        _Skip 'install.test: hooks command points at .ps1 script' 'settings.json not parseable'
    }

    # --- AC 6: no unresolved @@VAR@@ placeholders in build ------------------
    # Scan every file in the build dir for the @@PLACEHOLDER@@ token shape.
    # CAPABILITY_CATALOG is the only token install.ps1 generates internally;
    # if it survives, that's a bug.
    $unresolved = @(Get-ChildItem -LiteralPath $buildDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 0 } |
        ForEach-Object {
            $hits = Select-String -LiteralPath $_.FullName -Pattern '@@[A-Z_]+@@' -SimpleMatch:$false -ErrorAction SilentlyContinue
            if ($hits) {
                foreach ($h in $hits) {
                    [pscustomobject]@{ File = $_.FullName; Line = $h.Line }
                }
            }
        }
    )
    if ($unresolved.Count -eq 0) {
        _Pass 'install.test: no unresolved @@VAR@@ in build'
    } else {
        _Fail 'install.test: no unresolved @@VAR@@ in build' ($unresolved | ForEach-Object { "$($_.File): $($_.Line)" })
    }

    # --- AC 7: all expected hooks wired (Codex confirmation MT-3) -------------
    # The build MUST wire BOTH claude hook.ps1 files:
    # - session-agent.ps1 (PreToolUse: Write|Edit|NotebookEdit)
    # - framework-surface.ps1 (SessionStart: startup|clear|compact)
    # (closeout.ps1 / Stop was removed — closeout is now manual-fire.)
    # A regression that drops any one would break a specific surface
    # silently. Test pins each by script-name presence in $settings.hooks
    # somewhere AND on disk under $buildDir/hooks/.
    $expectedHooks = @(
        @{ name = 'session-agent.ps1';     event = 'PreToolUse';   matcher = 'Write|Edit|NotebookEdit' },
        @{ name = 'framework-surface.ps1'; event = 'SessionStart'; matcher = 'startup|clear|compact' }
    )
    foreach ($eh in $expectedHooks) {
        $hookFile = Join-Path $buildDir 'hooks' $eh.name
        if (Test-Path -LiteralPath $hookFile -PathType Leaf) {
            _Pass "install.test: hooks/$($eh.name) present in build"
        } else {
            _Fail "install.test: hooks/$($eh.name) present in build" "expected $hookFile"
        }
        # Also assert the settings.json wiring under the matching event.
        $found = $false
        $foundMatcher = ''
        if ($settings -ne $null -and $settings.hooks.PSObject.Properties.Name -contains $eh.event) {
            foreach ($me in $settings.hooks.($eh.event)) {
                foreach ($h in $me.hooks) {
                    $argsArr = @()
                    if ($h.PSObject.Properties.Name -contains 'args' -and $h.args) { $argsArr = @($h.args) }
                    foreach ($a in $argsArr) {
                        if ($a -like "*$($eh.name)") { $found = $true; $foundMatcher = $me.matcher; break }
                    }
                    if ($found) { break }
                }
                if ($found) { break }
            }
        }
        if ($found) {
            _Pass "install.test: settings.json wires $($eh.name) under event $($eh.event)"
            if ($foundMatcher -eq $eh.matcher) {
                _Pass "install.test: settings.json matcher for $($eh.name) is `"$($eh.matcher)`""
            } else {
                _Fail "install.test: settings.json matcher for $($eh.name) is `"$($eh.matcher)`"" "got: `"$foundMatcher`""
            }
        } else {
            _Fail "install.test: settings.json wires $($eh.name) under event $($eh.event)" "hook not found"
            _Skip "install.test: settings.json matcher for $($eh.name) is `"$($eh.matcher)`"" 'hook not wired'
        }
    }

    # --- AC 8: hook args shape is EXACTLY [-NoProfile, -File, <abs>] ----------
    # Codex confirmation MT-2 tightening: AC 5 is loose (accepts pwsh + any
    # mix of args including a.ps1). Pin the exact 3-element args order so
    # install.sh-style 'command: ".../<x>.sh"' regressions cannot pass.
    if ($settings -ne $null) {
        $argsShapeOk = $true
        $argsProblems = @()
        foreach ($evt in $settings.hooks.PSObject.Properties.Name) {
            foreach ($me in $settings.hooks.$evt) {
                foreach ($h in $me.hooks) {
                    $argsArr = @()
                    if ($h.PSObject.Properties.Name -contains 'args' -and $h.args) { $argsArr = @($h.args) }
                    # Exact: ['-NoProfile', '-File', '<abs ending.ps1>'].
                    if ($argsArr.Count -ne 3) {
                        $argsShapeOk = $false
                        $argsProblems += "event=$evt args.Count=$($argsArr.Count) (want 3)"
                        continue
                    }
                    if ($argsArr[0] -ne '-NoProfile') {
                        $argsShapeOk = $false
                        $argsProblems += "event=$evt args[0]=$($argsArr[0]) (want -NoProfile)"
                    }
                    if ($argsArr[1] -ne '-File') {
                        $argsShapeOk = $false
                        $argsProblems += "event=$evt args[1]=$($argsArr[1]) (want -File)"
                    }
                    if (-not ($argsArr[2] -like '*.ps1')) {
                        $argsShapeOk = $false
                        $argsProblems += "event=$evt args[2]=$($argsArr[2]) (want path ending .ps1)"
                    }
                    if ($h.command -ne 'pwsh') {
                        $argsShapeOk = $false
                        $argsProblems += "event=$evt command=$($h.command) (want bare 'pwsh')"
                    }
                }
            }
        }
        if ($argsShapeOk) {
            _Pass 'install.test: hook args shape is exactly [-NoProfile, -File, <abs>.ps1]'
        } else {
            _Fail 'install.test: hook args shape is exactly [-NoProfile, -File, <abs>.ps1]' $argsProblems
        }
    } else {
        _Skip 'install.test: hook args shape is exactly [-NoProfile, -File, <abs>.ps1]' 'settings.json not parseable'
    }
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    $env:AI_CONFIG_LOCAL_ENV = $null
}

# --- an unknown harness name is gracefully rejected on Windows ----------------
# <TEAM>-296: claude, codex, and hermes all build on Windows now, so the graceful
# rejection applies to a genuinely UNKNOWN harness name (a typo). install.ps1
# rejects it: exit 1, an actionable message naming the known set, and NO partial
# filesystem mutation (the reject fires at the per-harness env-var switch default,
# before any target resolution or build-dir creation).
$hmRoot = Join-Path ([IO.Path]::GetTempPath()) ("t296-unknown-harness-reject-" + [Guid]::NewGuid().Guid.Substring(0,8))
New-Item -ItemType Directory -Path $hmRoot -Force | Out-Null
$hmTgt   = Join-Path $hmRoot 'claude-config'
$hmEnv   = Join-Path $hmRoot 'fixture.local.env'
$hmVault = Join-Path $hmRoot 'vault'
New-Item -ItemType Directory -Path $hmTgt, $hmVault -Force | Out-Null
$hmLines = @(
    "CLAUDE_CONFIG_DIR=`"$hmTgt`"",
    "OBSIDIAN_VAULT_PATH=`"$hmVault`""
)
$hmUtf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($hmEnv, (($hmLines -join "`n") + "`n"), $hmUtf8)

try {
    $env:AI_CONFIG_LOCAL_ENV = $hmEnv
    $hmOut = & pwsh -NoProfile -File $INSTALL_PS1 --harness bogusharness 2>&1
    $hmExit = $LASTEXITCODE
    $hmOutStr = if ($hmOut -is [array]) { $hmOut -join "`n" } else { [string]$hmOut }

    # Exit 1 (graceful failure), not 0 (silent) and not an uncaught throw.
    Assert-Eq 'install.test: unknown harness exits 1 (graceful reject, no crash)' '1' "$hmExit"

    # Message is actionable — names the known harness set.
    Assert-Contains 'install.test: unknown-harness reject message names the known set' `
        $hmOutStr 'claude, codex, hermes'
    Assert-Contains 'install.test: unknown-harness reject message says unknown harness' `
        $hmOutStr 'unknown harness'

    # NO partial mutation — no build landed in the claude target (the reject fires
    # at the env switch default, before any target resolution / build-dir creation).
    if (Test-Path -LiteralPath (Join-Path $hmTgt 'CLAUDE.md')) {
        _Fail 'install.test: unknown-harness reject leaves no partial build' 'CLAUDE.md was built'
    } else {
        _Pass 'install.test: unknown-harness reject leaves no partial build'
    }
} finally {
    Remove-Item -LiteralPath $hmRoot -Recurse -Force -ErrorAction SilentlyContinue
    $env:AI_CONFIG_LOCAL_ENV = $null
}
