#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/scripts-ps-parity.test.ps1 — Windows-native twin of
# tests/scripts-ps-parity.test.sh.
#
# Bash↔pwsh byte-parity for script ports.
#
# **All assertions are SKIPped on the Windows lane** because the parity
# comparison requires BOTH `bash` AND `pwsh` to be present, and the Windows
# lane intentionally has no bash. The bash twin already runs this exact
# comparison on the macOS/Linux lane — running it again from the PS side
# (which still needs both interpreters available to compare) would be
# duplicative and would silently SKIP on Windows-only anyway.
#
# Per [[feedback_port_parity_vs_regression_split]] — the parity is COVERED
# by tests/drift.test.ps1, tests/memory-drift.test.ps1, tests/self-audit.ps1
# which exercise the PS-side behavior end-to-end on the Windows lane. The
# bash-vs-PS comparison is itself macOS/Linux-only.
#
# The acceptance contract ("same AC count, same PASS/FAIL on identical
# fixtures") is honored by emitting one SKIP per bash-twin assertion with
# explicit rationale.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$reason = 'bash↔pwsh parity comparison is intentionally only run by the bash twin on macOS/Linux lanes — PS-side behavior is covered end-to-end by sibling tests (drift / memory-drift / self-audit)'

# Mirror every bash-twin label exactly so the AC count matches.
# The PARITY_REQUIRE_PWSH meta-test + the quoted-name / freshness-boundary parity
# fixtures below are bash-lane-only (the gate guards the bash twin; the Windows
# lane runs PS tests in isolation with no bash<->PS cross-check to gate).
$reasonGate = 'the PARITY_REQUIRE_PWSH gate + the boundary parity fixtures run only on the bash twin (macOS/Linux) — the Windows lane has no bash to cross-check against'
_Skip 'scripts-ps-parity.test: PARITY_REQUIRE_PWSH=1 + no pwsh => hard FAIL (cross-check cannot silently skip)' $reasonGate
_Skip 'scripts-ps-parity.test: PARITY_REQUIRE_PWSH unset + no pwsh => silent skip (local-dev convenience preserved)' $reasonGate
_Skip 'scripts-ps-parity.test: check-memory-drift parity: exit codes match (drift fixture)' $reason
_Skip 'scripts-ps-parity.test: check-memory-drift parity: sorted output-classes match' $reason
_Skip 'scripts-ps-parity.test: check-memory-drift bash exits 0 on clean fixture' $reason
_Skip 'scripts-ps-parity.test: check-memory-drift ps exits 0 on clean fixture' $reason
_Skip 'scripts-ps-parity.test: check-memory-drift bash: quoted-name self-link is NOT drift (exit 0)' $reasonGate
_Skip 'scripts-ps-parity.test: check-memory-drift ps: quoted-name self-link is NOT drift (exit 0)' $reasonGate
_Skip 'scripts-ps-parity.test: check-memory-drift parity: quoted-name self-link exit codes match (quote-strip)' $reasonGate
_Skip 'scripts-ps-parity.test: check-memory-drift parity: single-quoted name self-link — exit codes match (twins symmetric)' $reasonGate
_Skip 'scripts-ps-parity.test: check-memory-drift bash: BOM''d CLOSED project still detects drift (BOM strip)' $reasonGate
_Skip 'scripts-ps-parity.test: check-memory-drift parity: BOM''d project exit codes match (BOM strip)' $reasonGate
_Skip 'scripts-ps-parity.test: self-audit bash exits 0 on isolated fixture' $reason
_Skip 'scripts-ps-parity.test: self-audit bash emits parseable total' $reason
_Skip 'scripts-ps-parity.test: self-audit ps exits 0 on isolated fixture' $reason
_Skip 'scripts-ps-parity.test: self-audit parity: total scores match' $reason
_Skip 'scripts-ps-parity.test: self-audit parity: pillar cross-layer-handoffs score' $reason
_Skip 'scripts-ps-parity.test: self-audit parity: pillar memory-hygiene score' $reason
_Skip 'scripts-ps-parity.test: self-audit parity: pillar folder-hygiene score' $reason
_Skip 'scripts-ps-parity.test: self-audit parity: pillar verification-coverage score' $reason
_Skip 'scripts-ps-parity.test: self-audit parity: pillar closeout-spine-discipline score' $reason
_Skip 'scripts-ps-parity.test: self-audit parity: semantic_currentness verdict + shape match' $reason
_Skip 'scripts-ps-parity.test: self-audit bash: 6.5d counted / 7.5d excluded — one State-Deltas penalty (epoch cutoff)' $reasonGate
_Skip 'scripts-ps-parity.test: self-audit parity: 6.5-day (inside) pillar score matches (epoch freshness)' $reasonGate
_Skip 'scripts-ps-parity.test: self-audit parity: 7.5-day (outside) pillar score matches (epoch freshness)' $reasonGate
_Skip 'scripts-ps-parity.test: check-drift bash --manifest exits 0 on clean fixture' $reason
_Skip 'scripts-ps-parity.test: check-drift ps --manifest exits 0 on clean fixture' $reason
_Skip 'scripts-ps-parity.test: check-drift parity: exit codes match (clean manifest)' $reason
_Skip 'scripts-ps-parity.test: check-drift parity: sorted output-classes match (clean manifest)' $reason
_Skip 'scripts-ps-parity.test: check-drift bash --manifest exits 1 on drift fixture' $reason
_Skip 'scripts-ps-parity.test: check-drift ps --manifest exits 1 on drift fixture' $reason
_Skip 'scripts-ps-parity.test: check-drift parity: exit codes match (drift manifest)' $reason
_Skip 'scripts-ps-parity.test: check-drift parity: STRICT byte-identical normalized output (clean manifest)' $reason
_Skip 'scripts-ps-parity.test: check-drift bash --manifest exits 0 on skills+hooks fixture' $reason
_Skip 'scripts-ps-parity.test: check-drift ps --manifest exits 0 on skills+hooks fixture' $reason
_Skip 'scripts-ps-parity.test: check-drift parity: STRICT byte-identical (skills+hooks fixture)' $reason
_Skip 'scripts-ps-parity.test: check-drift ps --manifest exits 0 on RELATIVE path (F-1 regression)' $reason
_Skip 'scripts-ps-parity.test: check-drift bash --manifest exits 0 on RELATIVE path (F-1 regression)' $reason
_Skip 'scripts-ps-parity.test: check-drift parity: STRICT byte-identical (RELATIVE path)' $reason
_Skip 'scripts-ps-parity.test: check-drift ps exits 0 via symlink-aliased repo root (macOS /tmp regression)' $reason
_Skip 'scripts-ps-parity.test: check-drift bash exits 0 via symlink-aliased repo root' $reason
_Skip 'scripts-ps-parity.test: check-drift parity: STRICT byte-identical (symlink-aliased repo root)' $reason
_Skip 'scripts-ps-parity.test: validate parity: exit codes match via symlink-aliased repo root' $reason
_Skip 'scripts-ps-parity.test: check-memory-drift bash exits 1 on 2-drift fixture' $reason
_Skip 'scripts-ps-parity.test: check-memory-drift ps exits 1 on 2-drift fixture' $reason
_Skip 'scripts-ps-parity.test: check-memory-drift parity: sorted byte-identical (2-drift fixture; iteration-order divergent)' $reason
_Skip "scripts-ps-parity.test: check-memory-drift bash reports '1 drift(s)' (bash boolean quirk)" $reason
_Skip "scripts-ps-parity.test: check-memory-drift ps mirrors bash '1 drift(s)' quirk (F-3 port-parity)" $reason
_Skip 'scripts-ps-parity.test: check-memory-drift.ps1 accepts POSIX --memory-dir' $reason
_Skip 'scripts-ps-parity.test: self-audit.ps1 accepts POSIX --json + --isolated + --repo-root' $reason
_Skip 'scripts-ps-parity.test: check-drift.ps1 accepts POSIX --manifest' $reason
_Skip 'scripts-ps-parity.test: build-public-snapshot.sh --help exits 0' $reason
_Skip 'scripts-ps-parity.test: build-public-snapshot.ps1 -Help exits 0' $reason
_Skip 'scripts-ps-parity.test: build-public-snapshot --help/-Help exit codes match' $reason
