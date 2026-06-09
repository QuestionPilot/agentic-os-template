#Requires -Version 7
# tests/spine-only.test.ps1 — Windows-native twin of tests/spine-only.test.sh.
#
# Guards the spine-only invariant: ai-config (and the public template) ship ONLY
# the OS spine (session-agent, closeout, self-audit) + their machinery + the
# linear/ and obsidian/ contracts. Zero operator tool opinions. See the.sh twin's
# header for the full rationale, the F1 ctx7 audit, the F4 line-
# scoped allowlist (scripts/validate.* + build-public-snapshot.* + linear/ +
# obsidian/ are now SCANNED, not file-excluded), and the deferred codex-ctx7-block
# .codegraph carve-outs.
#
# Enumeration is via git (ls-files / grep), never filesystem globs. The forbidden-
# identifier pattern is built from halves so this file never trips its own audit
# (tests/ is excluded from the audit regardless).

$soRoot = $env:REPO_ROOT
if (-not $soRoot) { throw 'REPO_ROOT not set' }

# --- structural: the tool-layer files must not be tracked ------------------
foreach ($rel in @(
    'catalog.md',
    'skills/capability-families.md',
    'harnesses/claude/connectors.md',
    'harnesses/codex/connectors.md'
)) {
    $n = @(& git -C $soRoot ls-files -- $rel).Count
    Assert-Eq "spine-only: $rel is not shipped" '0' "$n"
}

# skills/recommended/ — the entire recommended tool-skill dir must be gone
$n = @(& git -C $soRoot ls-files -- 'skills/recommended/*').Count
Assert-Eq 'spine-only: skills/recommended/ is not shipped' '0' "$n"

# --- structural: capabilities/ ships exactly the 3 spine capabilities ------
# Ordinal sort (byte order) to match the bash side's `LC_ALL=C sort` — PowerShell's
# default Sort-Object is case-insensitive culture order (would put closeout before
# README), which diverges from bash byte order.
$capNames = [string[]]@(& git -C $soRoot ls-files -- 'capabilities/*.md' |
    ForEach-Object { $_ -replace '^capabilities/', '' })
[System.Array]::Sort($capNames, [System.StringComparer]::Ordinal)
$caps = ($capNames -join ',') + ','
Assert-Eq 'spine-only: capabilities/ = README + 3 spine capabilities only' `
    'README.md,closeout.md,self-audit.md,session-agent.md,' $caps

# --- structural: shipped settings.base.json enables zero plugins ----------
$raw = (Get-Content -Raw -LiteralPath (Join-Path $soRoot 'harnesses/claude/settings.base.json')) -replace '[ \t\r\n]', ''
$m = [regex]::Match($raw, '"enabledPlugins":\{[^}]*\}')
$plugins = if ($m.Success) { $m.Value } else { '' }
Assert-Eq 'spine-only: settings.base.json enables zero plugins' '"enabledPlugins":{}' $plugins

# --- structural: shipped settings.base.json ships no cost/behavior preference ---
# theme + effortLevel are operator-local (carried across re-renders by install.ps1
# preserve-live); the shared base must not ship them downstream — effortLevel in
# particular is a cost setting.
$prefsMatch = [regex]::Match($raw, '"(theme|effortLevel)"')
$prefs = if ($prefsMatch.Success) { $prefsMatch.Value } else { '' }
Assert-Eq 'spine-only: settings.base.json ships no theme/effortLevel preference' '' $prefs

# --- audit: forbidden tool identifiers appear ONLY in allowlisted DATA lines ---
# Twin of the.sh audit. ctx7/context7 join the forbidden set;
# only docs/ + tests/ stay file-excluded. The allowlist is per-OCCURRENCE (Codex
# F1): lowercase each hit, strip ONLY the name-as-data token legitimate FOR ITS
# FILE, then rescan the residual — so a real opinion sharing an allowed line still
# trips. -replace / -match are case-insensitive by default; the lowercased line +
# lowercase pattern keep parity with the bash `tr | sed | grep`. Built from halves.
$soPat = 'play' + 'wright|sup' + 'abase|net' + 'lify|str' + 'ipe|fire' + 'crawl|web-design-' + 'guidelines|frontend-' + 'design|con' + 'text7|ct' + 'x7'
$soStr = 'str' + 'ipe'; $soSup = 'sup' + 'abase'; $soC7 = 'con' + 'text7'; $soCx = 'ct' + 'x7'
function Test-SpineResidual {
    # Strip the per-file allowed token(s) from a (lowercased) git-grep hit line.
    # validate.ps1 names Stripe; memory-vault-audit.js names Stripe AND Supabase
    # (its secret-scan key prefixes); the codex AGENTS block names ctx7/context7.
    param([string]$Line)
    $lc = $Line.ToLowerInvariant()
    if ($lc -match '^scripts/validate\.ps1:') {
        $lc = $lc -replace $soStr, ''
    } elseif ($lc -match '^obsidian/vault-scaffolding/bin/memory-vault-audit\.js:') {
        $lc = ($lc -replace $soStr, '') -replace $soSup, ''
    } elseif ($lc -match '^harnesses/codex/agents\.template\.md:') {
        $lc = ($lc -replace $soC7, '') -replace $soCx, ''
    }
    return ($lc -match $soPat)
}
$soRaw = @(& git -C $soRoot grep -niIE $soPat -- ':!tests/' ':!docs/' 2>$null)
$hits = (@($soRaw | Where-Object { Test-SpineResidual $_ }) -join "`n")
Assert-Eq 'spine-only: no operator tool identifiers outside the allowlisted DATA lines' '' $hits

# F1 regression (self-trip): a real opinion sharing an allowed line still trips.
# Parenthesize each element — in PowerShell the `,` array separator binds tighter
# than `+`, so unparenthesized `'a'+'b', 'c'+'d'` collapses into ONE element.
$soEvil = @(
    ('harnesses/codex/agents.template.md:120:use ct' + 'x7 and install play' + 'wright'),
    ('scripts/validate.ps1:210:stripe scanner; also wire fire' + 'crawl')
)
$soEvilN = @($soEvil | Where-Object { Test-SpineResidual $_ }).Count
Assert-Eq 'spine-only: allowlist is per-occurrence (a real opinion sharing an allowed line still trips)' '2' "$soEvilN"

# --- structural: the SHIPPED claude SKILLS template is spine-only ---
# Twin of the.sh assertion — see it for the rationale and the overlay model. The
# marker string + the forbidden pattern are built from halves so this guard file
# never self-matches (and tests/ is excluded from the audit regardless).
$soTmpl = Join-Path $soRoot 'harnesses/claude/SKILLS.template.md'

$soMarker = '@@OPERATOR_SKILLS' + '_OVERLAY@@'
$soMarkerN = @(Select-String -LiteralPath $soTmpl -SimpleMatch -Pattern $soMarker).Count
Assert-Eq 'spine-only: SKILLS.template.md carries the operator-overlay marker once' '1' "$soMarkerN"

# Operator plugin namespaces (rendered as `<ns>:<skill>`), family section headers,
# the two local CLIs, and ctx7/context7 must not appear. Select-String
# is case-insensitive by default (matches the bash `grep -niE`).
$soFam = 'anthropic-' + 'skills:|productivity:|design:|engineering:|product-' + 'management:|marketing:|data:|finance:|operations:|legal:|sales:|human-' + 'resources:|customer-' + 'support:|small-' + 'business:|zoom-' + 'plugin:|enterprise-' + 'search:|pdf-' + 'viewer:|zapier:|claude-md-' + 'management:|code' + 'burn|design' + 'lang|con' + 'text7|ct' + 'x7'
$soTmplHits = (Select-String -LiteralPath $soTmpl -Pattern $soFam | ForEach-Object { $_.Line }) -join "`n"
Assert-Eq 'spine-only: SKILLS.template.md carries no operator plugin/family/CLI names' '' $soTmplHits

# Positive heading allowlist (Codex F4) — twin of the.sh assertion. The $soFam
# denylist only catches known namespaces; this asserts every H2/H3 heading matches
# a spine section keyword, so an operator family heading with no `<ns>:` form (e.g.
# "### Figma Plugin Skills") still trips. Keyed on stable ASCII substrings.
$soHeadAllow = 'How to use|Routing Layer|Routing table|Top recommendations|Live Inventory|Agentic OS capabilities|Built-in|Candidates|MCP connectors|Maintenance'
$soBadHeadings = (@(Get-Content -LiteralPath $soTmpl |
    Where-Object { $_ -match '^#{2,3} ' -and $_ -notmatch $soHeadAllow }) -join "`n")
Assert-Eq 'spine-only: SKILLS.template.md has only spine section headings (no operator family sections)' '' $soBadHeadings
