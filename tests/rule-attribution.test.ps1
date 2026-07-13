#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/rule-attribution.test.ps1 — Windows-native twin of
# tests/rule-attribution.test.sh.
#
# enforce the prose-rationale + out-of-line-vault-lineage attribution
# convention that REPLACED the inline (KEY-NN) suffix convention. Asserts the
# governed rule sections carry NO inline tracker-ID token and NO legacy
# `(founding)` / `(harness-mechanic)` suffix, the two entrypoint Ground Rules
# preambles state the new convention (prose rationale AND the `linear:`
# frontmatter lineage home), and the vault handshake is documented in
# core/memory-model.md. Mirrors tests/rule-attribution.test.sh 1:1.
#
# NON-GOAL: validates public-file cleanliness of the governed rule sections; it
# does NOT verify a vault note exists for each rule (a migration-audit concern).
#
# Per [[reference_ps_port_traps]]: case-sensitive matching via -cmatch (the bash
# twin uses /usr/bin/grep -E, case-sensitive);.NET regex treats `\(` as a
# literal paren (matching grep -E, unlike the awk dynamic-regex quirk in the
# OLD bash test). Self-trip guard ([[feedback_self_tripping_test_source]]): the
# forbidden tracker-ID class is assembled at runtime from a non-matching key +
# separator, so this file carries no literal issue-shaped token in its fixtures.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

# --- the forbidden attribution forms --------------------------------------
$TRACKER_KEY     = 'QUE'
$TRACKER_ID_RE   = "$TRACKER_KEY-[0-9]+"
$LEGACY_TOKEN_RE = '\((founding|harness-mechanic)\)'
$FORBIDDEN_RE    = "$TRACKER_ID_RE|$LEGACY_TOKEN_RE"

# Get-SectionRuleContent — emit a governed rule section's body: every line from
# the section header to the next `## ` header. The WHOLE section is in scope,
# including any managed sub-blocks (e.g. the operator-rules overlay marker in the
# Codex Ground Rules) — the new convention forbids private tracker IDs anywhere in
# a shipped framework rule section, so nothing is comment-exempt.
function Get-SectionRuleContent {
    param([string]$Path, [string]$Section)
    $lines = Get-Content -LiteralPath $Path
    $inSec = $false
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -cmatch '^## ') { $inSec = ($line -ceq $Section); continue }
        if ($inSec) { [void]$out.Add($line) }
    }
    return ($out -join "`n")
}

# Test-SectionClean — PASS iff the section's rule content carries no forbidden
# attribution token. A renamed/mistyped/deleted section yields an empty body;
# that is a FAILURE (coverage must not silently drop), not a vacuous pass.
function Test-SectionClean {
    param([string]$Path, [string]$Section, [string]$Label)
    $body = Get-SectionRuleContent $Path $Section
    if (-not $body) {
        _Fail $Label 'governed rule section not found or empty (renamed / mistyped header?)'
        return
    }
    $hits = @($body -split "`n" | Where-Object { $_ -cmatch $FORBIDDEN_RE })
    if ($hits.Count -eq 0) {
        _Pass "$Label (prose rationale — no inline tracker-ID / legacy token)"
    } else {
        _Fail $Label (@('governed rule section still carries forbidden attribution token(s):') + $hits)
    }
}

# === Governed rule sections — must carry NO inline attribution token =========
$CLAUDE_TPL = Join-Path $env:REPO_ROOT 'harnesses' 'claude' 'CLAUDE.template.md'
$AGENTS_TPL = Join-Path $env:REPO_ROOT 'harnesses' 'codex' 'AGENTS.template.md'

Test-SectionClean $CLAUDE_TPL '## Ground Rules' `
    'rule-attribution.test: claude template Ground Rules'
Test-SectionClean $AGENTS_TPL '## Ground Rules' `
    'rule-attribution.test: codex template Ground Rules'
Test-SectionClean (Join-Path $env:REPO_ROOT 'core' 'memory-model.md') '## Per-Harness Memory Index' `
    'rule-attribution.test: memory-model Per-Harness Memory Index'
Test-SectionClean (Join-Path $env:REPO_ROOT 'core' 'memory-model.md') '## Failure Modes' `
    'rule-attribution.test: memory-model Failure Modes'
Test-SectionClean (Join-Path $env:REPO_ROOT 'core' 'self-improvement.md') '## Inputs — State Deltas' `
    'rule-attribution.test: self-improvement Inputs — State Deltas'
Test-SectionClean (Join-Path $env:REPO_ROOT 'core' 'operating-system.md') '## Working Rules' `
    'rule-attribution.test: operating-system Working Rules'
Test-SectionClean (Join-Path $env:REPO_ROOT 'core' 'tool-use.md') '## Guardrails' `
    'rule-attribution.test: tool-use Guardrails'
Test-SectionClean (Join-Path $env:REPO_ROOT 'core' 'routing.md') '## Avoid' `
    'rule-attribution.test: routing Avoid'
Test-SectionClean (Join-Path $env:REPO_ROOT 'core' 'routing.md') '## Escalate When' `
    'rule-attribution.test: routing Escalate When'

# === Positive: the new convention is stated in both Ground Rules preambles ===
$CLAUDE_GR = Get-SectionRuleContent $CLAUDE_TPL '## Ground Rules'
Assert-Contains 'rule-attribution.test: claude Ground Rules states the prose-rationale convention' `
    $CLAUDE_GR 'prose'
Assert-Contains 'rule-attribution.test: claude Ground Rules names the linear: frontmatter lineage home' `
    $CLAUDE_GR 'linear:'
$AGENTS_GR = Get-SectionRuleContent $AGENTS_TPL '## Ground Rules'
Assert-Contains 'rule-attribution.test: codex Ground Rules states the prose-rationale convention' `
    $AGENTS_GR 'prose'
Assert-Contains 'rule-attribution.test: codex Ground Rules names the linear: frontmatter lineage home' `
    $AGENTS_GR 'linear:'

# === the vault linear:-frontmatter handshake is documented ==========
$MEM_MODEL = Get-Content -LiteralPath (Join-Path $env:REPO_ROOT 'core' 'memory-model.md') -Raw
Assert-Contains 'rule-attribution.test: memory-model documents the linear: frontmatter handshake' `
    $MEM_MODEL 'linear:'
Assert-Contains 'rule-attribution.test: memory-model frames the handshake via frontmatter' `
    $MEM_MODEL 'frontmatter'

# === Unrelated invariants that share this file (NOT attribution) =============
# These came bundled with the original attribution test; they guard
# SKILLS.template.md substitution safety, not rule attribution. Kept here to
# avoid churn — a future maintainer cleaning up attribution logic MUST NOT
# delete them.
$SKILLS_TPL_PATH = Join-Path $env:REPO_ROOT 'harnesses' 'claude' 'SKILLS.template.md'
$SKILLS_HEAD = (Get-Content -LiteralPath $SKILLS_TPL_PATH -TotalCount 20) -join "`n"
Assert-Contains 'rule-attribution.test: SKILLS.template.md names capabilities/ as canonical source' `
    $SKILLS_HEAD 'capabilities/'
Assert-Contains 'rule-attribution.test: SKILLS.template.md names harnesses/claude/capabilities/ as Claude-specific canonical source' `
    $SKILLS_HEAD 'harnesses/claude/capabilities/'
Assert-Contains 'rule-attribution.test: SKILLS.template.md names install.sh as regenerator' `
    $SKILLS_HEAD 'install.sh'
Assert-Contains 'rule-attribution.test: SKILLS.template.md has do-not-edit-directly clause' `
    $SKILLS_HEAD 'Do not edit directly'

$SKILLS_TPL_TEXT = Get-Content -LiteralPath $SKILLS_TPL_PATH -Raw
$catalog_token_count = ([regex]::Matches($SKILLS_TPL_TEXT, '@@CAPABILITY_CATALOG@@')).Count
Assert-Eq 'rule-attribution.test: SKILLS.template.md has exactly one @@CAPABILITY_CATALOG@@ occurrence (no stray-prose copies)' `
    '1' "$catalog_token_count"
$AGENTS_TPL_TEXT = Get-Content -LiteralPath $AGENTS_TPL -Raw
$agents_catalog_count = ([regex]::Matches($AGENTS_TPL_TEXT, '@@CAPABILITY_CATALOG@@')).Count
Assert-Eq 'rule-attribution.test: AGENTS.template.md has exactly one @@CAPABILITY_CATALOG@@ occurrence' `
    '1' "$agents_catalog_count"

# === Unit tests for the forbidden-token detector ============================
# Assembled at runtime from halves so the test source carries no literal
# issue-shaped token (self-trip guard). Cover the bypass forms the design
# review flagged: bare, bracketed, and prose-embedded tracker IDs.
function Test-ForbiddenMatch {
    param([string]$Line)
    if ($Line -cmatch $FORBIDDEN_RE) { return '0' } else { return '1' }
}
$qid = "$TRACKER_KEY-185"          # runtime-built real-shaped tracker id

# Positive: every inline form of the tracker-ID class must be caught.
Assert-Eq 'rule-attribution.test: detector catches parenthesized (KEY-NN)' '0' (Test-ForbiddenMatch "- foo ($qid)")
Assert-Eq 'rule-attribution.test: detector catches bare KEY-NN (no parens)' '0' (Test-ForbiddenMatch "- foo $qid")
Assert-Eq 'rule-attribution.test: detector catches bracketed [KEY-NN]' '0' (Test-ForbiddenMatch "- foo [$qid]")
Assert-Eq 'rule-attribution.test: detector catches prose-embedded tracker id' '0' (Test-ForbiddenMatch "see Linear $qid for context")
Assert-Eq 'rule-attribution.test: detector catches legacy (founding)' '0' (Test-ForbiddenMatch '- foo (founding)')
Assert-Eq 'rule-attribution.test: detector catches legacy (harness-mechanic)' '0' (Test-ForbiddenMatch '- foo (harness-mechanic)')

# Negative controls: benign text must NOT match.
# Lowercase variant of the runtime-built key — the detector matches UPPERCASE
# tracker IDs, so the lowercase form must be ignored. Built by lowercasing
# TRACKER_KEY so this source still carries no literal issue-shaped token.
$lqid = $TRACKER_KEY.ToLower() + '-185'
Assert-Eq 'rule-attribution.test: detector ignores lowercase key' '1' (Test-ForbiddenMatch "- foo ($lqid)")
Assert-Eq 'rule-attribution.test: detector ignores the word ''founding'' in prose (no parens)' '1' (Test-ForbiddenMatch 'these are the founding rules')
Assert-Eq 'rule-attribution.test: detector ignores an ordinary hyphenated word' '1' (Test-ForbiddenMatch '- a well-formed bullet')
Assert-Eq 'rule-attribution.test: detector ignores a different team-key shape' '1' (Test-ForbiddenMatch '- foo (ABC-1)')

# === Fixture tests for section scanning =====================================
# Build a fixture with a tracker id sitting AFTER an HTML comment inside a
# section (qid runtime-built per the self-trip guard). The whole section is in
# scope — no comment-exempt region — so the scan must still see the id.
$fixDir = Join-Path ([IO.Path]::GetTempPath()) ('rule-attr-fix-' + [Guid]::NewGuid().Guid.Substring(0,8))
New-Item -ItemType Directory -Path $fixDir -Force | Out-Null
$fix = Join-Path $fixDir 'fixture.md'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$fixText = "# Fixture`n`n## Demo Section`n`n- a clean bullet`n<!-- a managed sub-block -->`n- another bullet ($qid)`n`n## Next Section`n"
[System.IO.File]::WriteAllText($fix, $fixText, $utf8NoBom)
$demoBody = Get-SectionRuleContent $fix '## Demo Section'
$demoHit = if ($demoBody -cmatch $FORBIDDEN_RE) { '0' } else { '1' }
Assert-Eq 'rule-attribution.test: section scan covers content AFTER an HTML comment (no comment-exempt)' '0' $demoHit
# A renamed / mistyped section header yields an empty body — the coverage-drop
# guard in Test-SectionClean turns that into a FAIL, not a vacuous pass.
Assert-Eq 'rule-attribution.test: section scan returns empty for an absent section header' '' (Get-SectionRuleContent $fix '## Nonexistent Section')
Remove-Item -LiteralPath $fixDir -Recurse -Force -ErrorAction SilentlyContinue
