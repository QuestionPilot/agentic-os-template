#Requires -Version 7
# tests/harness-index.test.ps1 — Windows-native twin of tests/harness-index.test.sh.
#
# Per-harness generated index views (obsidian/vault-scaffolding/bin/
# generate-harness-index.js) + the published scaffold audit
# (memory-vault-audit.js) behavior checks. Mirrors the bash twin 1:1: scope
# filter, default-all, determinism, drift enforcement, planted-secret trip,
# plus the backported audit behaviors — .DS_Store WARN (not FAIL), orphan WARN
# (not FAIL), and machine-path FAIL.
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

    # --- T6-T8: scaffold-audit behaviors backported from the live vault tool.
    # Run on a SECOND, pristine copy: the T1-T5 copy still holds the planted
    # secret (a persistent FAIL), which would mask the exit-0 assertions below.
    $HI_TMP2_PARENT = Join-Path ([System.IO.Path]::GetTempPath()) ("hi2-" + [guid]::NewGuid().ToString('N'))
    $HI_TMP2 = Join-Path $HI_TMP2_PARENT 'vault'
    New-Item -ItemType Directory -Path $HI_TMP2_PARENT -Force | Out-Null
    Copy-Item -LiteralPath $HI_SCAFFOLD -Destination $HI_TMP2 -Recurse
    $hiGen2 = Join-Path $HI_TMP2 $HI_GEN_REL
    $hiAudit2 = Join-Path $HI_TMP2 $HI_AUDIT_REL

    # T6: a stray .DS_Store is OS noise (macOS/Finder/Drive regenerate it), so the
    # audit must WARN and stay exit-0 — never FAIL — or a Drive-synced scaffold
    # copy audits nondeterministically.
    $hiDsStore = Join-Path $HI_TMP2 '.DS_Store'
    New-Item -ItemType File -Path $hiDsStore -Force | Out-Null
    $hiDsOut = (& node $hiAudit2 2>&1) -join "`n"
    $hiDsRc = $LASTEXITCODE
    Assert-Eq 'harness-index.test: stray .DS_Store does not FAIL the scaffold audit' 0 $hiDsRc
    Assert-Contains 'harness-index.test: stray .DS_Store surfaces as a WARN' `
        $hiDsOut 'WARN OS noise'
    Remove-Item -LiteralPath $hiDsStore -Force -ErrorAction SilentlyContinue

    # T7: a note with zero inbound wikilinks is an orphan — WARN-only, never FAIL.
    # Regenerate the index around the plant so this isolates ORPHAN behavior from
    # the index-drift FAIL a new note would otherwise cause.
    $hiOrphan = Join-Path $HI_TMP2 '10-Wiki' '__orphan-fixture__.md'
    Set-Content -LiteralPath $hiOrphan -Value "# orphan fixture`n`nNo note links here.`n"
    node $hiGen2 *> $null
    $hiOrphOut = (& node $hiAudit2 2>&1) -join "`n"
    $hiOrphRc = $LASTEXITCODE
    Assert-Eq 'harness-index.test: an unlinked note does not FAIL the audit (orphans are WARN)' 0 $hiOrphRc
    Assert-Contains 'harness-index.test: an unlinked note surfaces as an orphan WARN' `
        $hiOrphOut 'orphan page — no inbound wikilinks (link it from a hub or index): 10-Wiki/__orphan-fixture__.md'
    Remove-Item -LiteralPath $hiOrphan -Force -ErrorAction SilentlyContinue
    node $hiGen2 *> $null

    # T8: a machine-specific absolute path in a note must FAIL (keep the vault
    # agnostic). The sentinel path is assembled from halves so THIS test source
    # never trips the repo-wide machine-path scan (feedback_self_tripping_test_source).
    # Regenerate the index AFTER the plant so the ONLY possible FAIL is the machine
    # path — that makes the non-zero exit attributable to checkAgnostic, not to
    # incidental index drift. Assert both the exit code AND the `FAIL ` prefix so a
    # silent fail()->warn() downgrade (same message, WARN not FAIL) is caught.
    $hiMp = '/Users' + '/sentinel-user/x'
    $hiMpNote = Join-Path $HI_TMP2 '10-Wiki' '__machinepath-fixture__.md'
    Set-Content -LiteralPath $hiMpNote -Value "---`ntitle: machinepath fixture`n---`n`nSee $hiMp here.`n"
    node $hiGen2 *> $null
    $hiMpOut = (& node $hiAudit2 2>&1) -join "`n"
    $hiMpRc = $LASTEXITCODE
    Assert-Eq 'harness-index.test: a machine-specific absolute path FAILs the audit (non-zero exit)' 1 $hiMpRc
    Assert-Contains 'harness-index.test: a machine-specific absolute path surfaces as a FAIL line (not WARN)' `
        $hiMpOut 'FAIL machine-specific absolute path (keep vault agnostic): 10-Wiki/__machinepath-fixture__.md'
    Remove-Item -LiteralPath $hiMpNote -Force -ErrorAction SilentlyContinue

    Remove-Item -LiteralPath $HI_TMP2_PARENT -Recurse -Force -ErrorAction SilentlyContinue
}
