#Requires -Version 7
# tests/install-render-stable.test.ps1 — Windows-native twin of
# tests/install-render-stable.test.sh.
#
# install-render stability gate. Mirrors the bash twin 1:1 for the
# fixture-completeness check + claude harness build + byte-deterministic
# re-render. The codex build assertion is SKIPped on the Windows lane
# because install.ps1 doesn't yet support codex.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$INSTALL_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'

$IRS_DIR = Join-Path ([IO.Path]::GetTempPath()) ('irs-' + [Guid]::NewGuid().Guid.Substring(0,8))
$IRS_CLAUDE_TGT = Join-Path $IRS_DIR 'claude'
$IRS_CODEX_TGT  = Join-Path $IRS_DIR 'codex'
$IRS_ENV_CLAUDE = Join-Path $IRS_DIR 'claude.local.env'
$IRS_ENV_CODEX  = Join-Path $IRS_DIR 'codex.local.env'
$IRS_CI_FIXTURE = Join-Path $env:REPO_ROOT 'tests' 'fixtures' 'ci.local.env'
New-Item -ItemType Directory -Path $IRS_DIR -Force | Out-Null

# --- Assertion 0: fixture is provably complete vs active templates ----------
# OPERATOR_SKILLS_OVERLAY + OPERATOR_CODEX_RULES_OVERLAY are injection markers
# consumed before the @@VAR@@ loop (install.{sh,ps1} splice the operator overlay
# at each, or empty for a spine-only render) — not env-sourced path vars, so they
# skip the fixture completeness check like CAPABILITY_CATALOG. See the.sh twin.
$irs_special_tokens = @('CAPABILITY_CATALOG', 'OPERATOR_SKILLS_OVERLAY', 'OPERATOR_CODEX_RULES_OVERLAY')
$irs_active_surfaces = @(
    (Join-Path $env:REPO_ROOT 'harnesses' 'claude' 'CLAUDE.template.md'),
    (Join-Path $env:REPO_ROOT 'harnesses' 'claude' 'SKILLS.template.md'),
    (Join-Path $env:REPO_ROOT 'harnesses' 'codex' 'AGENTS.template.md'),
    (Join-Path $env:REPO_ROOT 'harnesses' 'claude' 'hooks' 'framework-surface.sh'),
    (Join-Path $env:REPO_ROOT 'harnesses' 'codex' 'hooks' 'framework-surface.sh')
)

$tokenRe = '@@([A-Z_][A-Z0-9_]*)@@'
$tokenSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($surf in $irs_active_surfaces) {
    if (-not (Test-Path -LiteralPath $surf -PathType Leaf)) { continue }
    $content = Get-Content -LiteralPath $surf -Raw
    foreach ($m in [regex]::Matches($content, $tokenRe)) {
        [void]$tokenSet.Add($m.Groups[1].Value)
    }
}
$irs_all_tokens = @($tokenSet | Sort-Object)

# Fixture keys (lines like VAR=...)
$irs_fixture_keys = New-Object System.Collections.Generic.HashSet[string]
foreach ($line in Get-Content -LiteralPath $IRS_CI_FIXTURE) {
    if ($line -cmatch '^([A-Z_][A-Z0-9_]*)=') {
        [void]$irs_fixture_keys.Add($Matches[1])
    }
}

$irs_completeness_msgs = New-Object System.Collections.Generic.List[string]
foreach ($var in $irs_all_tokens) {
    if ($irs_special_tokens -contains $var) { continue }
    if ($var -cmatch '[0-9]') {
        [void]$irs_completeness_msgs.Add("placeholder @@$var@@ contains a digit — install.sh's substitution regex [A-Z_]+ would silently skip it (F2)")
        continue
    }
    if (-not $irs_fixture_keys.Contains($var)) {
        [void]$irs_completeness_msgs.Add("placeholder @@$var@@ present in active templates/hooks but missing from tests/fixtures/ci.local.env (F1)")
    }
}

if ($irs_completeness_msgs.Count -eq 0) {
    _Pass 'install-render-stable.test: fixture covers every active-template @@VAR@@ (F1+F2)'
} else {
    _Fail 'install-render-stable.test: fixture covers every active-template @@VAR@@ (F1+F2)' `
        ($irs_completeness_msgs | Select-Object -First 20)
}

# Build per-harness local.env files from the SHIPPED CI fixture, overriding
# CLAUDE_CONFIG_DIR / CODEX_HOME to the per-run tmp target.
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$fixtureContent = Get-Content -LiteralPath $IRS_CI_FIXTURE -Raw
[System.IO.File]::WriteAllText($IRS_ENV_CLAUDE, ($fixtureContent + "`nCLAUDE_CONFIG_DIR=`"$IRS_CLAUDE_TGT`"`n"), $utf8NoBom)
[System.IO.File]::WriteAllText($IRS_ENV_CODEX,  ($fixtureContent + "`nCODEX_HOME=`"$IRS_CODEX_TGT`"`n"), $utf8NoBom)

# --- Assertion 1: claude harness build is green -----------------------------
$env:AI_CONFIG_LOCAL_ENV = $IRS_ENV_CLAUDE
try {
    $irs_claude_out = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --build-only 2>&1
    $irs_claude_status = $LASTEXITCODE
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
if ($irs_claude_out -is [array]) { $irs_claude_out_str = $irs_claude_out -join "`n" } else { $irs_claude_out_str = "$irs_claude_out" }
Assert-Eq 'install-render-stable.test: install.ps1 --harness claude --build-only exits 0 with CI fixture' '0' "$irs_claude_status"
if ($irs_claude_status -ne 0) {
    [Console]::Error.WriteLine("       install.ps1 output:`n$irs_claude_out_str")
}

# --- Assertion 2: codex harness build — DEFERRED -----------------------------
# install.ps1 doesn't support codex yet. The bash twin runs
# install.sh --harness codex; the PS twin SKIPs with rationale.
_Skip 'install-render-stable.test: install.ps1 --harness codex --build-only exits 0 with CI fixture' `
    'install.ps1 codex harness not implemented'

# --- Assertion 2b: no overlay marker survives into the rendered claude surface ---
# Twin of the .sh assertion 2b: assertion 0 exempts the @@OPERATOR_*_OVERLAY@@
# injection markers from the completeness check globally; this asserts directly
# that the BUILT tree carries zero residual overlay markers, so a marker leaked
# into a non-consuming surface (e.g. a hook) is caught. PS covers the claude build;
# the codex build is bash-only (assertion 2), so the .sh twin covers codex.
# Pattern from halves so this source isn't a stray literal copy of either marker.
$irsOvlRe = '@@OPERATOR_[A-Z_]*' + '_OVERLAY@@'
$env:AI_CONFIG_LOCAL_ENV = $IRS_ENV_CLAUDE
try {
    $irsOvlOut = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --build-only 2>$null
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
$irsOvlBd = @($irsOvlOut | Where-Object { $_ -ne '' }) | Select-Object -Last 1
$irsOvlHits = @()
if ($irsOvlBd -and (Test-Path -LiteralPath $irsOvlBd)) {
    $irsOvlHits = @(Get-ChildItem -LiteralPath $irsOvlBd -Recurse -File |
        Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match $irsOvlRe } |
        ForEach-Object { $_.FullName })
}
Assert-Eq 'install-render-stable.test: no @@OPERATOR_*_OVERLAY@@ marker survives into the rendered claude surface' `
    '' ($irsOvlHits -join "`n")
if ($irsOvlBd) { Remove-Item -LiteralPath $irsOvlBd -Recurse -Force -ErrorAction SilentlyContinue }

# --- Assertion 3: re-render is byte-deterministic ---------------------------
$IRS_DET_TGT = Join-Path $IRS_DIR 'det_shared'
$IRS_ENV_DET = Join-Path $IRS_DIR 'det.local.env'
[System.IO.File]::WriteAllText($IRS_ENV_DET, ($fixtureContent + "`nCLAUDE_CONFIG_DIR=`"$IRS_DET_TGT`"`n"), $utf8NoBom)

$env:AI_CONFIG_LOCAL_ENV = $IRS_ENV_DET
try {
    $irs_det_a_raw = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --build-only 2>$null
    $irs_det_b_raw = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --build-only 2>$null
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
if ($irs_det_a_raw -is [array]) { $irs_det_a = $irs_det_a_raw | Select-Object -Last 1 } else { $irs_det_a = $irs_det_a_raw }
if ($irs_det_b_raw -is [array]) { $irs_det_b = $irs_det_b_raw | Select-Object -Last 1 } else { $irs_det_b = $irs_det_b_raw }

if ($irs_det_a -and $irs_det_b -and `
    (Test-Path -LiteralPath (Join-Path $irs_det_a '.build-manifest.json') -PathType Leaf) -and `
    (Test-Path -LiteralPath (Join-Path $irs_det_b '.build-manifest.json') -PathType Leaf)) {
    $stream = [System.IO.File]::OpenRead((Join-Path $irs_det_a '.build-manifest.json'))
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $irs_hash_a = ([System.BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
    } finally { $stream.Dispose() }
    $stream = [System.IO.File]::OpenRead((Join-Path $irs_det_b '.build-manifest.json'))
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $irs_hash_b = ([System.BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
    } finally { $stream.Dispose() }
    Assert-Eq 'install-render-stable.test: build manifest is byte-deterministic across re-renders' `
        $irs_hash_a $irs_hash_b
    if ($irs_hash_a -ne $irs_hash_b) {
        [Console]::Error.WriteLine("       manifest A: $irs_det_a/.build-manifest.json")
        [Console]::Error.WriteLine("       manifest B: $irs_det_b/.build-manifest.json")
    }
    Remove-Item -LiteralPath $irs_det_a -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $irs_det_b -Recurse -Force -ErrorAction SilentlyContinue
} else {
    _Fail 'install-render-stable.test: determinism assertion could not run (one or both builds failed)' @(
        "build A path: [$irs_det_a]",
        "build B path: [$irs_det_b]"
    )
}

# --- Assertion 4: the durable-knowledge vault is OPTIONAL. A build with an EMPTY
# OBSIDIAN_VAULT_PATH must SUCCEED (exit 0) and render the unset sentinel into the
# entrypoint — never the raw @@OBSIDIAN_VAULT_PATH@@ token, and never a hard die.
# Mirrors the bash twin's assertion 4 (the first-run promise: no vault still builds).
$irsNvLines = @(Get-Content -LiteralPath $IRS_CI_FIXTURE | Where-Object { $_ -notmatch '^OBSIDIAN_VAULT_PATH=' })
$irsNvEnv = Join-Path $IRS_DIR 'novault.local.env'
$irsNvTgt = Join-Path $IRS_DIR 'novault-claude'
$irsNvBody = ($irsNvLines -join "`n") + "`nOBSIDIAN_VAULT_PATH=`nCLAUDE_CONFIG_DIR=`"$irsNvTgt`"`n"
[System.IO.File]::WriteAllText($irsNvEnv, $irsNvBody, $utf8NoBom)

$env:AI_CONFIG_LOCAL_ENV = $irsNvEnv
try {
    $irsNvOut = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --build-only 2>&1
    $irsNvStatus = $LASTEXITCODE
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
Assert-Eq 'install-render-stable.test: install.ps1 --harness claude --build-only exits 0 with an EMPTY vault (vault is optional)' '0' "$irsNvStatus"

$irsNvBd = @($irsNvOut | Where-Object { $_ -ne '' }) | Select-Object -Last 1
if ($irsNvBd -and (Test-Path -LiteralPath (Join-Path $irsNvBd 'CLAUDE.md') -PathType Leaf)) {
    $irsNvMd = Get-Content -Raw -LiteralPath (Join-Path $irsNvBd 'CLAUDE.md')
    if ($irsNvMd.Contains('@@OBSIDIAN_VAULT_PATH@@')) {
        _Fail 'install-render-stable.test: empty-vault build renders the unset sentinel, not the raw token' `
            'found unresolved @@OBSIDIAN_VAULT_PATH@@ in the rendered entrypoint'
    } elseif ($irsNvMd.Contains('the durable-knowledge vault is optional')) {
        _Pass 'install-render-stable.test: empty-vault build renders the unset sentinel, not the raw token'
    } else {
        _Fail 'install-render-stable.test: empty-vault build renders the unset sentinel, not the raw token' `
            'rendered entrypoint contains neither the sentinel nor the raw token'
    }
    Remove-Item -LiteralPath $irsNvBd -Recurse -Force -ErrorAction SilentlyContinue
} else {
    _Fail 'install-render-stable.test: empty-vault build produced an inspectable CLAUDE.md' "build path: [$irsNvBd]"
}

Remove-Item -LiteralPath $IRS_DIR -Recurse -Force -ErrorAction SilentlyContinue
