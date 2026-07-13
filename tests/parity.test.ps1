#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/parity.test.ps1 — Windows-native twin of tests/parity.test.sh.
#
# Cross-shell parity drift detector. The PS lane on Windows has no bash to
# compare against — the parity comparison is intrinsically macOS/Linux-only.
# All assertions SKIP with rationale, preserving the assertion count per
# [[feedback_port_parity_vs_regression_split]] contract.
#
# Sourced by tests/run.ps1; do not call exit.

$reason = 'cross-shell parity (bash↔pwsh) is intentionally only run by the bash twin on macOS/Linux lanes — Windows has no bash. PS-side behavior is covered end-to-end by sibling tests (validate-ps / install / drift / scripts-ps-parity).'

# Mirror every bash-twin label exactly so AC count matches.
_Skip 'parity.test: parity validate: bash exits 0 on live repo' $reason
_Skip 'parity.test: parity validate: ps exits 0 on live repo' $reason
_Skip 'parity.test: parity validate: exit codes match' $reason
_Skip 'parity.test: parity validate: sorted output classes match (excluding documented drift-call divergence)' $reason

_Skip 'parity.test: parity install --build-only: bash exits 0' $reason
_Skip 'parity.test: parity install --build-only: ps exits 0' $reason
_Skip 'parity.test: parity install --build-only: exit codes match' $reason
_Skip 'parity.test: parity install --build-only: platform-agnostic manifest entries bit-identical' $reason

_Skip 'parity.test: parity check-drift: bash exits 0 on post-build manifest' $reason
_Skip 'parity.test: parity check-drift: ps exits 0 on post-build manifest' $reason
_Skip 'parity.test: parity check-drift: exit codes match' $reason
_Skip 'parity.test: parity check-drift: sorted output classes match' $reason

_Skip 'parity.test: parity snapshot-builder: --help/-Help exit codes match' $reason
