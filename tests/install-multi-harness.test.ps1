#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/install-multi-harness.test.ps1 — install.ps1 repeatable --harness.
#
# Twin of tests/install-multi-harness.test.sh. install.ps1 now builds claude,
# codex, AND hermes on Windows (<TEAM>-296), so a multi-harness run builds every
# requested harness (no WARN-skip); a genuinely unknown harness name is rejected
# (pinned in install.test.ps1). This file pins the multi-harness behavior:
#
# 1. `--harness claude --harness codex` builds BOTH, exit 0; `--harness claude
#    --harness hermes` builds BOTH, exit 0.
# 2. Reversed order behaves the same.
# 3. A repeated harness dedupes (builds once).
# 4. --out cannot be combined with multiple --harness.
# 5. bootstrap.ps1's PS-native `-Harness <h> -Out <dir>` single form still
# binds (guards the param-surface change that dropped the bound -Harness).
#
# tests/lib.ps1 is dot-sourced by tests/run.ps1 before each test file — Assert-*,
# _Pass/_Fail and Write-LocalEnvFixture are already in scope.

$INSTALL_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'

Assert-File 'install-multi-harness.test: scripts/install.ps1 exists' $INSTALL_PS1
if (-not (Test-Path -LiteralPath $INSTALL_PS1 -PathType Leaf)) {
    _Skip 'install-multi-harness.test: --harness claude --harness codex/hermes builds all requested' 'install.ps1 missing'
    return
}

# Dual local.env writer (LF + no-BOM, like Write-LocalEnvFixture) — sets BOTH
# harness targets so a claude+codex multi-harness run builds both, not a
# "CODEX_HOME unset" failure for the codex child.
function Write-DualEnvFixture {
    param(
        [Parameter(Mandatory)][string]$EnvFile,
        [Parameter(Mandatory)][string]$ClaudeDir,
        [Parameter(Mandatory)][string]$CodexHome,
        [string]$VaultDir
    )
    $lines = @(
        "CLAUDE_CONFIG_DIR=`"$ClaudeDir`"",
        "CODEX_HOME=`"$CodexHome`"",
        "OBSIDIAN_VAULT_PATH=`"$VaultDir`""
    )
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($EnvFile, (($lines -join "`n") + "`n"), $utf8NoBom)
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("t250-multi-harness-" + [Guid]::NewGuid().Guid.Substring(0,8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

try {
    # --- 1. --harness claude --harness codex: BOTH build (codex now ported) ----
    $cc1   = Join-Path $tmpRoot 'cc1'
    $cx1   = Join-Path $tmpRoot 'cx1'
    $vault = Join-Path $tmpRoot 'vault'
    $env1  = Join-Path $tmpRoot 'env1.local.env'
    New-Item -ItemType Directory -Path $cc1, $cx1, $vault -Force | Out-Null
    Write-DualEnvFixture -EnvFile $env1 -ClaudeDir $cc1 -CodexHome $cx1 -VaultDir $vault

    $env:AI_CONFIG_LOCAL_ENV = $env1
    $null  = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --harness codex 2>&1
    $exit1 = $LASTEXITCODE

    Assert-Eq 'install-multi-harness.test: --harness claude --harness codex exits 0' '0' "$exit1"
    Assert-File 'install-multi-harness.test: multi-harness builds the claude entrypoint' (Join-Path $cc1 'CLAUDE.md')
    Assert-File 'install-multi-harness.test: multi-harness builds the codex entrypoint'  (Join-Path $cx1 'AGENTS.md')

    # --- 1b. --harness claude --harness hermes: BOTH build (hermes now ported) -
    # <TEAM>-296: hermes builds natively on Windows now, so a multi-harness run
    # installs both targets (claude CLAUDE.md + hermes SOUL.md), exit 0.
    $cc1b  = Join-Path $tmpRoot 'cc1b'
    $hm1b  = Join-Path $tmpRoot 'hm1b'
    $env1b = Join-Path $tmpRoot 'env1b.local.env'
    New-Item -ItemType Directory -Path $cc1b, $hm1b -Force | Out-Null
    $utf8NoBom1b = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($env1b, ((@(
        "CLAUDE_CONFIG_DIR=`"$cc1b`"",
        "HERMES_HOME=`"$hm1b`"",
        "OBSIDIAN_VAULT_PATH=`"$vault`""
    ) -join "`n") + "`n"), $utf8NoBom1b)
    $env:AI_CONFIG_LOCAL_ENV = $env1b
    $null   = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --harness hermes 2>&1
    $exit1b = $LASTEXITCODE
    Assert-Eq 'install-multi-harness.test: --harness claude --harness hermes exits 0' '0' "$exit1b"
    Assert-File 'install-multi-harness.test: multi-harness builds the claude entrypoint (with hermes)' (Join-Path $cc1b 'CLAUDE.md')
    Assert-File 'install-multi-harness.test: multi-harness builds the hermes entrypoint'              (Join-Path $hm1b 'SOUL.md')

    # --- 2. Reversed order behaves the same -----------------------------------
    $cc2  = Join-Path $tmpRoot 'cc2'
    $cx2  = Join-Path $tmpRoot 'cx2'
    $env2 = Join-Path $tmpRoot 'env2.local.env'
    New-Item -ItemType Directory -Path $cc2, $cx2 -Force | Out-Null
    Write-DualEnvFixture -EnvFile $env2 -ClaudeDir $cc2 -CodexHome $cx2 -VaultDir $vault
    $env:AI_CONFIG_LOCAL_ENV = $env2
    $null  = & pwsh -NoProfile -File $INSTALL_PS1 --harness codex --harness claude 2>&1
    $exit2 = $LASTEXITCODE
    Assert-Eq 'install-multi-harness.test: --harness codex --harness claude exits 0' '0' "$exit2"
    Assert-File 'install-multi-harness.test: reversed order still builds claude' (Join-Path $cc2 'CLAUDE.md')

    # --- 3. Dedup: repeated harness builds once, succeeds ----------------------
    $cc3  = Join-Path $tmpRoot 'cc3'
    $env3 = Join-Path $tmpRoot 'env3.local.env'
    New-Item -ItemType Directory -Path $cc3 -Force | Out-Null
    Write-LocalEnvFixture -EnvFile $env3 -ConfigDir $cc3 -VaultDir $vault
    $env:AI_CONFIG_LOCAL_ENV = $env3
    $null  = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --harness claude 2>&1
    $exit3 = $LASTEXITCODE
    Assert-Eq 'install-multi-harness.test: --harness claude --harness claude (dedup) exits 0' '0' "$exit3"
    Assert-File 'install-multi-harness.test: deduped repeat builds the claude entrypoint' (Join-Path $cc3 'CLAUDE.md')

    # --- 4. --out cannot target multiple harnesses ----------------------------
    $cc4  = Join-Path $tmpRoot 'cc4'
    $cx4  = Join-Path $tmpRoot 'cx4'
    $env4 = Join-Path $tmpRoot 'env4.local.env'
    New-Item -ItemType Directory -Path $cc4, $cx4 -Force | Out-Null
    Write-DualEnvFixture -EnvFile $env4 -ClaudeDir $cc4 -CodexHome $cx4 -VaultDir $vault
    $outTgt = Join-Path $tmpRoot 'outtgt'
    $env:AI_CONFIG_LOCAL_ENV = $env4
    $out4  = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --harness codex --out $outTgt 2>&1
    $exit4 = $LASTEXITCODE
    $out4Str = if ($out4 -is [array]) { $out4 -join "`n" } else { [string]$out4 }
    Assert-Eq 'install-multi-harness.test: --out + multiple --harness exits 1' '1' "$exit4"
    Assert-Contains 'install-multi-harness.test: --out + multiple --harness names the conflict' $out4Str '--out'
    if (Test-Path -LiteralPath $outTgt -PathType Container -ErrorAction SilentlyContinue) {
        # The dir may pre-exist only if a build started; assert no build landed.
        if (Test-Path -LiteralPath (Join-Path $outTgt 'CLAUDE.md')) {
            _Fail 'install-multi-harness.test: --out + multi-harness makes no partial build' 'CLAUDE.md built into --out target'
        } else {
            _Pass 'install-multi-harness.test: --out + multi-harness makes no partial build'
        }
    } else {
        _Pass 'install-multi-harness.test: --out + multi-harness makes no partial build'
    }

    # --- 5. bootstrap.ps1's invocation form (--harness <h> --out <dir>) -------
    # Guards bootstrap.ps1's first-run install path: it forwards the resolved
    # target via --out because the seeded local.env has an EMPTY CLAUDE_CONFIG_DIR.
    # MUST be the double-dash --out spelling: on Windows, pwsh.exe consumes a
    # single-dash -Out as its own -OutputFormat CLI param (prefix match) before it
    # reaches the script, so the target would be lost. --out is not a pwsh CLI
    # param and passes through verbatim. (env5 has NO CLAUDE_CONFIG_DIR, so the
    # build can ONLY succeed if --out actually delivered the target.)
    $cc5  = Join-Path $tmpRoot 'cc5'
    $env5 = Join-Path $tmpRoot 'env5.local.env'
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($env5, ("OBSIDIAN_VAULT_PATH=`"$vault`"`n"), $utf8NoBom)
    $env:AI_CONFIG_LOCAL_ENV = $env5
    $out5  = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --out $cc5 2>&1
    $exit5 = $LASTEXITCODE
    $out5Str = if ($out5 -is [array]) { $out5 -join "`n" } else { [string]$out5 }
    if ($exit5 -eq 0) {
        _Pass 'install-multi-harness.test: bootstrap form --harness claude --out <dir> exits 0'
    } else {
        _Fail 'install-multi-harness.test: bootstrap form --harness claude --out <dir> exits 0' "exit=$exit5", $out5Str
    }
    Assert-File 'install-multi-harness.test: bootstrap form --harness/--out builds the claude entrypoint' (Join-Path $cc5 'CLAUDE.md')

    # --- 6. Case-insensitive dedup: claude + CLAUDE builds claude once ---------
    # List[string].Contains is ordinal, but harness names are lowercased before
    # dedup, so `--harness claude --harness CLAUDE` collapses to ONE request and
    # builds the single claude target once (not twice). A full install (single
    # target after dedup) is the proof — pre-fix this dispatched two children.
    $cc6  = Join-Path $tmpRoot 'cc6'
    $env6 = Join-Path $tmpRoot 'env6.local.env'
    New-Item -ItemType Directory -Path $cc6 -Force | Out-Null
    Write-LocalEnvFixture -EnvFile $env6 -ConfigDir $cc6 -VaultDir $vault
    $env:AI_CONFIG_LOCAL_ENV = $env6
    $null  = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --harness CLAUDE 2>&1
    $exit6 = $LASTEXITCODE
    Assert-Eq 'install-multi-harness.test: --harness claude --harness CLAUDE (case dedup) exits 0' '0' "$exit6"
    Assert-File 'install-multi-harness.test: case-variant repeat builds the claude entrypoint' (Join-Path $cc6 'CLAUDE.md')

    # --- 7. --build-only cannot be combined with multiple --harness ------------
    $cc7  = Join-Path $tmpRoot 'cc7'
    $cx7  = Join-Path $tmpRoot 'cx7'
    $env7 = Join-Path $tmpRoot 'env7.local.env'
    New-Item -ItemType Directory -Path $cc7, $cx7 -Force | Out-Null
    Write-DualEnvFixture -EnvFile $env7 -ClaudeDir $cc7 -CodexHome $cx7 -VaultDir $vault
    $env:AI_CONFIG_LOCAL_ENV = $env7
    $out7  = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --harness codex --build-only 2>&1
    $exit7 = $LASTEXITCODE
    $out7Str = if ($out7 -is [array]) { $out7 -join "`n" } else { [string]$out7 }
    Assert-Eq 'install-multi-harness.test: --build-only + multiple --harness exits 1' '1' "$exit7"
    Assert-Contains 'install-multi-harness.test: --build-only + multiple --harness names the conflict' $out7Str '--build-only'

    # --- 8. Live config-dir guard: a throwaway build can't overwrite a live dir
    # Twin of the bash guard test (section 10). install.ps1 refuses to render a
    # throwaway-env build into a forbidden live dir and exits non-zero WITHOUT
    # writing it. Pinned SAFELY against a temp dir via AI_CONFIG_FORBID_TARGETS —
    # never the operator's real .codex — so a guard regression can never corrupt a
    # live entrypoint. The inline CODEX_HOME simulates the leaked inherited value.
    $gdLive = Join-Path $tmpRoot 'live-codex'
    New-Item -ItemType Directory -Path $gdLive -Force | Out-Null
    $utf8NoBom8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Join-Path $gdLive 'AGENTS.md'), "SENTINEL-DO-NOT-OVERWRITE`n", $utf8NoBom8)
    $gdEnv = Join-Path $tmpRoot 'env8.local.env'
    # Fixture sets OBSIDIAN_VAULT_PATH but NOT CODEX_HOME — the leak precondition.
    [System.IO.File]::WriteAllText($gdEnv, ("OBSIDIAN_VAULT_PATH=`"$vault`"`n"), $utf8NoBom8)
    $env:AI_CONFIG_LOCAL_ENV = $gdEnv
    $env:AI_CONFIG_FORBID_TARGETS = $gdLive
    $env:CODEX_HOME = $gdLive
    $gdOut  = & pwsh -NoProfile -File $INSTALL_PS1 --harness codex 2>&1
    $gdExit = $LASTEXITCODE
    $env:CODEX_HOME = $null
    $env:AI_CONFIG_FORBID_TARGETS = $null
    $gdStr = if ($gdOut -is [array]) { $gdOut -join "`n" } else { [string]$gdOut }
    Assert-Eq 'install-multi-harness.test: guard blocks throwaway build into a live dir (exit 1)' '1' "$gdExit"
    Assert-Contains 'install-multi-harness.test: guard names the refusal' $gdStr 'refusing to render'
    $gdSentinel = ([System.IO.File]::ReadAllText((Join-Path $gdLive 'AGENTS.md'))).Trim()
    Assert-Eq 'install-multi-harness.test: guard leaves the live AGENTS.md intact' 'SENTINEL-DO-NOT-OVERWRITE' $gdSentinel

    # The escape hatch lets a deliberate custom-env co-located install through.
    $env:AI_CONFIG_LOCAL_ENV = $gdEnv
    $env:AI_CONFIG_FORBID_TARGETS = $gdLive
    $env:CODEX_HOME = $gdLive
    $env:AI_CONFIG_ALLOW_LIVE_TARGET = '1'
    $null   = & pwsh -NoProfile -File $INSTALL_PS1 --harness codex 2>&1
    $ovExit = $LASTEXITCODE
    $env:AI_CONFIG_ALLOW_LIVE_TARGET = $null
    $env:CODEX_HOME = $null
    $env:AI_CONFIG_FORBID_TARGETS = $null
    Assert-Eq 'install-multi-harness.test: AI_CONFIG_ALLOW_LIVE_TARGET=1 overrides the refusal (exit 0)' '0' "$ovExit"
    Assert-File 'install-multi-harness.test: override actually rendered the codex entrypoint' (Join-Path $gdLive 'AGENTS.md')

    # --- 9. Guard refuses BEFORE creating a missing forbidden dir (no mutation)
    # Twin of bash section 11: the guard runs before New-Item, so a refusal must
    # not even CREATE the live dir. (cross-model adversarial finding.)
    $gmMissing = Join-Path $tmpRoot 'never-created'   # forbidden target, absent
    $gmEnv = Join-Path $tmpRoot 'env9.local.env'
    [System.IO.File]::WriteAllText($gmEnv, ("OBSIDIAN_VAULT_PATH=`"$vault`"`n"), $utf8NoBom8)
    $env:AI_CONFIG_LOCAL_ENV = $gmEnv
    $env:AI_CONFIG_FORBID_TARGETS = $gmMissing
    $env:CODEX_HOME = $gmMissing
    $null   = & pwsh -NoProfile -File $INSTALL_PS1 --harness codex 2>&1
    $gmExit = $LASTEXITCODE
    $env:CODEX_HOME = $null
    $env:AI_CONFIG_FORBID_TARGETS = $null
    Assert-Eq 'install-multi-harness.test: guard into a missing forbidden dir exits 1' '1' "$gmExit"
    if (Test-Path -LiteralPath $gmMissing) {
        _Fail 'install-multi-harness.test: refusal does NOT create the forbidden dir' "$gmMissing was created before the guard fired"
    } else {
        _Pass 'install-multi-harness.test: refusal does NOT create the forbidden dir'
    }

    # --- 10. Guard fires for --build-only too — no transient under the live dir
    # Twin of bash section 12: --build-only would mktemp a .install-build tree
    # under the target; the guard must block it first. (cross-model finding.)
    $gbLive = Join-Path $tmpRoot 'live-codex-bo'
    New-Item -ItemType Directory -Path $gbLive -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $gbLive 'AGENTS.md'), "SENTINEL-BUILD-ONLY`n", $utf8NoBom8)
    $gbEnv = Join-Path $tmpRoot 'env10.local.env'
    [System.IO.File]::WriteAllText($gbEnv, ("OBSIDIAN_VAULT_PATH=`"$vault`"`n"), $utf8NoBom8)
    $env:AI_CONFIG_LOCAL_ENV = $gbEnv
    $env:AI_CONFIG_FORBID_TARGETS = $gbLive
    $env:CODEX_HOME = $gbLive
    $null   = & pwsh -NoProfile -File $INSTALL_PS1 --harness codex --build-only 2>&1
    $gbExit = $LASTEXITCODE
    $env:CODEX_HOME = $null
    $env:AI_CONFIG_FORBID_TARGETS = $null
    Assert-Eq 'install-multi-harness.test: --build-only into a forbidden live dir exits 1' '1' "$gbExit"
    $gbSentinel = ([System.IO.File]::ReadAllText((Join-Path $gbLive 'AGENTS.md'))).Trim()
    Assert-Eq 'install-multi-harness.test: --build-only leaves AGENTS.md intact' 'SENTINEL-BUILD-ONLY' $gbSentinel
    $gbTransient = @(Get-ChildItem -LiteralPath $gbLive -Filter '.install-build.*' -Force -ErrorAction SilentlyContinue)
    Assert-Eq 'install-multi-harness.test: --build-only leaves no .install-build transient' '0' "$($gbTransient.Count)"
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    $env:AI_CONFIG_LOCAL_ENV = $null
    $env:AI_CONFIG_FORBID_TARGETS = $null
    $env:AI_CONFIG_ALLOW_LIVE_TARGET = $null
    $env:CODEX_HOME = $null
}
