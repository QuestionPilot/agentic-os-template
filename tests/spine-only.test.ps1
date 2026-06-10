#Requires -Version 7
# tests/spine-only.test.ps1 — Windows-native twin of tests/spine-only.test.sh.
#
# Guards the spine-only invariant: agentic-os-template (and the public template) ship ONLY
# the OS spine (session-agent, closeout, self-audit) + their machinery + the
# linear/ and obsidian/ contracts. Zero operator tool opinions. See the.sh twin's
# header for the full rationale, the ctx7/context7 audit (now with NO template
# exception — the former codex ctx7-managed block moved to an operator overlay),
# the F4 line-scoped allowlist (scripts/validate.* + build-public-snapshot.* +
# linear/ + obsidian/ are now SCANNED, not file-excluded), and the .codegraph
# carve-outs.
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
# Twin of the.sh audit. ctx7/context7 join the forbidden set; only docs/ + tests/
# stay file-excluded. The allowlist is per-OCCURRENCE (Codex F1) AND anchored to the
# secret-scan CONTENT SIGNATURE — a brand-free token from the surrounding secret-scan
# construct (`_live_` / `bgnpriv` in validate.ps1, `secretpattern` in the js scan),
# NOT just the file path. The bare brand is stripped ONLY on lines carrying that
# signature, so a tool opinion elsewhere in the file trips even if it embeds the brand
# inside a variable/key name. -replace / -match are case-insensitive by default; the
# lowercased line + lowercase pattern keep parity with the bash `tr|sed|grep`. Built
# from halves.
$soPat = 'play' + 'wright|sup' + 'abase|net' + 'lify|str' + 'ipe|fire' + 'crawl|web-design-' + 'guidelines|frontend-' + 'design|con' + 'text7|ct' + 'x7'
$soStr = 'str' + 'ipe'; $soSup = 'sup' + 'abase'
function Test-SpineResidual {
    # Strip the bare brand from a (lowercased) git-grep hit line ONLY when the line
    # carries the secret-scan signature for its file (brand-free anchors): validate.ps1
    # `_live_` / `bgnpriv` bracket the two $stripeLive uses; memory-vault-audit.js
    # `secretpattern` brackets the env-var keys. A tool opinion lacking the anchor is
    # left intact and trips.
    param([string]$Line)
    $lc = $Line.ToLowerInvariant()
    if ($lc -match '^scripts/validate\.ps1:') {
        if ($lc -match '_live_' -or $lc -match 'bgnpriv') { $lc = $lc -replace $soStr, '' }
    } elseif ($lc -match '^obsidian/vault-scaffolding/bin/memory-vault-audit\.js:') {
        if ($lc -match 'secretpattern') { $lc = ($lc -replace $soStr, '') -replace $soSup, '' }
    }
    return ($lc -match $soPat)
}
$soRaw = @(& git -C $soRoot grep -niIE $soPat -- ':!tests/' ':!docs/' 2>$null)
$hits = (@($soRaw | Where-Object { Test-SpineResidual $_ }) -join "`n")
Assert-Eq 'spine-only: no operator tool identifiers outside the allowlisted DATA lines' '' $hits

# Self-trip regression A — per-occurrence: a forbidden identifier sharing a real
# secret-scan line still trips (brand stripped, co-located identifier survives).
# Parenthesize each element — in PowerShell the `,` array separator binds tighter than
# `+`, so unparenthesized `'a'+'b', 'c'+'d'` collapses into ONE element.
$soEvil = @(
    ('scripts/validate.ps1:210:' + $soStr + "live = '_live_' regex; also wire fire" + 'crawl'),
    ('obsidian/vault-scaffolding/bin/memory-vault-audit.js:69:const secretpattern ' + $soStr + '_secret_key|' + $soSup + '_service_role_key; plus play' + 'wright')
)
$soEvilN = @($soEvil | Where-Object { Test-SpineResidual $_ }).Count
Assert-Eq 'spine-only: a forbidden identifier on a real secret-scan line still trips' '2' "$soEvilN"

# Self-trip regression B — pure opinion: a bare-brand tool opinion in an allowlisted
# file (no secret-scan signature) MUST trip. Brands split so this source isn't self-listing.
$soPure = @(
    ('scripts/validate.ps1:99:# use the ' + $soStr + ' cli for billing checks'),
    ('obsidian/vault-scaffolding/bin/memory-vault-audit.js:99:# wire ' + $soSup + ' and ' + $soStr + ' here')
)
$soPureN = @($soPure | Where-Object { Test-SpineResidual $_ }).Count
Assert-Eq 'spine-only: a pure bare-brand opinion in an allowlisted file still trips' '2' "$soPureN"

# Self-trip regression C — signature-form prose: a tool opinion embedding the brand
# inside the secret-scan variable/key NAME but lacking the surrounding signature MUST
# still trip — the file-scoped signature-token strip masked these (Codex pass).
$soEvade = @(
    ('scripts/validate.ps1:99:# use ' + $soStr + 'live for billing checks'),
    ('obsidian/vault-scaffolding/bin/memory-vault-audit.js:99:# wire ' + $soSup + '_service_role_key and ' + $soStr + '_secret_key here')
)
$soEvadeN = @($soEvade | Where-Object { Test-SpineResidual $_ }).Count
Assert-Eq 'spine-only: brand in a signature name without the secret-scan context still trips' '2' "$soEvadeN"

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
