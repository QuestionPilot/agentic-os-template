#Requires -Version 7
# tests/editorial.test.ps1 — Windows-native twin of tests/editorial.test.sh.
#
# Asserts editorial deliverables: CI workflow no longer installs lineark;
# Linear/Obsidian REQUIRED-language is
# softened in root entrypoints; core/operating-system.md is QUE-NN-free for
# standalone-read.
#
# Mirrors tests/editorial.test.sh 1:1. Pure content-only.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$WORKFLOW    = Join-Path $env:REPO_ROOT '.github' 'workflows' 'install-render-stable.yml'
$ROOT_CLAUDE = Join-Path $env:REPO_ROOT 'CLAUDE.md'
$ROOT_AGENTS = Join-Path $env:REPO_ROOT 'AGENTS.md'
$OS_DOC      = Join-Path $env:REPO_ROOT 'core' 'operating-system.md'

Assert-File 'editorial.test: install-render-stable.yml exists' $WORKFLOW
Assert-File 'editorial.test: root CLAUDE.md exists' $ROOT_CLAUDE
Assert-File 'editorial.test: root AGENTS.md exists' $ROOT_AGENTS
Assert-File 'editorial.test: core/operating-system.md exists' $OS_DOC

# ---- A. CI workflow: lineark install step removed ---------------------------
$workflow_body = Get-Content -LiteralPath $WORKFLOW -Raw

Assert-NotContains 'editorial.test: workflow no longer has ''Install lineark CLI'' step' `
    $workflow_body 'Install lineark CLI'
Assert-NotContains 'editorial.test: workflow no longer pipes upstream lineark installer' `
    $workflow_body 'flipbit03/lineark/main/install.sh'

# 'lineark --version' at a leading-space-bullet position. The bash twin used
# `grep -E '^[[:space:]]+lineark --version'`. PS `-cmatch` with `(?m)` for
# multiline anchoring.
$leadingLinearkVersion = $workflow_body -cmatch '(?m)^[ \t]+lineark --version'
Assert-Eq 'editorial.test: workflow no longer invokes lineark --version' `
    'False' "$leadingLinearkVersion"

# ---- C. Linear/Obsidian REQUIRED-language softened in root entrypoints ------
$claude_body = Get-Content -LiteralPath $ROOT_CLAUDE -Raw
$agents_body = Get-Content -LiteralPath $ROOT_AGENTS -Raw

Assert-NotContains 'editorial.test: root CLAUDE.md drops ''install or connect before relying'' hard-require prose' `
    $claude_body 'install or connect before relying on framework workflows'
Assert-NotContains 'editorial.test: root AGENTS.md drops ''install or connect before relying'' hard-require prose' `
    $agents_body 'install or connect before relying on framework workflows'

Assert-NotContains 'editorial.test: root CLAUDE.md drops ''## Required Dependencies'' heading' `
    $claude_body '## Required Dependencies'
Assert-NotContains 'editorial.test: root AGENTS.md drops ''## Required Dependencies'' heading' `
    $agents_body '## Required Dependencies'
Assert-NotContains 'editorial.test: root CLAUDE.md drops ''This framework assumes the machine has'' framing' `
    $claude_body 'This framework assumes the machine has'
Assert-NotContains 'editorial.test: root AGENTS.md drops ''This framework assumes the machine has'' framing' `
    $agents_body 'This framework assumes the machine has'

Assert-Contains 'editorial.test: root CLAUDE.md uses ''canonical example'' framing for tracker/vault' `
    $claude_body 'canonical example'
Assert-Contains 'editorial.test: root AGENTS.md uses ''canonical example'' framing for tracker/vault' `
    $agents_body 'canonical example'
Assert-Contains 'editorial.test: root CLAUDE.md accepts tracker equivalents (names alternatives)' `
    $claude_body 'accepts equivalents'
Assert-Contains 'editorial.test: root AGENTS.md accepts tracker equivalents (names alternatives)' `
    $agents_body 'accepts equivalents'

Assert-Contains 'editorial.test: root CLAUDE.md asserts spine capabilities degrade gracefully without tracker' `
    $claude_body 'degrade gracefully'
Assert-Contains 'editorial.test: root AGENTS.md asserts spine capabilities degrade gracefully without tracker' `
    $agents_body 'degrade gracefully'

# ---- D. Standalone-read invariant — six named files free of QUE-NN refs ----
$README_DOC = Join-Path $env:REPO_ROOT 'README.md'
$CLOSEOUT_DOC = Join-Path $env:REPO_ROOT 'core' 'closeout.md'
$BOOTSTRAP_DOC = Join-Path $env:REPO_ROOT 'playbooks' 'new-machine-bootstrap.md'

Assert-File 'editorial.test: README.md exists' $README_DOC
Assert-File 'editorial.test: core/closeout.md exists' $CLOSEOUT_DOC
Assert-File 'editorial.test: playbooks/new-machine-bootstrap.md exists' $BOOTSTRAP_DOC

foreach ($doc in @($README_DOC, $ROOT_CLAUDE, $ROOT_AGENTS, $OS_DOC, $CLOSEOUT_DOC, $BOOTSTRAP_DOC)) {
    $rel = $doc.Substring($env:REPO_ROOT.Length).TrimStart('/', '\').Replace('\', '/')
    $content = Get-Content -LiteralPath $doc -Raw
    # Build the QUE-NN literal at runtime so this test source doesn't itself
    # self-trip downstream scanners; the bash twin uses grep which doesn't
    # self-trip but PS `-cmatch` would scan the literal in this file's
    # bytes too if it appeared (it doesn't here, but be safe). Construct
    # from non-matching halves: 'QU' + 'E-' is split.
    $quePrefix = 'QU' + 'E-'
    $hasQueNn = $content -cmatch ($quePrefix + '\d+')
    Assert-Eq "editorial.test: ${rel}: no QUE-NN attribution (standalone-read invariant)" `
        'False' "$hasQueNn"
}

# ---- E. Workflow + Makefile audit -------------------------------------------
$MAKEFILE = Join-Path $env:REPO_ROOT 'Makefile'
Assert-File 'editorial.test: Makefile exists' $MAKEFILE

$make_body = Get-Content -LiteralPath $MAKEFILE -Raw
$quePrefix = 'QU' + 'E-'
$makeHasQueNn = $make_body -cmatch ($quePrefix + '\d+')
Assert-Eq 'editorial.test: Makefile has no QUE-NN identifiers' 'False' "$makeHasQueNn"

# Loop over every workflow file via git ls-files.
$workflows_dir = Join-Path $env:REPO_ROOT '.github' 'workflows'
if (Test-Path -LiteralPath $workflows_dir -PathType Container) {
    Push-Location $env:REPO_ROOT
    try {
        $ymls = & git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml' 2>$null
        foreach ($yml in $ymls) {
            if (-not $yml) { continue }
            $full = Join-Path $env:REPO_ROOT $yml
            $rel = $yml -replace '\\', '/'
            $content = Get-Content -LiteralPath $full -Raw
            $hasQueNn = $content -cmatch ($quePrefix + '\d+')
            Assert-Eq "editorial.test: ${rel}: no QUE-NN identifiers in workflow comments" `
                'False' "$hasQueNn"
        }
    } finally {
        Pop-Location
    }
}
