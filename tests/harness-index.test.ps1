#Requires -Version 7
# tests/harness-index.test.ps1 — Windows-native twin of tests/harness-index.test.sh.
#
# Per-harness generated index views (obsidian/vault-scaffolding/bin/
# generate-harness-index.js) + the vault secret scan extension in
# memory-vault-audit.js. Mirrors the bash twin 1:1: scope filter, default-all,
# determinism, drift enforcement, planted-secret trip.
#
# Runs against a TMP COPY of the scaffolding — never mutates the live repo
# tree. tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in
# scope.

$HI_SCAFFOLD = Join-Path $env:REPO_ROOT 'obsidian' 'vault-scaffolding'
$HI_GEN_REL = Join-Path 'bin' 'generate-harness-index.js'
$HI_AUDIT_REL = Join-Path 'bin' 'memory-vault-audit.js'

$hiNode = Get-Command node -ErrorAction SilentlyContinue
if (-not $hiNode) {
    _Skip 'harness-index.test: suite' 'node not installed'
}
elseif (-not (Test-Path -LiteralPath (Join-Path $HI_SCAFFOLD $HI_GEN_REL))) {
    _Fail 'harness-index.test: generator present' "missing: $HI_SCAFFOLD/$HI_GEN_REL"
}
else {
    $HI_TMP_PARENT = Join-Path ([System.IO.Path]::GetTempPath()) ("hi-" + [guid]::NewGuid().ToString('N'))
    $HI_TMP = Join-Path $HI_TMP_PARENT 'vault'
    New-Item -ItemType Directory -Path $HI_TMP_PARENT -Force | Out-Null
    Copy-Item -LiteralPath $HI_SCAFFOLD -Destination $HI_TMP -Recurse

    $hiGen = Join-Path $HI_TMP $HI_GEN_REL
    $hiAudit = Join-Path $HI_TMP $HI_AUDIT_REL
    $hiViews = Join-Path $HI_TMP '90-Indexes'

    # --- T1: shipped scaffolding views match regeneration ---
    Assert-Exit 'harness-index.test: shipped scaffolding passes generator --check' 0 -- `
        node $hiGen --check

    # --- T2: scope filter — a harness-scoped note appears ONLY in its own view ---
    Set-Content -LiteralPath (Join-Path $HI_TMP '10-Wiki' '__scoped-fixture__.md') -Value @'
---
title: scoped fixture
harness: claude
learned_by: claude
---

Claude-only guidance.
'@
    node $hiGen *> $null

    $hiClaudeView = Get-Content -LiteralPath (Join-Path $hiViews 'Harness Index - claude.md') -Raw
    $hiCodexView = Get-Content -LiteralPath (Join-Path $hiViews 'Harness Index - codex.md') -Raw
    $hiHermesView = Get-Content -LiteralPath (Join-Path $hiViews 'Harness Index - hermes.md') -Raw
    Assert-Contains 'harness-index.test: claude view lists the claude-scoped note' `
        $hiClaudeView '__scoped-fixture__'
    Assert-NotContains 'harness-index.test: codex view does NOT list the claude-scoped note' `
        $hiCodexView '__scoped-fixture__'
    Assert-NotContains 'harness-index.test: hermes view does NOT list the claude-scoped note' `
        $hiHermesView '__scoped-fixture__'

    # Unscoped note (no harness: key) defaults to all — visible everywhere.
    Set-Content -LiteralPath (Join-Path $HI_TMP '10-Wiki' '__unscoped-fixture__.md') -Value @'
---
title: unscoped fixture
---

Shared guidance.
'@
    node $hiGen *> $null
    $hiCodexView = Get-Content -LiteralPath (Join-Path $hiViews 'Harness Index - codex.md') -Raw
    Assert-Contains 'harness-index.test: missing harness: key defaults to all (codex view lists it)' `
        $hiCodexView '__unscoped-fixture__'

    # --- T3: determinism — regenerate twice, byte-identical ---
    $hiSum1 = (Get-ChildItem -LiteralPath $hiViews -Filter 'Harness Index - *.md' |
        Sort-Object Name | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    node $hiGen *> $null
    $hiSum2 = (Get-ChildItem -LiteralPath $hiViews -Filter 'Harness Index - *.md' |
        Sort-Object Name | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    Assert-Eq 'harness-index.test: regeneration is deterministic (byte-identical twice)' $hiSum1 $hiSum2

    # --- T4: drift enforcement — a hand-edited view fails --check ---
    Add-Content -LiteralPath (Join-Path $hiViews 'Harness Index - hermes.md') -Value 'HAND EDIT'
    Assert-Exit 'harness-index.test: hand-edited view fails generator --check' 1 -- `
        node $hiGen --check
    node $hiGen *> $null   # heal for T5

    # --- T5: vault secret scan — planted credential shape trips the audit.
    # Sentinel assembled from non-matching halves so this test source never
    # self-trips a tree-wide scan (feedback_self_tripping_test_source).
    $hiKeyName = 'ANTHROPIC_API' + '_KEY'
    $hiKeyVal = 'sk-' + 'ant-test0123456789abcdefghij'
    Set-Content -LiteralPath (Join-Path $HI_TMP '10-Wiki' '__planted-secret__.md') -Value @"
---
title: planted secret fixture
---

$hiKeyName=$hiKeyVal
"@
    $hiAuditOut = (& node $hiAudit 2>&1) -join "`n"
    Assert-Contains 'harness-index.test: planted secret in a vault note trips the audit scan' `
        $hiAuditOut 'likely secret pattern in 10-Wiki/__planted-secret__.md'

    Remove-Item -LiteralPath $HI_TMP_PARENT -Recurse -Force -ErrorAction SilentlyContinue
}
