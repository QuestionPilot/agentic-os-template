#!/usr/bin/env pwsh
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# Focused acceptance tests for the read-only Codex trust-row detector.

$CT_SCRIPT = Join-Path $env:REPO_ROOT 'scripts' 'check-codex-trust.ps1'
$CT_TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-trust-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $CT_TMP -Force | Out-Null

try {
    $ctConfig = Join-Path $CT_TMP 'config.toml'
    $configText = @'
title = "ordinary config # not a project row"

[projects."/workspace/quoted # path"]
trust_level = "trusted" # a comment after the value
description = "trust_level = \"untrusted\" is text"
metadata = { trust_level = "trusted" }

[projects."/workspace/dotted.path"]
trust_level = "untrusted"

[projects."/workspace/escaped\npath"]
trust_level = "trusted"

[other]
trust_level = "trusted"
'@
    [System.IO.File]::WriteAllText($ctConfig, $configText, [System.Text.UTF8Encoding]::new($false))

    $ctOut = (& $CT_SCRIPT --config $ctConfig 2>&1) -join "`n"
    $ctRc = $LASTEXITCODE
    Assert-Eq 'codex trust: valid TOML reports two trusted rows' '0' "$ctRc"
    Assert-Contains 'codex trust: reports the trusted-row denominator' $ctOut 'trusted project rows: 2'
    Assert-Contains 'codex trust: reports quoted project path' $ctOut 'path: "/workspace/quoted # path"'
    Assert-Contains 'codex trust: JSON-escapes a control character in a project path' $ctOut 'path: "/workspace/escaped\npath"'
    Assert-NotContains 'codex trust: does not report untrusted project path' $ctOut '/workspace/dotted.path'
    Assert-NotContains 'codex trust: does not leak a sibling config value' $ctOut 'description ='

    $ctHome = Join-Path $CT_TMP 'codex-home'
    New-Item -ItemType Directory -Path $ctHome -Force | Out-Null
    [System.IO.File]::Copy($ctConfig, (Join-Path $ctHome 'config.toml'))
    $oldCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $ctHome
        $ctOut = (& $CT_SCRIPT 2>&1) -join "`n"
        $ctRc = $LASTEXITCODE
        Assert-Eq 'codex trust: CODEX_HOME default config reports trusted rows' '0' "$ctRc"
        Assert-Contains 'codex trust: CODEX_HOME default config reports its inventory' $ctOut 'trusted project rows: 2'
    }
    finally {
        if ($null -eq $oldCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
        else { $env:CODEX_HOME = $oldCodexHome }
    }

    [System.IO.File]::WriteAllText($ctConfig, "[projects]`n", [System.Text.UTF8Encoding]::new($false))
    $ctOut = (& $CT_SCRIPT --config $ctConfig 2>&1) -join "`n"
    $ctRc = $LASTEXITCODE
    Assert-Eq 'codex trust: valid empty projects table reports zero' '0' "$ctRc"
    Assert-Contains 'codex trust: zero is explicit' $ctOut 'trusted project rows: 0'

    [System.IO.File]::WriteAllText($ctConfig, "[projects.`"/broken`"`ntrust_level = `"trusted`"`n", [System.Text.UTF8Encoding]::new($false))
    $ctOut = (& $CT_SCRIPT --config $ctConfig 2>&1) -join "`n"
    $ctRc = $LASTEXITCODE
    Assert-Eq 'codex trust: malformed TOML fails instead of reporting zero' '2' "$ctRc"
    Assert-Contains 'codex trust: malformed TOML explains the failure' $ctOut 'config.toml is malformed'

    if ($PSVersionTable.PSVersion -ge [version]'7.3') {
        $oldForceScript = $env:CODEX_TRUST_FORCE_SCRIPT
        $oldForceConfig = $env:CODEX_TRUST_FORCE_CONFIG
        try {
            $env:CODEX_TRUST_FORCE_SCRIPT = $CT_SCRIPT
            $env:CODEX_TRUST_FORCE_CONFIG = $ctConfig
            $forceCommand = '$PSNativeCommandUseErrorActionPreference = $true; & $env:CODEX_TRUST_FORCE_SCRIPT --config $env:CODEX_TRUST_FORCE_CONFIG; exit $LASTEXITCODE'
            $ctOut = (& pwsh -NoProfile -Command $forceCommand 2>&1 | Out-String)
            $ctRc = $LASTEXITCODE
            Assert-Eq 'codex trust: forced native-error preference preserves malformed-config exit 2' '2' "$ctRc"
            Assert-Contains 'codex trust: forced native-error preference keeps malformed-config receipt' $ctOut 'config.toml is malformed'
        }
        finally {
            if ($null -eq $oldForceScript) { Remove-Item Env:CODEX_TRUST_FORCE_SCRIPT -ErrorAction SilentlyContinue }
            else { $env:CODEX_TRUST_FORCE_SCRIPT = $oldForceScript }
            if ($null -eq $oldForceConfig) { Remove-Item Env:CODEX_TRUST_FORCE_CONFIG -ErrorAction SilentlyContinue }
            else { $env:CODEX_TRUST_FORCE_CONFIG = $oldForceConfig }
        }
    }
    else {
        _Skip 'codex trust: forced native-error preference preserves malformed-config exit 2' 'PowerShell version lacks PSNativeCommandUseErrorActionPreference'
        _Skip 'codex trust: forced native-error preference keeps malformed-config receipt' 'PowerShell version lacks PSNativeCommandUseErrorActionPreference'
    }

    [System.IO.File]::WriteAllText($ctConfig, "[projects]`n`"/not-a-table`" = `"trusted`"`n", [System.Text.UTF8Encoding]::new($false))
    Assert-Exit 'codex trust: unsupported project schema fails instead of reporting zero' 2 -- `
        $CT_SCRIPT --config $ctConfig

    [System.IO.File]::WriteAllText($ctConfig, "[projects.`"/wrong-type`"]`ntrust_level = 1`n", [System.Text.UTF8Encoding]::new($false))
    Assert-Exit 'codex trust: non-string trust level fails instead of reporting zero' 2 -- `
        $CT_SCRIPT --config $ctConfig

    [System.IO.File]::WriteAllText($ctConfig, "[projects.`"/unknown-level`"]`ntrust_level = `"later`"`n", [System.Text.UTF8Encoding]::new($false))
    Assert-Exit 'codex trust: unknown trust level fails instead of reporting zero' 2 -- `
        $CT_SCRIPT --config $ctConfig

    Assert-Exit 'codex trust: unavailable explicit config fails' 2 -- `
        $CT_SCRIPT --config (Join-Path $CT_TMP 'missing.toml')

    $oldCodexHome = $env:CODEX_HOME
    Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    Assert-Exit 'codex trust: unset CODEX_HOME fails' 2 -- $CT_SCRIPT
    if ($null -ne $oldCodexHome) { $env:CODEX_HOME = $oldCodexHome }
}
finally {
    Remove-Item -LiteralPath $CT_TMP -Recurse -Force -ErrorAction SilentlyContinue
}
