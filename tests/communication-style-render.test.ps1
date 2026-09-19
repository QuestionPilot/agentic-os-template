#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }

# Windows-native twin of communication-style-render.test.sh. It exercises each
# PowerShell compiler target and the same missing-source failure contract.
$csrDir = Join-Path ([IO.Path]::GetTempPath()) ('communication-style-' + [Guid]::NewGuid().Guid)
New-Item -ItemType Directory -Path $csrDir -Force | Out-Null
$stylePath = Join-Path $env:REPO_ROOT 'core' 'communication-style.md'
$styleContent = [IO.File]::ReadAllText($stylePath).TrimEnd("`r", "`n")
$install = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

try {
    foreach ($harness in @('claude', 'codex', 'hermes', 'cursor')) {
        $target = Join-Path $csrDir $harness
        $envFile = Join-Path $csrDir ($harness + '.local.env')
        $key = switch ($harness) {
            'claude' { 'CLAUDE_CONFIG_DIR' }
            'codex' { 'CODEX_HOME' }
            'hermes' { 'HERMES_HOME' }
            'cursor' { 'CURSOR_CONFIG_DIR' }
        }
        [IO.File]::WriteAllText($envFile, "$key=$target`nOBSIDIAN_VAULT_PATH=$(Join-Path $csrDir 'vault')`n", $utf8NoBom)
        $env:AI_CONFIG_LOCAL_ENV = $envFile
        try {
            $buildOut = & pwsh -NoProfile -File $install --harness $harness --build-only 2>&1
            $status = $LASTEXITCODE
        } finally {
            Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
        }
        Assert-Eq "communication style: $harness isolated render exits 0" '0' "$status"
        if ($status -ne 0) { continue }
        $build = if ($buildOut -is [array]) { [string]$buildOut[-1] } else { [string]$buildOut }
        $entrypoint = switch ($harness) {
            'claude' { Join-Path $build 'CLAUDE.md' }
            'hermes' { Join-Path $build 'SOUL.md' }
            default { Join-Path $build 'AGENTS.md' }
        }
        Assert-File "communication style: $harness entrypoint exists" $entrypoint
        if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) { continue }
        $content = [IO.File]::ReadAllText($entrypoint).TrimEnd("`r", "`n")
        Assert-Contains "communication style: $harness entrypoint has canonical text" $content $styleContent
        Assert-Eq "communication style: $harness injects the title once" '1' "$(([regex]::Matches($content, [regex]::Escape('## Default communication style — plain and brief'))).Count)"
        $titleLine = [array]::IndexOf(($content -split "`n"), '## Default communication style — plain and brief') + 1
        if ($titleLine -gt 0 -and $titleLine -le 20) {
            _Pass "communication style: $harness places the rule near the top"
        } else {
            _Fail "communication style: $harness places the rule near the top" "title line: $titleLine"
        }
        Assert-NotContains "communication style: $harness leaves no include marker" $content '@@COMMUNICATION_STYLE@@'
        Remove-Item -LiteralPath $build -Recurse -Force -ErrorAction SilentlyContinue
    }

    $copy = Join-Path $csrDir 'missing-source-repo'
    Copy-RepoTracked $copy
    Remove-Item -LiteralPath (Join-Path $copy 'core' 'communication-style.md') -Force -ErrorAction SilentlyContinue
    $missingEnv = Join-Path $csrDir 'missing-source.local.env'
    [IO.File]::WriteAllText($missingEnv, "CLAUDE_CONFIG_DIR=$(Join-Path $csrDir 'missing-source-output')`nOBSIDIAN_VAULT_PATH=$(Join-Path $csrDir 'vault')`n", $utf8NoBom)
    $env:AI_CONFIG_LOCAL_ENV = $missingEnv
    try {
        $missingOut = & pwsh -NoProfile -File (Join-Path $copy 'scripts' 'install.ps1') --harness claude --build-only 2>&1
        $missingStatus = $LASTEXITCODE
    } finally {
        Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
    }
    if ($missingOut -is [array]) { $missingOut = $missingOut -join "`n" }
    Assert-Eq 'communication style: missing source fails closed' '1' "$missingStatus"
    Assert-Contains 'communication style: missing source names the cause' "$missingOut" 'communication style source not found'
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $csrDir -Recurse -Force -ErrorAction SilentlyContinue
}
