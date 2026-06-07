#Requires -Version 7
# tests/context7-rule.test.ps1 — Windows-native twin of tests/context7-rule.test.sh.
#
# ctx7 rule block in harnesses/codex/AGENTS.template.md so install.sh
# --harness codex does not clobber it on re-render.
#
# Port scope decision: the bash twin's §"Render round-trip" + §"Drift gate"
# sections invoke `bash install.sh --harness codex`. install.ps1 (
# prototype) does NOT support the codex harness — line 280 dies with
# "codex harness is not implemented in the prototype — see Issue 5B
#". The bash codex harness build is Issue 5B-d scope.
#
# Under [[feedback_port_parity_vs_regression_split]] — the PS twin documents
# the gap with deliberate _Skip calls and a one-line rationale, rather than
# attempting a divergent codex.ps1 build path that doesn't exist. The bash
# round-trip test still runs on macOS/Linux lanes. When lands the
# codex install.ps1, this twin lifts the skip.
#
# Mirrors tests/context7-rule.test.sh §"Template source" 1:1.
#
# tests/lib.ps1 is dot-sourced by tests/run.ps1; Assert-* + counters already in
# scope. Do NOT re-dot-source.

$CODEX_TEMPLATE = Join-Path $env:REPO_ROOT 'harnesses' 'codex' 'AGENTS.template.md'
Assert-File 'context7-rule.test: Codex harness template exists' $CODEX_TEMPLATE

# --- Template source: ctx7 block present with markers for re-detection -------

# Opening + closing HTML-comment markers preserved so ctx7's `setup --universal`
# re-run can find and update its own block in place (rather than appending a
# duplicate). Assert exactly 2 whole-line matches via PS regex so an accidental
# future inline mention of the marker substring in prose can't silently bump
# the count without breaking ctx7's actual marker-pair contract (Codex F-1
# amendment in the bash twin).
$codexTpl = Get-Content -LiteralPath $CODEX_TEMPLATE
$ctMarkers = ($codexTpl | Where-Object { $_ -ceq '<!-- context7 -->' }).Count
Assert-Eq 'context7-rule.test: Codex template has the ctx7 open+close markers (exactly 2 whole-line matches)' '2' "$ctMarkers"

# Rule prose itself — anchor on the leading sentence ctx7 writes.
$codexTplStr = $codexTpl -join "`n"
Assert-Contains 'context7-rule.test: Codex template carries the ctx7 ''Use the ctx7 CLI'' rule' `
    $codexTplStr 'Use the `ctx7` CLI to fetch current documentation'

# The 4 numbered operating steps — anchor on Step 1 (library resolution).
Assert-Contains 'context7-rule.test: Codex template carries ctx7 Step 1 (library resolution)' `
    $codexTplStr 'Resolve library:'

# Codex-specific sandbox guidance ctx7 appends inside the codex-harness block
# (sandbox-aware DNS/fetch-error retry advice). Codex-only; Claude template
# intentionally does not carry this — that's the asymmetric install surface.
Assert-Contains 'context7-rule.test: Codex template carries the Codex-sandbox guidance ctx7 appended' `
    $codexTplStr "outside Codex's default sandbox"

# --- Render round-trip + drift gate: deliberately skipped on Windows lane ---
# Reason: install.ps1 does not yet support `--harness codex`; the codex
# build path is Issue 5B-d scope. The bash twin still covers
# round-trip + drift on macOS/Linux lanes. Skip emits a SKIP record so the
# count matches the bash twin's AC count when the codex install.ps1 lands.
_Skip 'context7-rule.test: rendered AGENTS.md preserves the ctx7 open+close markers (exactly 2 whole-line matches)' `
    'install.ps1 codex harness not implemented'
_Skip 'context7-rule.test: rendered AGENTS.md carries the ctx7 rule prose' `
    'install.ps1 codex harness not implemented'
_Skip 'context7-rule.test: rendered AGENTS.md carries the Codex-sandbox guidance' `
    'install.ps1 codex harness not implemented'
_Skip 'context7-rule.test: codex full install with ctx7 block passes drift check' `
    'install.ps1 codex harness not implemented'
