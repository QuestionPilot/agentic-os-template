#Requires -Version 7
# tests/vault-guide.test.ps1 — Windows-native twin of tests/vault-guide.test.sh.
#
# acceptance: obsidian/vault-guide.md + start-template.md +
# handshake-template.md + stub-collapse on README + vault-structure +
# inbound references from ai-config/README.md +
# playbooks/new-machine-bootstrap.md + templates/local.env.example.
#
# Mirrors tests/vault-guide.test.sh 1:1. Pure content-only; no script
# invocation.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$VG_PATH = Join-Path $env:REPO_ROOT 'obsidian' 'vault-guide.md'
$ST_PATH = Join-Path $env:REPO_ROOT 'obsidian' 'start-template.md'
$HT_PATH = Join-Path $env:REPO_ROOT 'obsidian' 'handshake-template.md'

# --- T1: canonical doc + templates exist ---
Assert-File 'vault-guide.test: obsidian/vault-guide.md exists' $VG_PATH
Assert-File 'vault-guide.test: obsidian/start-template.md exists' $ST_PATH
Assert-File 'vault-guide.test: obsidian/handshake-template.md exists' $HT_PATH

# --- T2: vault-guide.md has all 9 expected H2 sections ---
$vg_body = if (Test-Path -LiteralPath $VG_PATH) { Get-Content -LiteralPath $VG_PATH -Raw } else { '' }
foreach ($header in @(
    '## 1. Purpose and Audience',
    '## 2. Role in the Agentic OS',
    '## 3. First-Time Setup',
    '## 4. Folder Structure',
    '## 5. `00-System/` Notes',
    '## 6. `50-Outputs/` Convention',
    '## 7. Templates',
    '## 8. How the AI Uses the Vault at Runtime',
    '## 9. Failure Modes')) {
    Assert-Contains "vault-guide.test: vault-guide.md contains section: $header" $vg_body $header
}

# --- T3: vault-guide §2 + §8 carry summary-canonical-source labels ---
Assert-Contains 'vault-guide.test: vault-guide §2 labels canonical source with Markdown link to core/memory-model.md' `
    $vg_body 'Summary — canonical source is [`core/memory-model.md`](../core/memory-model.md)'
Assert-Contains 'vault-guide.test: vault-guide §8 labels canonical source with Markdown link to capabilities/session-agent.md' `
    $vg_body '[`capabilities/session-agent.md`](../capabilities/session-agent.md)'
Assert-Contains 'vault-guide.test: vault-guide §8 labels canonical source with Markdown link to capabilities/closeout.md' `
    $vg_body '[`capabilities/closeout.md`](../capabilities/closeout.md)'

# --- T4: start-template.md minimum-contract sections ---
$st_body = if (Test-Path -LiteralPath $ST_PATH) { Get-Content -LiteralPath $ST_PATH -Raw } else { '' }
foreach ($header in @(
    '## Read Order',
    '## Working Rule',
    '## Linear Boundary',
    '## Closeout',
    '## Health Check')) {
    Assert-Contains "vault-guide.test: start-template.md contains minimum-contract section: $header" $st_body $header
}

# --- T5: handshake-template.md YAML frontmatter contract ---
$ht_body = if (Test-Path -LiteralPath $HT_PATH) { Get-Content -LiteralPath $HT_PATH -Raw } else { '' }
foreach ($token in @('title:', 'tags:', 'linear-handshake', 'linear:', 'status:')) {
    Assert-Contains "vault-guide.test: handshake-template.md frontmatter contains: $token" $ht_body $token
}

# --- T6: README.md + vault-structure.md collapsed to <=10 line stubs ---
$readme_path = Join-Path $env:REPO_ROOT 'obsidian' 'README.md'
$vs_path = Join-Path $env:REPO_ROOT 'obsidian' 'vault-structure.md'

$readme_lines = if (Test-Path -LiteralPath $readme_path) { @(Get-Content -LiteralPath $readme_path).Count } else { 0 }
$vs_lines = if (Test-Path -LiteralPath $vs_path) { @(Get-Content -LiteralPath $vs_path).Count } else { 0 }

if ($readme_lines -le 10) {
    _Pass "vault-guide.test: obsidian/README.md is a stub (<=10 lines; actual=$readme_lines)"
} else {
    _Fail 'vault-guide.test: obsidian/README.md exceeds stub ceiling' "expected <=10 lines, got $readme_lines"
}
if ($vs_lines -le 10) {
    _Pass "vault-guide.test: obsidian/vault-structure.md is a stub (<=10 lines; actual=$vs_lines)"
} else {
    _Fail 'vault-guide.test: obsidian/vault-structure.md exceeds stub ceiling' "expected <=10 lines, got $vs_lines"
}

# --- T7: stubs reference vault-guide ---
$readme_body = if (Test-Path -LiteralPath $readme_path) { Get-Content -LiteralPath $readme_path -Raw } else { '' }
$vs_body = if (Test-Path -LiteralPath $vs_path) { Get-Content -LiteralPath $vs_path -Raw } else { '' }
Assert-Contains 'vault-guide.test: obsidian/README.md references vault-guide' $readme_body 'vault-guide.md'
Assert-Contains 'vault-guide.test: obsidian/vault-structure.md references vault-guide' $vs_body 'vault-guide.md'

# --- T8: inbound references from the fresh-clone path ---
$root_readme_path = Join-Path $env:REPO_ROOT 'README.md'
$playbook_path = Join-Path $env:REPO_ROOT 'playbooks' 'new-machine-bootstrap.md'
$env_path = Join-Path $env:REPO_ROOT 'templates' 'local.env.example'
$root_readme = if (Test-Path -LiteralPath $root_readme_path) { Get-Content -LiteralPath $root_readme_path -Raw } else { '' }
$playbook_body = if (Test-Path -LiteralPath $playbook_path) { Get-Content -LiteralPath $playbook_path -Raw } else { '' }
$env_body = if (Test-Path -LiteralPath $env_path) { Get-Content -LiteralPath $env_path -Raw } else { '' }

Assert-Contains 'vault-guide.test: ai-config/README.md Layout table references vault-guide.md' $root_readme 'obsidian/vault-guide.md'
Assert-Contains 'vault-guide.test: playbooks/new-machine-bootstrap.md references vault-guide.md' $playbook_body 'vault-guide.md'
Assert-Contains 'vault-guide.test: templates/local.env.example references vault-guide.md' $env_body 'vault-guide.md'

# --- T9: harness-leak guard — no `.claude/skills/` (or `.codex/` / `.agents/`) ---
$obs_dir = Join-Path $env:REPO_ROOT 'obsidian'
$harness_leak = $false
foreach ($f in Get-ChildItem -LiteralPath $obs_dir -Filter '*.md' -File) {
    $content = Get-Content -LiteralPath $f.FullName -Raw
    if ($content -match '\.claude/|\.codex/|\.agents/') {
        _Fail "vault-guide.test: obsidian/$($f.Name) leaks harness-config path" `
            'found one of: .claude/  .codex/  .agents/'
        $harness_leak = $true
    }
}
if (-not $harness_leak) {
    _Pass 'vault-guide.test: no harness-config-path leak in any obsidian/*.md'
}

# --- T10: operator-specific-name guard — runtime-construct sentinels.
$sentinel_personal = 'Hen' + 'do'
$sentinel_retired = 'Question' + 'Pilot'
$name_leak = $false
foreach ($f in Get-ChildItem -LiteralPath $obs_dir -Filter '*.md' -File) {
    $content = Get-Content -LiteralPath $f.FullName -Raw
    $lc = $content.ToLower()
    if ($lc.Contains($sentinel_personal.ToLower()) -or $lc.Contains($sentinel_retired.ToLower())) {
        _Fail "vault-guide.test: obsidian/$($f.Name) leaks operator-specific identifier" `
            'found one of the runtime-constructed sentinels'
        $name_leak = $true
    }
}
if (-not $name_leak) {
    _Pass 'vault-guide.test: no operator-specific-name leak in any obsidian/*.md'
}
