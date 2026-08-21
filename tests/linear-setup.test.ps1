#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/linear-setup.test.ps1 — Windows-native twin of tests/linear-setup.test.sh.
#
# acceptance: linear/linear-setup.md + stub-collapse on
# linear/README.md + inbound references from agentic-os-template/README.md +
# templates/local.env.example.
#
# Mirrors tests/linear-setup.test.sh 1:1. Pure content-only; no script
# invocation.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$LS_PATH = Join-Path $env:REPO_ROOT 'linear' 'linear-setup.md'
$LR_PATH = Join-Path $env:REPO_ROOT 'linear' 'README.md'

# --- T1: canonical doc + stub exist ---
Assert-File 'linear-setup.test: linear/linear-setup.md exists' $LS_PATH
Assert-File 'linear-setup.test: linear/README.md exists' $LR_PATH

# --- T2: linear-setup.md has all 7 expected H2 sections ---
$ls_body = if (Test-Path -LiteralPath $LS_PATH) { Get-Content -LiteralPath $LS_PATH -Raw } else { '' }
foreach ($header in @(
    '## 1. Purpose and Audience',
    '## 2. Role in the Agentic OS',
    '## 3. First-Time Setup',
    '## 4. Operating Instructions',
    '## 5. How the AI Uses Linear at Runtime',
    '## 6. Templates',
    '## 7. Failure Modes')) {
    Assert-Contains "linear-setup.test: linear-setup.md contains section: $header" $ls_body $header
}

# --- T3: linear-setup §2 + §5 carry summary-canonical-source labels ---
Assert-Contains 'linear-setup.test: linear-setup §2 labels canonical source with Markdown link to core/memory-model.md' `
    $ls_body 'Summary — canonical source is [`core/memory-model.md`](../core/memory-model.md)'
Assert-Contains 'linear-setup.test: linear-setup §5 labels canonical source with Markdown link to capabilities/session-agent.md' `
    $ls_body '[`capabilities/session-agent.md`](../capabilities/session-agent.md)'
Assert-Contains 'linear-setup.test: linear-setup §5 labels canonical source with Markdown link to capabilities/closeout.md' `
    $ls_body '[`capabilities/closeout.md`](../capabilities/closeout.md)'

# --- T4: §3 First-time setup documents BOTH surface options ---
Assert-Contains 'linear-setup.test: linear-setup §3 names Option A: linear CLI' $ls_body 'Option A'
Assert-Contains 'linear-setup.test: linear-setup §3 names Option B: Linear MCP' $ls_body 'Option B'
Assert-Contains 'linear-setup.test: linear-setup §3 cites linear CLI repo URL' $ls_body 'github.com/schpet/linear-cli'
Assert-Contains 'linear-setup.test: linear-setup §3 cites openai/plugins/linear for Codex MCP' $ls_body 'github.com/openai/plugins/tree/main/plugins/linear'
Assert-Contains 'linear-setup.test: linear-setup §3 documents headless auth env var' $ls_body 'LINEAR_API_KEY'

# --- T4.5: §3.5 documents uninstall/migration with teardown for stale stubs ---
Assert-Contains 'linear-setup.test: linear-setup §3.5 names uninstall/migration sub-section' $ls_body '### 3.5 Uninstalling or migrating between surfaces'
Assert-Contains 'linear-setup.test: linear-setup §3.5 documents deprecated lineark binary removal' $ls_body 'rm -f ~/.local/bin/lineark'
Assert-Contains 'linear-setup.test: linear-setup §3.5 documents API token removal' $ls_body 'rm -f ~/.linear_api_token'
Assert-Contains 'linear-setup.test: linear-setup §3.5 documents npm uninstall step' $ls_body 'npm uninstall -g <package-name>'
Assert-Contains 'linear-setup.test: linear-setup §3.5 documents per-machine config stub sweep' $ls_body 'rm -rf ~/.<tool-name>'
Assert-Contains 'linear-setup.test: linear-setup §3.5 documents cache leftover sweep' $ls_body 'rm -rf ~/.cache/<tool-name>'
Assert-Contains 'linear-setup.test: linear-setup §3.5 documents XDG config variant sweep' $ls_body 'rm -rf ~/.config/<tool-name>'
Assert-Contains 'linear-setup.test: linear-setup §3.5 documents XDG data variant sweep' $ls_body 'rm -rf ~/.local/share/<tool-name>'
Assert-Contains 'linear-setup.test: linear-setup §3.5 documents CLI-presence verify (command -v)' $ls_body 'command -v linear'
Assert-Contains 'linear-setup.test: linear-setup §3.5 documents CLI-version verify' $ls_body 'linear --version'

# --- T5: §6 Templates references the 3 existing linear/ template files ---
Assert-Contains 'linear-setup.test: linear-setup §6 references linear/issue-template.md' $ls_body 'issue-template.md'
Assert-Contains 'linear-setup.test: linear-setup §6 references linear/closeout-format.md' $ls_body 'closeout-format.md'
Assert-Contains 'linear-setup.test: linear-setup §6 references linear/tool-agnostic-linear.md' $ls_body 'tool-agnostic-linear.md'

# --- T6: linear/README.md collapsed to <=10 line stub ---
$readme_lines = if (Test-Path -LiteralPath $LR_PATH) {
    @(Get-Content -LiteralPath $LR_PATH).Count
} else { 0 }
if ($readme_lines -le 10) {
    _Pass "linear-setup.test: linear/README.md is a stub (<=10 lines; actual=$readme_lines)"
} else {
    _Fail 'linear-setup.test: linear/README.md exceeds stub ceiling' "expected <=10 lines, got $readme_lines"
}

# --- T7: stub references linear-setup.md ---
$readme_body = if (Test-Path -LiteralPath $LR_PATH) { Get-Content -LiteralPath $LR_PATH -Raw } else { '' }
Assert-Contains 'linear-setup.test: linear/README.md references linear-setup.md' $readme_body 'linear-setup.md'

# --- T8: inbound references from the fresh-clone path ---
$root_readme_path = Join-Path $env:REPO_ROOT 'README.md'
$env_path = Join-Path $env:REPO_ROOT 'templates' 'local.env.example'
$root_readme = if (Test-Path -LiteralPath $root_readme_path) { Get-Content -LiteralPath $root_readme_path -Raw } else { '' }
$env_body = if (Test-Path -LiteralPath $env_path) { Get-Content -LiteralPath $env_path -Raw } else { '' }

Assert-Contains 'linear-setup.test: agentic-os-template/README.md Layout table references linear/linear-setup.md' $root_readme 'linear/linear-setup.md'
Assert-Contains 'linear-setup.test: templates/local.env.example references linear/linear-setup.md' $env_body 'linear/linear-setup.md'

# --- T10: harness-leak guard — no.claude/skills/ etc. in shared content ---
$harness_leak = $false
foreach ($f in @(
    (Join-Path $env:REPO_ROOT 'linear' 'linear-setup.md'),
    (Join-Path $env:REPO_ROOT 'linear' 'README.md'))) {
    if (Test-Path -LiteralPath $f) {
        $content = Get-Content -LiteralPath $f -Raw
        if ($content -match '\.claude/|\.codex/|\.agents/') {
            $name = Split-Path -Leaf $f
            $parent = Split-Path -Leaf (Split-Path -Parent $f)
            _Fail "linear-setup.test: $parent/$name leaks harness-config path" `
                'found one of: .claude/  .codex/  .agents/'
            $harness_leak = $true
        }
    }
}
if (-not $harness_leak) {
    _Pass 'linear-setup.test: no harness-config-path leak in linear-setup.md / linear/README.md'
}

# --- T11: operator-specific-name guard — runtime-construct sentinels.
$sentinel_personal = 'Hen' + 'do'
$sentinel_retired  = 'Question' + 'Pilot'
$sentinel_slug     = 'question' + '-' + 'pilot'

$name_leak = $false
foreach ($f in @(
    (Join-Path $env:REPO_ROOT 'linear' 'linear-setup.md'),
    (Join-Path $env:REPO_ROOT 'linear' 'README.md'))) {
    if (Test-Path -LiteralPath $f) {
        # Case-insensitive scan for the runtime-constructed sentinels.
        $hits = Get-Content -LiteralPath $f | ForEach-Object {
            $line = $_
            $lcLine = $line.ToLower()
            if ($lcLine.Contains($sentinel_personal.ToLower()) -or
                $lcLine.Contains($sentinel_retired.ToLower()) -or
                $lcLine.Contains($sentinel_slug.ToLower())) {
                $line
            }
        }
        if ($hits) {
            $name = Split-Path -Leaf $f
            $parent = Split-Path -Leaf (Split-Path -Parent $f)
            _Fail "linear-setup.test: $parent/$name leaks operator-specific identifier" `
                'found one of the runtime-constructed sentinels'
            $name_leak = $true
        }
    }
}
if (-not $name_leak) {
    _Pass 'linear-setup.test: no operator-specific-name leak in linear-setup.md / linear/README.md'
}

# --- T12: Codex harness entrypoint retains the two-Linear-surfaces framing ---
# Re-homed from the deleted cli-transition test. Linear is a permanent
# framework contract; the Codex entrypoint must keep the framing post-purge.
$codex_tmpl_path = Join-Path $env:REPO_ROOT 'harnesses' 'codex' 'AGENTS.template.md'
$codex_tmpl = if (Test-Path -LiteralPath $codex_tmpl_path) { Get-Content -LiteralPath $codex_tmpl_path -Raw } else { '' }
Assert-Contains 'linear-setup.test: harnesses/codex/AGENTS.template.md retains ''two Linear access surfaces'' framing' `
    $codex_tmpl 'two Linear access surfaces'
