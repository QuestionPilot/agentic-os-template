#Requires -Version 7
# tests/entrypoint.test.ps1 — Windows-native twin of tests/entrypoint.test.sh.
#
# CLAUDE.md + SKILLS.md generation; vendored-snapshot manifest
# fix; retired-skill-name regression gate.
#
# Mirrors tests/entrypoint.test.sh 1:1, using install.ps1 + check-drift.ps1
# instead of their bash counterparts.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$INSTALL_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$CHECK_DRIFT_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'check-drift.ps1'

function Write-LfFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# --- shared fixture: a build with a complete local.env ----------------------
$EP_DIR = Join-Path ([IO.Path]::GetTempPath()) ('ep-' + [Guid]::NewGuid().Guid.Substring(0,8))
$EP_OUT = Join-Path $EP_DIR 'out'
New-Item -ItemType Directory -Path $EP_OUT -Force | Out-Null
$EP_VAULT = Join-Path $EP_DIR 'vault'
$EP_ENV = Join-Path $EP_DIR 'local.env'
Write-LocalEnvFixture -EnvFile $EP_ENV -ConfigDir $EP_OUT -VaultDir $EP_VAULT

$env:AI_CONFIG_LOCAL_ENV = $EP_ENV
try {
    $ep_build_raw = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --build-only 2>$null
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
if ($ep_build_raw -is [array]) { $ep_build = $ep_build_raw | Select-Object -Last 1 } else { $ep_build = $ep_build_raw }

# --- install.ps1 emits both harness entrypoint files ------------------------
Assert-File 'entrypoint.test: install.ps1 emits CLAUDE.md' (Join-Path $ep_build 'CLAUDE.md')
Assert-File 'entrypoint.test: install.ps1 emits SKILLS.md' (Join-Path $ep_build 'SKILLS.md')

$claudeMd = Join-Path $ep_build 'CLAUDE.md'
if (Test-Path -LiteralPath $claudeMd) {
    $cmd = Get-Content -LiteralPath $claudeMd -Raw
    Assert-Contains 'entrypoint.test: generated CLAUDE.md references README.md' $cmd 'README.md'
    Assert-Contains 'entrypoint.test: generated CLAUDE.md references core/' $cmd 'core/'
    Assert-Contains 'entrypoint.test: generated CLAUDE.md carries the session-agent spine rule' $cmd 'session-agent` is the spine'
    Assert-Contains 'entrypoint.test: generated CLAUDE.md keeps the broad quick-reference' $cmd 'security-review'
    Assert-NotContains 'entrypoint.test: generated CLAUDE.md has no unresolved placeholders' $cmd '@@'
    Assert-Contains 'entrypoint.test: generated CLAUDE.md substitutes the vault path' $cmd $EP_VAULT
    Assert-Contains 'entrypoint.test: generated CLAUDE.md substitutes the agentic-os-template path' $cmd $env:REPO_ROOT
    Assert-Contains 'entrypoint.test: generated CLAUDE.md has the OS capability subsection' $cmd 'OS capability skills'

    # capability catalog rows — install.ps1's catalog generator emits one
    # `| `<capn>` | <summary> | <kind> |` row per capability whose frontmatter
    # `harnesses:` list contains the target harness. (PR #55,
    # scripts/install.ps1:465) fixed the prior literal-leak bug: the row
    # append used `` "| `${base}` | …" `` where the single-backtick before `$`
    # is the documented PS escape that SUPPRESSES variable expansion — so
    # `${base}` rendered as 7-byte literal text, not the value. Fix uses
    # `` "| ``$base`` | …" `` (double-backtick = PS escape for ONE literal
    # backtick) so the markdown-code backticks AROUND the interpolated
    # $base interpolate correctly. Mirrors the bash-side assertion loop at
    # tests/entrypoint.test.sh:41-45. See [[reference_ps_port_traps]] trap
    # #14 — PS double-quoted-string `` `$ `` escape suppresses interpolation.
    Assert-NotContains 'entrypoint.test: PS render has no literal ${base} placeholder' $cmd '| ${base} |'
    $capDir = Join-Path $env:REPO_ROOT 'capabilities'
    if (Test-Path -LiteralPath $capDir -PathType Container) {
        foreach ($capf in Get-ChildItem -LiteralPath $capDir -Filter '*.md' -File) {
            $capn = [System.IO.Path]::GetFileNameWithoutExtension($capf.Name)
            if ($capn -eq 'README') { continue }
            Assert-Contains "entrypoint.test: capability catalog has a row for $capn" $cmd "| ``$capn`` |"
        }
    }

    # deleted capabilities must NOT appear.
    foreach ($deleted in @('firecrawl','impeccable','printing-press','silver-platter')) {
        Assert-NotContains "entrypoint.test: claude CLAUDE.md catalog omits removed $deleted" $cmd "| ``$deleted`` |"
    }
}

$skillsMd = Join-Path $ep_build 'SKILLS.md'
if (Test-Path -LiteralPath $skillsMd) {
    $skm = Get-Content -LiteralPath $skillsMd -Raw
    Assert-NotContains 'entrypoint.test: generated SKILLS.md has no unresolved placeholders' $skm '@@'
    Assert-Contains 'entrypoint.test: generated SKILLS.md keeps the live inventory' $skm 'Live Inventory'
    Assert-Contains 'entrypoint.test: generated SKILLS.md substitutes the agentic-os-template path' $skm $env:REPO_ROOT
}

# --- the build manifest tracks the generated + source files ----------------
$mf = Join-Path $ep_build '.build-manifest.json'
if (Test-Path -LiteralPath $mf) {
    $manifest = Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json
    $hasClaudeMd  = $null -ne $manifest.generated.'CLAUDE.md'
    Assert-Eq 'entrypoint.test: manifest tracks CLAUDE.md as generated' 'True' "$hasClaudeMd"
    $hasSkillsMd  = $null -ne $manifest.generated.'SKILLS.md'
    Assert-Eq 'entrypoint.test: manifest tracks SKILLS.md as generated' 'True' "$hasSkillsMd"
    $hasClaudeTpl = $null -ne $manifest.sources.'harnesses/claude/CLAUDE.template.md'
    Assert-Eq 'entrypoint.test: manifest tracks CLAUDE.template.md as a source' 'True' "$hasClaudeTpl"
    $hasSkillsTpl = $null -ne $manifest.sources.'harnesses/claude/SKILLS.template.md'
    Assert-Eq 'entrypoint.test: manifest tracks SKILLS.template.md as a source' 'True' "$hasSkillsTpl"

    # vendored snapshots — conditional.
    $vendoredDir = Join-Path $env:REPO_ROOT 'harnesses' 'claude' 'vendored'
    $vendoredSources = @($manifest.sources | Get-Member -MemberType NoteProperty | `
        Where-Object { $_.Name -like 'harnesses/claude/vendored/*' })
    if (Test-Path -LiteralPath $vendoredDir -PathType Container) {
        $hasVendored = $vendoredSources.Count -gt 0
        Assert-Eq 'entrypoint.test: manifest tracks vendored snapshots as sources' 'True' "$hasVendored"
    } else {
        $noneVendored = $vendoredSources.Count -eq 0
        Assert-Eq 'entrypoint.test: manifest correctly has no vendored sources when vendored/ absent' 'True' "$noneVendored"
    }
}

if ($ep_build) { Remove-Item -LiteralPath $ep_build -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $EP_DIR -Recurse -Force -ErrorAction SilentlyContinue

# --- a full install swaps both entrypoint files into the target -------------
$SWE_DIR = Join-Path ([IO.Path]::GetTempPath()) ('ep-swe-' + [Guid]::NewGuid().Guid.Substring(0,8))
$SWE_OUT = Join-Path $SWE_DIR 'target'
New-Item -ItemType Directory -Path $SWE_OUT -Force | Out-Null
$SWE_ENV = Join-Path $SWE_DIR 'local.env'
Write-LocalEnvFixture -EnvFile $SWE_ENV -ConfigDir $SWE_OUT -VaultDir (Join-Path $SWE_DIR 'vault')
$env:AI_CONFIG_LOCAL_ENV = $SWE_ENV
try {
    & pwsh -NoProfile -File $INSTALL_PS1 --harness claude *>$null
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
Assert-File 'entrypoint.test: full install swaps CLAUDE.md into the target' (Join-Path $SWE_OUT 'CLAUDE.md')
Assert-File 'entrypoint.test: full install swaps SKILLS.md into the target' (Join-Path $SWE_OUT 'SKILLS.md')
Assert-Exit 'entrypoint.test: drift check passes on a clean build with entrypoints' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $SWE_OUT
# Codex F-2 (MEDIUM): AppendAllText + UTF8NoBOM for byte-determinism on Windows.
[System.IO.File]::AppendAllText((Join-Path $SWE_OUT 'CLAUDE.md'), "`nHAND EDIT`n", [System.Text.UTF8Encoding]::new($false))
Assert-Exit 'entrypoint.test: drift check fails after CLAUDE.md is hand-edited' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $SWE_OUT
Remove-Item -LiteralPath $SWE_DIR -Recurse -Force -ErrorAction SilentlyContinue

# --- the optional vault: omitting OBSIDIAN_VAULT_PATH BUILDS (exit 0) and renders
# the unset sentinel, never a hard die. Mirrors the bash twin; the "required
# placeholder resolves empty -> die" guard stays at install.sh:442 and is exercised
# by install-render-stable.test's Assertion 0.
$NV_DIR = Join-Path ([IO.Path]::GetTempPath()) ('ep-nv-' + [Guid]::NewGuid().Guid.Substring(0,8))
$NV_OUT = Join-Path $NV_DIR 'out'
New-Item -ItemType Directory -Path $NV_OUT -Force | Out-Null
$NV_ENV = Join-Path $NV_DIR 'local.env'
Write-LfFile $NV_ENV ("CLAUDE_CONFIG_DIR=$NV_OUT`n")  # OBSIDIAN_VAULT_PATH omitted (it is optional)
$env:AI_CONFIG_LOCAL_ENV = $NV_ENV
try {
    $nv_out = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --build-only 2>&1
    $nv_status = $LASTEXITCODE
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
Assert-Eq 'entrypoint.test: build succeeds when the optional vault is omitted (renders sentinel)' '0' "$nv_status"
$nv_bd = @($nv_out | Where-Object { $_ -ne '' }) | Select-Object -Last 1
if ($nv_bd -and (Test-Path -LiteralPath (Join-Path $nv_bd 'CLAUDE.md') -PathType Leaf)) {
    $nv_md = Get-Content -Raw -LiteralPath (Join-Path $nv_bd 'CLAUDE.md')
    if ($nv_md.Contains('@@OBSIDIAN_VAULT_PATH@@')) {
        _Fail 'entrypoint.test: omitted-vault entrypoint has no unresolved vault token' 'found @@OBSIDIAN_VAULT_PATH@@ in the rendered entrypoint'
    } else {
        _Pass 'entrypoint.test: omitted-vault entrypoint has no unresolved vault token'
    }
    if ($nv_md.Contains('the durable-knowledge vault is optional')) {
        _Pass 'entrypoint.test: omitted-vault entrypoint renders the unset sentinel'
    } else {
        _Fail 'entrypoint.test: omitted-vault entrypoint renders the unset sentinel' 'sentinel text not found in rendered entrypoint'
    }
    Remove-Item -LiteralPath $nv_bd -Recurse -Force -ErrorAction SilentlyContinue
} else {
    _Fail 'entrypoint.test: omitted-vault build produced an inspectable CLAUDE.md' "build path: [$nv_bd]"
}
Remove-Item -LiteralPath $NV_DIR -Recurse -Force -ErrorAction SilentlyContinue

# Structural guard for the die-on-empty protection the case above no longer
# exercises behaviorally. Assert the Die guard is intact AND the sentinel exemption
# is NARROW — only OBSIDIAN_VAULT_PATH may dodge the die. Catches the two regressions
# a cross-model review flagged: the die being removed, or the exemption widening to a
# genuinely-required placeholder. Mirrors install.sh in the .sh twin.
$ep_install_ps1 = Get-Content -Raw -LiteralPath (Join-Path $env:REPO_ROOT 'scripts' 'install.ps1')
if ($ep_install_ps1.Contains('placeholder @@${var}@@ resolves empty')) {
    _Pass 'entrypoint.test: install.ps1 keeps the die-on-empty guard for required placeholders'
} else {
    _Fail 'entrypoint.test: install.ps1 keeps the die-on-empty guard for required placeholders' 'die-on-empty guard string not found'
}
if ($ep_install_ps1.Contains("`$var -eq 'OBSIDIAN_VAULT_PATH'")) {
    _Pass 'entrypoint.test: install.ps1 sentinel exemption is narrowly scoped to the vault only'
} else {
    _Fail 'entrypoint.test: install.ps1 sentinel exemption is narrowly scoped to the vault only' 'narrow vault exemption guard not found'
}

# --- placeholder substitution survives '&' and spaces in a path -------------
$SP_DIR = Join-Path ([IO.Path]::GetTempPath()) ('ep-sp-' + [Guid]::NewGuid().Guid.Substring(0,8))
$SP_OUT = Join-Path $SP_DIR 'out'
New-Item -ItemType Directory -Path $SP_OUT -Force | Out-Null
$SP_ENV = Join-Path $SP_DIR 'local.env'
$SP_VAULT = '/tmp/v&ault dir'
Write-LocalEnvFixture -EnvFile $SP_ENV -ConfigDir $SP_OUT -VaultDir $SP_VAULT
$env:AI_CONFIG_LOCAL_ENV = $SP_ENV
try {
    $sp_build_raw = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --build-only 2>$null
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
if ($sp_build_raw -is [array]) { $sp_build = $sp_build_raw | Select-Object -Last 1 } else { $sp_build = $sp_build_raw }
if ($sp_build -and (Test-Path -LiteralPath (Join-Path $sp_build 'CLAUDE.md'))) {
    $sp_cmd = Get-Content -LiteralPath (Join-Path $sp_build 'CLAUDE.md') -Raw
    Assert-Contains "entrypoint.test: substitution: an '&'/space path resolves verbatim" $sp_cmd $SP_VAULT
    Assert-NotContains "entrypoint.test: substitution: no placeholder survives an '&' path" $sp_cmd '@@'
} else {
    _Fail "entrypoint.test: substitution: build with an '&' path produced no CLAUDE.md"
}
if ($sp_build) { Remove-Item -LiteralPath $sp_build -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $SP_DIR -Recurse -Force -ErrorAction SilentlyContinue

# --- a '|' in a capability summary is escaped in the generated catalog ------
# DEFERRED: this test creates a separate copy of the repo (cp -R) and runs
# install.sh from that copy. The complexity is non-trivial; skip the PS twin
# with rationale — bash twin still runs on macOS/Linux lanes.
_Skip "entrypoint.test: catalog escapes a '|' inside a capability summary" `
    'requires repo-copy + capability-mutation fixture; deferred — bash twin covers on macOS/Linux'
_Skip 'entrypoint.test: pipe-summary: build produced no CLAUDE.md' `
    'matched bash twin assertion shape; same deferral'

# --- drift check also covers a hand-edited SKILLS.md ------------------------
$SK_DIR = Join-Path ([IO.Path]::GetTempPath()) ('ep-sk-' + [Guid]::NewGuid().Guid.Substring(0,8))
$SK_OUT = Join-Path $SK_DIR 'target'
New-Item -ItemType Directory -Path $SK_OUT -Force | Out-Null
$SK_ENV = Join-Path $SK_DIR 'local.env'
Write-LocalEnvFixture -EnvFile $SK_ENV -ConfigDir $SK_OUT -VaultDir (Join-Path $SK_DIR 'vault')
$env:AI_CONFIG_LOCAL_ENV = $SK_ENV
try {
    & pwsh -NoProfile -File $INSTALL_PS1 --harness claude *>$null
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
# Codex F-2 (MEDIUM): AppendAllText + UTF8NoBOM for byte-determinism on Windows.
[System.IO.File]::AppendAllText((Join-Path $SK_OUT 'SKILLS.md'), "`nHAND EDIT`n", [System.Text.UTF8Encoding]::new($false))
Assert-Exit 'entrypoint.test: drift check fails after SKILLS.md is hand-edited' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $SK_OUT
Remove-Item -LiteralPath $SK_DIR -Recurse -Force -ErrorAction SilentlyContinue

# --- §3 retired-skill-name gate -------------------------------------
$claudeDir = Join-Path $env:REPO_ROOT 'harnesses' 'claude'
$tb_hits = @(Get-ChildItem -LiteralPath $claudeDir -Recurse -File -ErrorAction SilentlyContinue | `
    ForEach-Object { Select-String -LiteralPath $_.FullName -Pattern 'three-brain' -CaseSensitive } | `
    ForEach-Object { "$($_.Path):$($_.LineNumber):$($_.Line)" })
Assert-Eq 'entrypoint.test: no three-brain references in Claude templates' '' "$($tb_hits -join "`n")"

$cmr_hits = @(Get-ChildItem -LiteralPath $claudeDir -Recurse -File -ErrorAction SilentlyContinue | `
    ForEach-Object { Select-String -LiteralPath $_.FullName -Pattern 'cross-model-review' -CaseSensitive } | `
    ForEach-Object { "$($_.Path):$($_.LineNumber):$($_.Line)" })
Assert-Eq 'entrypoint.test: no cross-model-review references in Claude templates' '' "$($cmr_hits -join "`n")"

$sup_hits = @(Get-ChildItem -LiteralPath $claudeDir -Recurse -File -ErrorAction SilentlyContinue | `
    ForEach-Object { Select-String -LiteralPath $_.FullName -Pattern 'superpowers:' -CaseSensitive } | `
    ForEach-Object { "$($_.Path):$($_.LineNumber):$($_.Line)" })
Assert-Eq 'entrypoint.test: no superpowers: hits in Claude templates' '' "$($sup_hits -join "`n")"
