#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/skills-overlay.test.ps1 — Windows-native twin of
# tests/skills-overlay.test.sh: exercises the operator-skills-overlay splice in
# install.ps1's Compile-Entrypoint across the same scenarios (happy path, Codex
# F2 set-but-missing, Codex F3 marker re-introduction, @@VAR@@-in-overlay). Each
# runner globs only its own extension, so per-file assertions live in BOTH twins.
# Marker built from halves so this source isn't a stray second literal copy.

$SO_DIR     = Join-Path ([System.IO.Path]::GetTempPath()) ("so-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SO_DIR -Force | Out-Null
$SO_TGT     = Join-Path $SO_DIR 'cfg'
$SO_FIXTURE = Join-Path $env:REPO_ROOT 'tests' 'fixtures' 'ci.local.env'
$SO_INSTALL = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$SO_MARK    = '@@OPERATOR_SKILLS' + '_OVERLAY@@'
$SO_ERR     = Join-Path $SO_DIR 'stderr.txt'

# Invoke-SoBuild <overlay-path-or-empty> → [pscustomobject]@{ Status; BuildDir }.
# stderr of the install run is captured to $SO_ERR.
function Invoke-SoBuild {
    param([string]$OverlayPath)
    $envFile = Join-Path $SO_DIR 'local.env'
    $lines = @(Get-Content -LiteralPath $SO_FIXTURE)
    # QUOTE the path values: Import-LocalEnv collapses `\<x>` → `<x>` in UNQUOTED
    # values (to mirror bash `%q` space-escaping), which would shred a Windows
    # backslash path. Quoted values pass through verbatim — same convention the
    # render-stable PS test uses for its CLAUDE_CONFIG_DIR override.
    $lines += "CLAUDE_CONFIG_DIR=`"$SO_TGT`""
    if ($OverlayPath) { $lines += "SKILLS_OVERLAY_PATH=`"$OverlayPath`"" }
    Set-Content -LiteralPath $envFile -Value $lines -Encoding utf8
    $env:AI_CONFIG_LOCAL_ENV = $envFile
    try {
        $out = & pwsh -NoProfile -File $SO_INSTALL --harness claude --build-only 2>$SO_ERR
        $status = $LASTEXITCODE
    } finally {
        Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
    }
    # --build-only prints the build dir as the last stdout line.
    $bd = @($out | Where-Object { $_ -ne '' }) | Select-Object -Last 1
    [pscustomobject]@{ Status = $status; BuildDir = $bd }
}

function Get-SoMarkerCount {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return 0 }
    return ([regex]::Matches([System.IO.File]::ReadAllText($File), [regex]::Escape($SO_MARK))).Count
}

# 1. Happy path — overlay present.
$SO_OV1 = Join-Path $SO_DIR 'overlay-ok.md'
Set-Content -LiteralPath $SO_OV1 -Value "### Operator routing`n`nSENTINEL_OVERLAY_ROW here" -Encoding utf8
$r = Invoke-SoBuild $SO_OV1
Assert-Eq 'overlay: present render exits 0' '0' "$($r.Status)"
$skills = Join-Path $r.BuildDir 'SKILLS.md'
if (Test-Path -LiteralPath $skills -PathType Leaf) {
    $txt = [System.IO.File]::ReadAllText($skills)
    Assert-Contains 'overlay: spliced content appears in rendered SKILLS.md' $txt 'SENTINEL_OVERLAY_ROW'
    Assert-Eq 'overlay: marker consumed in present render (0 left)' '0' "$(Get-SoMarkerCount $skills)"
} else {
    _Fail 'overlay: present build produced a SKILLS.md' @("no SKILLS.md under [$($r.BuildDir)]")
}
if ($r.BuildDir) { Remove-Item -LiteralPath $r.BuildDir -Recurse -Force -ErrorAction SilentlyContinue }

# 2. Codex F2 — SET-but-missing path: warn + exit 0 + spine-only.
$r = Invoke-SoBuild (Join-Path $SO_DIR 'nope-not-here.md')
Assert-Eq 'overlay: set-but-missing render still exits 0 (spine-only fallback)' '0' "$($r.Status)"
$errTxt = if (Test-Path -LiteralPath $SO_ERR) { Get-Content -Raw -LiteralPath $SO_ERR } else { '' }
Assert-Contains 'overlay: set-but-missing warns on stderr' $errTxt 'is set but the file does not exist'
$skills = Join-Path $r.BuildDir 'SKILLS.md'
if (Test-Path -LiteralPath $skills -PathType Leaf) {
    Assert-Eq 'overlay: set-but-missing leaves no marker in output' '0' "$(Get-SoMarkerCount $skills)"
}
if ($r.BuildDir) { Remove-Item -LiteralPath $r.BuildDir -Recurse -Force -ErrorAction SilentlyContinue }

# 3. Codex F3 — overlay re-introduces the marker: neutralized, no die.
$SO_OV3 = Join-Path $SO_DIR 'overlay-marker.md'
Set-Content -LiteralPath $SO_OV3 -Value "note: operators splice this at the $SO_MARK marker." -Encoding utf8
$r = Invoke-SoBuild $SO_OV3
Assert-Eq 'overlay: marker-in-overlay render exits 0 (no resolves-empty die)' '0' "$($r.Status)"
$skills = Join-Path $r.BuildDir 'SKILLS.md'
if (Test-Path -LiteralPath $skills -PathType Leaf) {
    Assert-Eq 'overlay: marker-in-overlay neutralized (0 markers left)' '0' "$(Get-SoMarkerCount $skills)"
}
if ($r.BuildDir) { Remove-Item -LiteralPath $r.BuildDir -Recurse -Force -ErrorAction SilentlyContinue }

# 4. @@VAR@@ inside the overlay resolves (splice precedes the @@VAR@@ loop).
$SO_OV4 = Join-Path $SO_DIR 'overlay-token.md'
Set-Content -LiteralPath $SO_OV4 -Value 'see @@AI_CONFIG_DIR@@/skills/skill-authoring.md' -Encoding utf8
$r = Invoke-SoBuild $SO_OV4
Assert-Eq 'overlay: path-token-in-overlay render exits 0' '0' "$($r.Status)"
$skills = Join-Path $r.BuildDir 'SKILLS.md'
if (Test-Path -LiteralPath $skills -PathType Leaf) {
    $n = ([regex]::Matches([System.IO.File]::ReadAllText($skills), [regex]::Escape('@@AI_CONFIG_DIR@@'))).Count
    Assert-Eq 'overlay: @@AI_CONFIG_DIR@@ inside overlay resolved (0 literal left)' '0' "$n"
}
if ($r.BuildDir) { Remove-Item -LiteralPath $r.BuildDir -Recurse -Force -ErrorAction SilentlyContinue }

# 5. Cross-overlay collision (the SEVERE leak case): a claude render with the skills
# overlay carrying the codex-rules marker AND CODEX_RULES_OVERLAY_PATH set must NOT
# splice codex rules into this claude SKILLS.md (before the cross-overlay fix the
# surviving marker made the codex-rules branch fire on post-splice content and leak).
# Marker from halves (not a stray copy). Bespoke env (Invoke-SoBuild sets only SKILLS).
$SO_CXMARK = '@@OPERATOR_CODEX_RULES' + '_OVERLAY@@'
$SO_OV5 = Join-Path $SO_DIR 'overlay-codex-marker.md'
Set-Content -LiteralPath $SO_OV5 -Value "operator note mentioning the $SO_CXMARK marker." -Encoding utf8
$SO_CXPAY = Join-Path $SO_DIR 'codex-payload.md'
Set-Content -LiteralPath $SO_CXPAY -Value 'CODEX_LEAK_SENTINEL must never reach a claude SKILLS.md' -Encoding utf8
$SO_ENV5 = Join-Path $SO_DIR 'local.env'
$lines5 = @(Get-Content -LiteralPath $SO_FIXTURE)
$lines5 += "CLAUDE_CONFIG_DIR=`"$SO_TGT`""
$lines5 += "SKILLS_OVERLAY_PATH=`"$SO_OV5`""
$lines5 += "CODEX_RULES_OVERLAY_PATH=`"$SO_CXPAY`""
Set-Content -LiteralPath $SO_ENV5 -Value $lines5 -Encoding utf8
$env:AI_CONFIG_LOCAL_ENV = $SO_ENV5
try {
    $out5 = & pwsh -NoProfile -File $SO_INSTALL --harness claude --build-only 2>$null
    $st5 = $LASTEXITCODE
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
Assert-Eq 'overlay: claude render with cross-overlay marker + codex path set exits 0' '0' "$st5"
$bd5 = @($out5 | Where-Object { $_ -ne '' }) | Select-Object -Last 1
$skills = Join-Path $bd5 'SKILLS.md'
if (Test-Path -LiteralPath $skills -PathType Leaf) {
    $txt5 = [System.IO.File]::ReadAllText($skills)
    Assert-NotContains 'overlay: codex rules do NOT leak into claude SKILLS.md (cross-overlay)' $txt5 'CODEX_LEAK_SENTINEL'
    $n5 = ([regex]::Matches($txt5, [regex]::Escape($SO_CXMARK))).Count
    Assert-Eq 'overlay: cross-overlay codex-rules marker neutralized (0 left in SKILLS.md)' '0' "$n5"
}
if ($bd5) { Remove-Item -LiteralPath $bd5 -Recurse -Force -ErrorAction SilentlyContinue }

# 6. Catalog-honesty warn: a skill dir living in the live target but absent from
# the rendered SKILLS.md draws an advisory stderr warn on a FULL install — the
# install still exits 0 (warn-not-fail contract) and the warn names both the
# offending dir and the overlay fix.
$CH_DIR = Join-Path ([System.IO.Path]::GetTempPath()) ("ch-" + [guid]::NewGuid().ToString('N'))
$CH_TGT = Join-Path $CH_DIR 'cfg'
New-Item -ItemType Directory -Path (Join-Path $CH_TGT 'skills' 'mystery-operator-skill') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $CH_TGT 'skills' 'mystery-operator-skill' 'SKILL.md') -Value '# operator skill' -Encoding utf8
New-Item -ItemType Directory -Path (Join-Path $CH_TGT 'skills' 'zz aa') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $CH_TGT 'skills' 'zz aa' 'SKILL.md') -Value '# spaced-name skill' -Encoding utf8
$CH_ERR = Join-Path $CH_DIR 'stderr.txt'
$chEnv = Join-Path $CH_DIR 'local.env'
$chLines = @(Get-Content -LiteralPath $SO_FIXTURE)
$chLines += "CLAUDE_CONFIG_DIR=`"$CH_TGT`""
$chLines += "OBSIDIAN_VAULT_PATH=`"$(Join-Path $CH_DIR 'vault')`""
Set-Content -LiteralPath $chEnv -Value $chLines -Encoding utf8
$env:AI_CONFIG_LOCAL_ENV = $chEnv
try {
    & pwsh -NoProfile -File $SO_INSTALL --harness claude 1>$null 2>$CH_ERR
    $chStatus = $LASTEXITCODE
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
Assert-Eq 'catalog-warn: install with an uncataloged skill dir still exits 0' '0' "$chStatus"
$chErrTxt = if (Test-Path -LiteralPath $CH_ERR) { Get-Content -Raw -LiteralPath $CH_ERR } else { '' }
Assert-Contains 'catalog-warn: warn names the uncataloged skill dir' $chErrTxt 'mystery-operator-skill'
# A skill dir named with a space reports as ONE skill (array elements, no
# splitting) — mirrors the bash regression guard; "zz aa" halves would not
# sort adjacent if split.
Assert-Contains 'catalog-warn: spaced skill-dir name reports as one skill' $chErrTxt 'zz aa'
Assert-Contains 'catalog-warn: warn names the overlay fix' $chErrTxt 'SKILLS_OVERLAY_PATH'
# Spine skills are cataloged by the generated table — they must NOT be flagged.
$chWarnLine = @($chErrTxt -split "`n" | Where-Object { $_ -match 'absent from the rendered SKILLS\.md catalog' }) -join "`n"
Assert-NotContains 'catalog-warn: cataloged spine skill draws no warn' $chWarnLine 'session-agent'
Remove-Item -LiteralPath $CH_DIR -Recurse -Force -ErrorAction SilentlyContinue

# 7. Catalog-honesty warn suppressed when the overlay lists the skill: the same
# uncataloged dir plus an overlay row naming it backticked renders warn-free.
$CQ_DIR = Join-Path ([System.IO.Path]::GetTempPath()) ("cq-" + [guid]::NewGuid().ToString('N'))
$CQ_TGT = Join-Path $CQ_DIR 'cfg'
New-Item -ItemType Directory -Path (Join-Path $CQ_TGT 'skills' 'mystery-operator-skill') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $CQ_TGT 'skills' 'mystery-operator-skill' 'SKILL.md') -Value '# operator skill' -Encoding utf8
$CQ_OV = Join-Path $CQ_DIR 'overlay.md'
Set-Content -LiteralPath $CQ_OV -Value "### Operator skills`n`n| ``mystery-operator-skill`` | test row |" -Encoding utf8
$CQ_ERR = Join-Path $CQ_DIR 'stderr.txt'
$cqEnv = Join-Path $CQ_DIR 'local.env'
$cqLines = @(Get-Content -LiteralPath $SO_FIXTURE)
$cqLines += "CLAUDE_CONFIG_DIR=`"$CQ_TGT`""
$cqLines += "OBSIDIAN_VAULT_PATH=`"$(Join-Path $CQ_DIR 'vault')`""
$cqLines += "SKILLS_OVERLAY_PATH=`"$CQ_OV`""
Set-Content -LiteralPath $cqEnv -Value $cqLines -Encoding utf8
$env:AI_CONFIG_LOCAL_ENV = $cqEnv
try {
    & pwsh -NoProfile -File $SO_INSTALL --harness claude 1>$null 2>$CQ_ERR
    $cqStatus = $LASTEXITCODE
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
Assert-Eq 'catalog-warn: overlay-listed skill install exits 0' '0' "$cqStatus"
$cqErrTxt = if (Test-Path -LiteralPath $CQ_ERR) { Get-Content -Raw -LiteralPath $CQ_ERR } else { '' }
Assert-NotContains 'catalog-warn: overlay-listed skill draws no warn' $cqErrTxt 'absent from the rendered SKILLS.md catalog'
Remove-Item -LiteralPath $CQ_DIR -Recurse -Force -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $SO_DIR -Recurse -Force -ErrorAction SilentlyContinue
