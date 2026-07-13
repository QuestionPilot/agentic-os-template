#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/codex-rules-overlay.test.ps1 — Windows-native twin of
# tests/codex-rules-overlay.test.sh. Replaces context7-rule.test.ps1.
#
# The codex AGENTS template is spine-only and carries the operator-rules overlay
# marker; install.sh --harness codex splices an operator-local overlay file
# (named by CODEX_RULES_OVERLAY_PATH) there at render time, or renders spine-only.
# See the .sh twin for the full rationale (the relocation of the former ctx7
# block out of the shipped template into an operator overlay).
#
# Port scope: install.ps1 does NOT support `--harness codex` (the codex build is
# bash-only — install.ps1 dies on the codex harness), so the render-machinery +
# drift-gate scenarios are deliberately _Skip'd here with a one-line rationale —
# the same gap context7-rule.test.ps1 documented under
# [[feedback_port_parity_vs_regression_split]]. The template-source invariants
# run natively. When the codex install.ps1 lands, this twin lifts the skips.
#
# tests/lib.ps1 is dot-sourced by tests/run.ps1; Assert-* + counters already in
# scope. Do NOT re-dot-source.

$CRO_TEMPLATE = Join-Path $env:REPO_ROOT 'harnesses' 'codex' 'AGENTS.template.md'
# Build the marker from halves so this source isn't a stray second literal copy.
$CRO_MARK = '@@OPERATOR_CODEX_RULES' + '_OVERLAY@@'

# --- Template source: spine-only + carries the marker exactly once -----------
Assert-File 'codex-rules-overlay.test: codex AGENTS template exists' $CRO_TEMPLATE
$croMarkerN = @(Select-String -LiteralPath $CRO_TEMPLATE -SimpleMatch -Pattern $CRO_MARK).Count
Assert-Eq 'codex-rules-overlay.test: codex template carries the overlay marker exactly once' '1' "$croMarkerN"
# The relocated ctx7 block must be gone. Pattern from halves; Select-String is
# case-insensitive by default (matches the bash `grep -ciE`).
$croC7 = 'con' + 'text7'; $croCx = 'ct' + 'x7'
$croCtx7N = @(Select-String -LiteralPath $CRO_TEMPLATE -Pattern ($croC7 + '|' + $croCx)).Count
Assert-Eq 'codex-rules-overlay.test: codex template ships no ctx7/context7 (relocated to overlay)' '0' "$croCtx7N"

# --- Render machinery + drift gate: deliberately skipped on the Windows lane --
# Reason: install.ps1 does not support `--harness codex`; the codex build path is
# bash-only. The bash twin covers the overlay splice (present / unset / set-but-
# missing / marker-in-overlay) + the drift gate on macOS/Linux lanes. Skip emits
# a SKIP record so the count tracks the bash twin when the codex install.ps1 lands.
_Skip 'codex-rules-overlay.test: overlay present -> content spliced + @@VAR@@ resolved + marker consumed' `
    'install.ps1 codex harness not implemented'
_Skip 'codex-rules-overlay.test: overlay unset -> spine-only AGENTS.md (no content, marker consumed)' `
    'install.ps1 codex harness not implemented'
_Skip 'codex-rules-overlay.test: overlay set-but-missing -> warns + exits 0 + spine-only' `
    'install.ps1 codex harness not implemented'
_Skip 'codex-rules-overlay.test: overlay re-introduces marker -> neutralized, no resolves-empty die' `
    'install.ps1 codex harness not implemented'
_Skip 'codex-rules-overlay.test: codex overlay carrying the SKILLS marker still renders (no resolves-empty die)' `
    'install.ps1 codex harness not implemented'
_Skip 'codex-rules-overlay.test: cross-overlay SKILLS marker neutralized (0 left in AGENTS.md)' `
    'install.ps1 codex harness not implemented'
_Skip 'codex-rules-overlay.test: codex full install (spine-only) passes drift check' `
    'install.ps1 codex harness not implemented'
