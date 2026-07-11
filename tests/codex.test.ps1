#Requires -Version 7
# tests/codex.test.ps1 — Windows-native twin of tests/codex.test.sh.
#
# Codex-target build acceptance tests. install.ps1 now supports the codex harness
# on Windows (<TEAM>-296), so the build/structure/manifest/AGENTS/determinism/
# drift assertions run LIVE here, mirroring the bash twin against the .ps1 build
# output (codex hooks are .ps1, wired into hooks.json via the pwsh -NoProfile
# -File launcher shape — see scripts/install.ps1 New-CodexHooks).
#
# The codex HOOK-BEHAVIOR assertions stay _Skip on this lane, per
# [[feedback_port_parity_vs_regression_split]] + the sibling decision in
# tests/hooks-behavior.test.ps1: the .ps1 hooks' run-time behavior (marker
# recognition, fail-closed/open) is covered in tests/hooks-ps-parity.test.ps1.
# _Skip preserves the AC count + carries the rationale; the bash twin runs the
# .sh hook behavior on the macOS/Linux lanes.
#
# tests/lib.ps1 is dot-sourced by tests/run.ps1 BEFORE each test file — Assert-*
# helpers + counters are already in scope. Do NOT re-dot-source lib.ps1.

$INSTALL_PS1     = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$CHECK_DRIFT_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'check-drift.ps1'

# Normalize path separators for cross-platform substring checks (the baked hook
# command path uses '\' on Windows, '/' under a local macOS/Linux pwsh verify).
function ConvertTo-Slash { param([string]$P) if ($null -eq $P) { '' } else { $P -replace '\\', '/' } }

# Invoke-CxBuildOnly <env-file> <out> -> build dir path (stdout last line), or $null.
function Invoke-CxBuildOnly {
    param([string]$EnvFile, [string]$Out)
    $env:AI_CONFIG_LOCAL_ENV = $EnvFile
    $raw = & pwsh -NoProfile -File $INSTALL_PS1 --harness codex --out $Out --build-only 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $lines = @($raw | Where-Object { ($_ -ne $null) -and (($_.ToString().Trim()) -ne '') })
    if ($lines.Count -eq 0) { return $null }
    return $lines[-1].ToString().Trim()
}

# Get-TreeDigest <root> -> sorted "relpath:sha256" newline-joined (determinism compare).
function Get-TreeDigest {
    param([string]$Root)
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('/', '\').Replace('\', '/')
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        [void]$sb.AppendLine("${rel}:$h")
    }
    return $sb.ToString()
}

# === Shared fixture for the codex target ====================================
$CX_ROOT  = Join-Path ([IO.Path]::GetTempPath()) ("t296-codex-test-" + [Guid]::NewGuid().Guid.Substring(0,8))
New-Item -ItemType Directory -Path $CX_ROOT -Force | Out-Null
$CX_OUT   = Join-Path $CX_ROOT 'out'
$CX_VAULT = Join-Path $CX_ROOT 'vault'
$CX_ENV   = Join-Path $CX_ROOT 'local.env'
New-Item -ItemType Directory -Path $CX_OUT   -Force | Out-Null
New-Item -ItemType Directory -Path $CX_VAULT -Force | Out-Null
Write-CodexEnvFixture -EnvFile $CX_ENV -CodexHome $CX_OUT -VaultDir $CX_VAULT

try {
    # === Build-only: every managed path is produced =========================
    $cx_build = Invoke-CxBuildOnly -EnvFile $CX_ENV -Out $CX_OUT

    Assert-File 'codex.test: codex build emits session-agent SKILL.md' (Join-Path $cx_build 'skills/session-agent/SKILL.md')
    Assert-File 'codex.test: codex build emits AGENTS.md'              (Join-Path $cx_build 'AGENTS.md')
    if ($cx_build -and (Test-Path -LiteralPath (Join-Path $cx_build 'skills/session-agent/SKILL.md') -PathType Leaf)) {
        $cx_sa = Get-Content -Raw -LiteralPath (Join-Path $cx_build 'skills/session-agent/SKILL.md')
        Assert-Contains 'codex.test: codex session-agent SKILL.md has neutral protocol' $cx_sa 'Session Agent — Session Kickoff Orient + Routing'
        Assert-Contains 'codex.test: codex session-agent SKILL.md has Codex realization' $cx_sa 'Codex realization'
    } else {
        _Skip 'codex.test: codex session-agent SKILL.md has neutral protocol' 'session-agent SKILL.md not built'
        _Skip 'codex.test: codex session-agent SKILL.md has Codex realization' 'session-agent SKILL.md not built'
    }

    # Each native capability compiles to a SKILL.md.
    foreach ($capn in @('session-agent', 'closeout')) {
        Assert-File "codex.test: codex build emits $capn SKILL.md" (Join-Path $cx_build "skills/$capn/SKILL.md")
    }

    # the deleted route + skill-orchestrator capabilities must NOT generate output.
    foreach ($deleted in @('route', 'skill-orchestrator')) {
        if ($cx_build -and (Test-Path -LiteralPath (Join-Path $cx_build "skills/$deleted/SKILL.md"))) {
            _Fail "codex.test: codex build does NOT generate deleted $deleted SKILL.md" "skills/$deleted/SKILL.md still produced"
        } else {
            _Pass "codex.test: codex build does NOT generate deleted $deleted SKILL.md"
        }
    }

    # Each Codex hook script is compiled into hooks/ (.ps1 on the Windows lane).
    # (closeout.ps1 removed — closeout is now manual-fire, no Stop hook.)
    foreach ($h in @('session-agent.ps1', 'framework-surface.ps1')) {
        Assert-File "codex.test: codex build emits hook $h" (Join-Path $cx_build "hooks/$h")
    }

    # the deleted route.ps1 hook must NOT be in the build.
    if ($cx_build -and (Test-Path -LiteralPath (Join-Path $cx_build 'hooks/route.ps1'))) {
        _Fail 'codex.test: codex build does NOT generate deleted hooks/route.ps1' 'hooks/route.ps1 still produced'
    } else {
        _Pass 'codex.test: codex build does NOT generate deleted hooks/route.ps1'
    }

    # hooks.json is generated and well-formed.
    $cx_hj_path = Join-Path $cx_build 'hooks.json'
    Assert-File 'codex.test: codex build emits hooks.json' $cx_hj_path
    if (Test-Path -LiteralPath $cx_hj_path -PathType Leaf) {
        $cx_hj = $null
        try {
            $cx_hj = Get-Content -Raw -LiteralPath $cx_hj_path | ConvertFrom-Json -ErrorAction Stop
            _Pass 'codex.test: codex hooks.json is valid JSON'
        } catch {
            _Fail 'codex.test: codex hooks.json is valid JSON' $_.Exception.Message
        }
        # PreToolUse / SessionStart are the wired events (Stop removed — closeout
        # is manual-fire; UserPromptSubmit removed with cross-model-review).
        foreach ($ev in @('PreToolUse', 'SessionStart')) {
            $has = ($cx_hj -ne $null) -and ($null -ne $cx_hj.hooks.$ev)
            Assert-Eq "codex.test: codex hooks.json wires $ev" 'True' "$has"
        }
        # negative guard: the closeout Stop hook must NOT be wired.
        $hasStop = ($cx_hj -ne $null) -and ($null -ne $cx_hj.hooks.Stop)
        Assert-Eq 'codex.test: codex hooks.json does NOT wire a Stop hook' 'False' "$hasStop"
        $cx_matcher = if ($cx_hj) { $cx_hj.hooks.PreToolUse[0].matcher } else { '' }
        Assert-Eq 'codex.test: codex PreToolUse matcher is apply_patch' 'apply_patch' "$cx_matcher"
        # PS twin: command is 'pwsh', the hook path is the LAST element of args.
        $cx_cmdpath = if ($cx_hj) { @($cx_hj.hooks.PreToolUse[0].hooks[0].args)[-1] } else { '' }
        Assert-Contains 'codex.test: codex PreToolUse command points at target hooks dir' (ConvertTo-Slash $cx_cmdpath) ((ConvertTo-Slash $CX_OUT) + '/hooks/session-agent.ps1')
        # SessionStart is wired unconditionally for EVERY harness (codex included)
        # at install.ps1's non-capability Add-Hook — NOT via Resolve-HookForClass,
        # which only carries enforcement classes. Assert the TARGET + matcher (not
        # just the event key) so this proves framework-surface.ps1 is actually wired
        # into the codex hooks.json, and self-documents the routing.
        $cx_ss_matcher = if ($cx_hj) { $cx_hj.hooks.SessionStart[0].matcher } else { '' }
        Assert-Eq 'codex.test: codex SessionStart matcher is startup|clear|compact' 'startup|clear|compact' "$cx_ss_matcher"
        $cx_ss_path = if ($cx_hj) { @($cx_hj.hooks.SessionStart[0].hooks[0].args)[-1] } else { '' }
        Assert-Contains 'codex.test: codex SessionStart command points at framework-surface.ps1' (ConvertTo-Slash $cx_ss_path) ((ConvertTo-Slash $CX_OUT) + '/hooks/framework-surface.ps1')
        # Every codex hook entry uses the pwsh launcher shape EXACTLY: command
        # 'pwsh' + args ['-NoProfile','-File','<abs>.ps1']. A bare .ps1 command path
        # (the install.sh shape) is non-executable on Windows — pin the exact shape
        # so an install.sh-style regression cannot pass (parity with the claude
        # exact-args-shape assertion in install.test.ps1).
        $cx_shape_bad = 0
        if ($cx_hj) {
            foreach ($ev in $cx_hj.hooks.PSObject.Properties.Name) {
                foreach ($me in $cx_hj.hooks.$ev) {
                    foreach ($hk in $me.hooks) {
                        $a = @($hk.args)
                        if ($hk.command -ne 'pwsh' -or $a.Count -ne 3 -or $a[0] -ne '-NoProfile' -or $a[1] -ne '-File' -or ($a[2] -notlike '*.ps1')) { $cx_shape_bad++ }
                    }
                }
            }
        }
        Assert-Eq 'codex.test: codex hook entries use the exact pwsh -NoProfile -File <abs>.ps1 launcher shape' '0' "$cx_shape_bad"
    } else {
        foreach ($lbl in @(
            'codex.test: codex hooks.json is valid JSON',
            'codex.test: codex hooks.json wires PreToolUse',
            'codex.test: codex hooks.json wires SessionStart',
            'codex.test: codex hooks.json does NOT wire a Stop hook',
            'codex.test: codex PreToolUse matcher is apply_patch',
            'codex.test: codex PreToolUse command points at target hooks dir',
            'codex.test: codex SessionStart matcher is startup|clear|compact',
            'codex.test: codex SessionStart command points at framework-surface.ps1',
            'codex.test: codex hook entries use the exact pwsh -NoProfile -File <abs>.ps1 launcher shape')) {
            _Skip $lbl 'hooks.json not built'
        }
    }

    # Build manifest tracks the codex generated files and sources.
    $cx_mf_path = Join-Path $cx_build '.build-manifest.json'
    Assert-File 'codex.test: codex build emits .build-manifest.json' $cx_mf_path
    if (Test-Path -LiteralPath $cx_mf_path -PathType Leaf) {
        $cx_mf = $null
        try {
            $cx_mf = Get-Content -Raw -LiteralPath $cx_mf_path | ConvertFrom-Json -ErrorAction Stop
            _Pass 'codex.test: codex manifest is valid JSON'
        } catch {
            _Fail 'codex.test: codex manifest is valid JSON' $_.Exception.Message
        }
        Assert-Eq 'codex.test: codex manifest records the harness' 'codex' "$(if ($cx_mf) { $cx_mf.harness })"
        Assert-Eq 'codex.test: codex manifest tracks AGENTS.md generated' 'True' "$(($cx_mf -ne $null) -and ($null -ne $cx_mf.generated.'AGENTS.md'))"
        Assert-Eq 'codex.test: codex manifest tracks hooks.json generated' 'True' "$(($cx_mf -ne $null) -and ($null -ne $cx_mf.generated.'hooks.json'))"
        Assert-Eq 'codex.test: codex manifest tracks the codex adapter as a source' 'True' "$(($cx_mf -ne $null) -and ($null -ne $cx_mf.sources.'harnesses/codex/adapter.md'))"
        Assert-Eq 'codex.test: codex manifest tracks AGENTS.template.md as a source' 'True' "$(($cx_mf -ne $null) -and ($null -ne $cx_mf.sources.'harnesses/codex/AGENTS.template.md'))"
    } else {
        foreach ($lbl in @(
            'codex.test: codex manifest is valid JSON',
            'codex.test: codex manifest records the harness',
            'codex.test: codex manifest tracks AGENTS.md generated',
            'codex.test: codex manifest tracks hooks.json generated',
            'codex.test: codex manifest tracks the codex adapter as a source',
            'codex.test: codex manifest tracks AGENTS.template.md as a source')) {
            _Skip $lbl 'manifest not built'
        }
    }

    # Adapter prose hygiene. The 4 removed vendored skills must not appear in any
    # harnesses/<h>/adapter.md scope note. Loops over EVERY harness adapter (mirrors
    # the bash glob harnesses/*/adapter.md — claude, codex, hermes).
    $adapters = @(Get-ChildItem -LiteralPath (Join-Path $env:REPO_ROOT 'harnesses') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'adapter.md' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Sort-Object)
    foreach ($adapter in $adapters) {
        $hname = Split-Path (Split-Path $adapter -Parent) -Leaf
        $stale = @(Select-String -LiteralPath $adapter -Pattern 'firecrawl|impeccable|printing-press|silver-platter' -ErrorAction SilentlyContinue)
        $staleStr = ($stale | ForEach-Object { "$($_.LineNumber):$($_.Line)" }) -join "`n"
        Assert-Eq "codex.test: harnesses/$hname/adapter.md has no stale vendored-skill refs" '' "$staleStr"
    }

    # AGENTS.md carries the framework layers + routing protocol + capability catalog.
    $cx_agents_path = Join-Path $cx_build 'AGENTS.md'
    if (Test-Path -LiteralPath $cx_agents_path -PathType Leaf) {
        $cx_agents = Get-Content -Raw -LiteralPath $cx_agents_path
        Assert-Contains 'codex.test: codex AGENTS.md references README.md'   $cx_agents 'README.md'
        Assert-Contains 'codex.test: codex AGENTS.md references core/'       $cx_agents 'core/'
        Assert-Contains 'codex.test: codex AGENTS.md carries the session-agent spine rule' $cx_agents 'session-agent` is the spine'
        Assert-NotContains 'codex.test: codex AGENTS.md has no unresolved placeholders' $cx_agents '@@'
        Assert-Contains 'codex.test: codex AGENTS.md substitutes the vault path' $cx_agents $CX_VAULT
        Assert-Contains 'codex.test: codex AGENTS.md substitutes the agentic-os-template path' $cx_agents $env:REPO_ROOT
        foreach ($capn in @('session-agent', 'closeout')) {
            Assert-Contains "codex.test: codex AGENTS.md catalog has a row for $capn" $cx_agents "| ``$capn`` |"
        }
        foreach ($deleted in @('route', 'skill-orchestrator')) {
            Assert-NotContains "codex.test: codex AGENTS.md catalog omits deleted $deleted" $cx_agents "| ``$deleted`` |"
        }
        foreach ($deleted in @('firecrawl', 'impeccable', 'printing-press', 'silver-platter')) {
            Assert-NotContains "codex.test: codex AGENTS.md catalog omits removed $deleted" $cx_agents "| ``$deleted`` |"
        }
    } else {
        foreach ($lbl in @(
            'codex.test: codex AGENTS.md references README.md',
            'codex.test: codex AGENTS.md references core/',
            'codex.test: codex AGENTS.md carries the session-agent spine rule',
            'codex.test: codex AGENTS.md has no unresolved placeholders',
            'codex.test: codex AGENTS.md substitutes the vault path',
            'codex.test: codex AGENTS.md substitutes the agentic-os-template path',
            'codex.test: codex AGENTS.md catalog has a row for session-agent',
            'codex.test: codex AGENTS.md catalog has a row for closeout',
            'codex.test: codex AGENTS.md catalog omits deleted route',
            'codex.test: codex AGENTS.md catalog omits deleted skill-orchestrator',
            'codex.test: codex AGENTS.md catalog omits removed firecrawl',
            'codex.test: codex AGENTS.md catalog omits removed impeccable',
            'codex.test: codex AGENTS.md catalog omits removed printing-press',
            'codex.test: codex AGENTS.md catalog omits removed silver-platter')) {
            _Skip $lbl 'AGENTS.md not built'
        }
    }
    if ($cx_build) { Remove-Item -LiteralPath $cx_build -Recurse -Force -ErrorAction SilentlyContinue }

    # === Determinism: two codex builds are byte-identical ===================
    $cx_det_a = Invoke-CxBuildOnly -EnvFile $CX_ENV -Out $CX_OUT
    $cx_det_b = Invoke-CxBuildOnly -EnvFile $CX_ENV -Out $CX_OUT
    if ($cx_det_a -and $cx_det_b) {
        $same = (Get-TreeDigest -Root $cx_det_a) -eq (Get-TreeDigest -Root $cx_det_b)
        Assert-Eq 'codex.test: codex: two builds are byte-identical (diff -r)' 'True' "$same"
    } else {
        _Fail 'codex.test: codex: two builds are byte-identical (diff -r)' 'one or both determinism builds failed'
    }
    foreach ($d in @($cx_det_a, $cx_det_b)) { if ($d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }

    # === a relative --out yields absolute hooks.json command paths ==========
    # install.ps1 must canonicalize TARGET to an absolute path — a relative --out
    # otherwise leaks relative command paths into hooks.json, resolved against an
    # unpredictable CWD.
    $CXR_WORK = Join-Path ([IO.Path]::GetTempPath()) ("t296-codex-relout-" + [Guid]::NewGuid().Guid.Substring(0,8))
    New-Item -ItemType Directory -Path $CXR_WORK -Force | Out-Null
    $CXR_ENV = Join-Path $CXR_WORK 'local.env'
    Write-CodexEnvFixture -EnvFile $CXR_ENV -CodexHome (Join-Path $CXR_WORK 'unused') -VaultDir $CX_VAULT
    Push-Location $CXR_WORK
    try {
        $env:AI_CONFIG_LOCAL_ENV = $CXR_ENV
        & pwsh -NoProfile -File $INSTALL_PS1 --harness codex --out ./reltgt 1>$null 2>$null
    } finally {
        Pop-Location
    }
    $cxr_hooks = Join-Path $CXR_WORK 'reltgt/hooks.json'
    Assert-File 'codex.test: codex: relative --out still produces hooks.json' $cxr_hooks
    if (Test-Path -LiteralPath $cxr_hooks -PathType Leaf) {
        $cxr_hj = Get-Content -Raw -LiteralPath $cxr_hooks | ConvertFrom-Json
        $cxr_relcount = 0
        foreach ($ev in $cxr_hj.hooks.PSObject.Properties.Name) {
            foreach ($me in $cxr_hj.hooks.$ev) {
                foreach ($hk in $me.hooks) {
                    $p = @($hk.args)[-1]
                    if (-not [System.IO.Path]::IsPathRooted($p)) { $cxr_relcount++ }
                }
            }
        }
        Assert-Eq 'codex.test: codex: every hooks.json command path is absolute' '0' "$cxr_relcount"
    } else {
        _Skip 'codex.test: codex: every hooks.json command path is absolute' 'relative --out build produced no hooks.json'
    }
    Remove-Item -LiteralPath $CXR_WORK -Recurse -Force -ErrorAction SilentlyContinue

    # === Full install: swap into the target + drift gate ====================
    $CXB_ROOT = Join-Path ([IO.Path]::GetTempPath()) ("t296-codex-full-" + [Guid]::NewGuid().Guid.Substring(0,8))
    New-Item -ItemType Directory -Path $CXB_ROOT -Force | Out-Null
    $CXB_OUT = Join-Path $CXB_ROOT 'target'
    $CXB_ENV = Join-Path $CXB_ROOT 'local.env'
    New-Item -ItemType Directory -Path $CXB_OUT -Force | Out-Null
    Write-CodexEnvFixture -EnvFile $CXB_ENV -CodexHome $CXB_OUT -VaultDir $CX_VAULT
    $cxb_err = Join-Path $CXB_ROOT 'install.err'
    $env:AI_CONFIG_LOCAL_ENV = $CXB_ENV
    # Hermetic: an inherited AGENTS_DIR would flip the co-render on for this
    # fixture build (mirrors the bash twin's `env -u AGENTS_DIR`).
    $cxb_saved_agents = [Environment]::GetEnvironmentVariable('AGENTS_DIR')
    Remove-Item Env:AGENTS_DIR -ErrorAction SilentlyContinue
    & pwsh -NoProfile -File $INSTALL_PS1 --harness codex 1>$null 2>$cxb_err
    $cxb_status = $LASTEXITCODE
    if ($null -ne $cxb_saved_agents) { $env:AGENTS_DIR = $cxb_saved_agents }
    Assert-Eq 'codex.test: codex full install exits 0' '0' "$cxb_status"
    # The codex build is inert until the user trusts its hooks.json — install.ps1
    # must surface that manual step (adapter.md Fact 2 documents it as surfaced).
    $cxb_errtext = if (Test-Path -LiteralPath $cxb_err) { Get-Content -Raw -LiteralPath $cxb_err } else { '' }
    Assert-Contains 'codex.test: codex install surfaces the /hooks trust step' $cxb_errtext '/hooks'
    Assert-File 'codex.test: codex full install swaps session-agent SKILL.md' (Join-Path $CXB_OUT 'skills/session-agent/SKILL.md')
    Assert-File 'codex.test: codex full install swaps hooks.json'             (Join-Path $CXB_OUT 'hooks.json')
    Assert-File 'codex.test: codex full install swaps AGENTS.md'              (Join-Path $CXB_OUT 'AGENTS.md')
    Assert-File 'codex.test: codex full install swaps the session-agent hook' (Join-Path $CXB_OUT 'hooks/session-agent.ps1')
    # No backup/temp dirs left behind.
    $cx_leftover = @(Get-ChildItem -LiteralPath $CXB_OUT -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '.install-bak.*' -or $_.Name -like '.install-build.*' })
    Assert-Eq 'codex.test: codex install leaves no backup/temp dirs' '0' "$($cx_leftover.Count)"
    # A clean codex build passes the drift gate.
    Assert-Exit 'codex.test: codex drift check passes on a clean build' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $CXB_OUT

    # === .agents co-render: loud skip + live-overlay guard ==================
    # Twin of the bash block. Without AGENTS_DIR the codex install skips the
    # co-render LOUDLY; the happy path is covered in drift.test.ps1's -Auto
    # fixture.
    Assert-Contains 'codex.test: codex install skips the .agents co-render loudly when AGENTS_DIR is unset' `
        $cxb_errtext 'AGENTS_DIR not set'

    # A throwaway local.env whose AGENTS_DIR names the repo's LIVE overlay must
    # be refused (the same inherited-var corruption guard the harness-home
    # targets have) — the die fires before any write to the overlay.
    # String-compare based, so it holds whether or not .agents exists here.
    $CXA_ROOT = Join-Path ([IO.Path]::GetTempPath()) ("codex-agents-guard-" + [Guid]::NewGuid().Guid.Substring(0,8))
    $CXA_OUT = Join-Path $CXA_ROOT 'target'
    New-Item -ItemType Directory -Path $CXA_OUT -Force | Out-Null
    $CXA_ENV = Join-Path $CXA_ROOT 'local.env'
    $cxa_lines = @(
        "CODEX_HOME=`"$CXA_OUT`"",
        "OBSIDIAN_VAULT_PATH=`"$CX_VAULT`"",
        "AGENTS_DIR=`"$(Join-Path $env:REPO_ROOT '.agents')`""
    )
    [System.IO.File]::WriteAllText($CXA_ENV, (($cxa_lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    $env:AI_CONFIG_LOCAL_ENV = $CXA_ENV
    $cxa_out = (& pwsh -NoProfile -File $INSTALL_PS1 --harness codex 2>&1) -join "`n"
    $cxa_rc = $LASTEXITCODE
    $env:AI_CONFIG_LOCAL_ENV = $CXB_ENV
    Assert-Eq 'codex.test: codex install refuses a throwaway-local.env co-render into the live overlay' '1' "$cxa_rc"
    Assert-Contains 'codex.test: live-overlay refusal names the guard' $cxa_out 'refusing the .agents co-render into the live overlay'
    Remove-Item -LiteralPath $CXA_ROOT -Recurse -Force -ErrorAction SilentlyContinue

    # === Codex hook behaviour — _Skip on the Windows lane ====================
    # Per [[feedback_port_parity_vs_regression_split]]: the .ps1 codex hooks'
    # run-time behavior (marker recognition + fail-closed/open) is covered in
    # tests/hooks-ps-parity.test.ps1; the bash twin exercises the .sh hooks on
    # macOS/Linux. _Skip preserves the AC count + carries the rationale.
    $hbreason = 'codex .ps1 hook behavior covered in tests/hooks-ps-parity.test.ps1; bash twin runs the .sh hooks'
    _Skip 'codex.test: codex session-agent: no transcript exits 0' $hbreason
    _Skip 'codex.test: codex session-agent: no transcript allows' $hbreason
    _Skip 'codex.test: codex session-agent: no routing exits 0' $hbreason
    _Skip 'codex.test: codex session-agent: no routing blocks' $hbreason
    _Skip 'codex.test: codex session-agent: invoked+Linear allows' $hbreason
    _Skip 'codex.test: codex session-agent: invoked w/o Linear blocks' $hbreason
    _Skip 'codex.test: codex session-agent: kill switch allows' $hbreason
    _Skip 'codex.test: codex framework-surface: emits context exits 0' $hbreason
    _Skip 'codex.test: codex framework-surface: emits additionalContext' $hbreason
    _Skip 'codex.test: codex framework-surface: kill switch is silent' $hbreason
    _Skip 'codex.test: codex framework-surface: session-agent directive exits 0' $hbreason
    _Skip 'codex.test: codex framework-surface: emits session-agent directive header' $hbreason
    _Skip 'codex.test: codex framework-surface: directive references Mode 1' $hbreason
    _Skip 'codex.test: codex framework-surface: directive uses $session-agent' $hbreason
    _Skip 'codex.test: codex framework-surface: directive references kill switch' $hbreason
    _Skip 'codex.test: codex framework-surface: SA-directive kill switch exits 0' $hbreason
    _Skip 'codex.test: codex framework-surface: SA-directive kill switch drops block' $hbreason
    _Skip 'codex.test: codex framework-surface: SA-directive kill switch keeps git-log' $hbreason
    _Skip 'codex.test: codex session-agent: no jq exits 0' $hbreason
    _Skip 'codex.test: codex session-agent: no jq fails closed (blocks)' $hbreason
    _Skip 'codex.test: codex framework-surface: no jq exits 0' $hbreason
    _Skip 'codex.test: codex framework-surface: no jq is silent (open)' $hbreason

    # === Drift gate catches a hand-edited generated entrypoint ==============
    Add-Content -LiteralPath (Join-Path $CXB_OUT 'AGENTS.md') -Value "`nHAND EDIT`n"
    Assert-Exit 'codex.test: codex drift check fails after AGENTS.md is hand-edited' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $CXB_OUT

    Remove-Item -LiteralPath $CXB_ROOT -Recurse -Force -ErrorAction SilentlyContinue
} finally {
    Remove-Item -LiteralPath $CX_ROOT -Recurse -Force -ErrorAction SilentlyContinue
    $env:AI_CONFIG_LOCAL_ENV = $null
}
