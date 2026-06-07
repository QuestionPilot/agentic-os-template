#Requires -Version 7
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

Remove-Item -LiteralPath $SO_DIR -Recurse -Force -ErrorAction SilentlyContinue
