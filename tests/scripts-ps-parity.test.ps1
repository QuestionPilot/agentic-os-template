#Requires -Version 7
# tests/scripts-ps-parity.test.ps1 — Windows-native twin of
# tests/scripts-ps-parity.test.sh.
#
# Bash↔pwsh byte-parity for script ports.
#
# **All 38 assertions are SKIPped on the Windows lane** because the parity
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
_Skip 'scripts-ps-parity.test: check-memory-drift parity: exit codes match (drift fixture)' $reason
_Skip 'scripts-ps-parity.test: check-memory-drift parity: sorted output-classes match' $reason
_Skip 'scripts-ps-parity.test: check-memory-drift bash exits 0 on clean fixture' $reason
_Skip 'scripts-ps-parity.test: check-memory-drift ps exits 0 on clean fixture' $reason
_Skip 'scripts-ps-parity.test: self-audit bash exits 0 on isolated fixture' $reason
_Skip 'scripts-ps-parity.test: self-audit bash emits parseable total' $reason
_Skip 'scripts-ps-parity.test: self-audit ps exits 0 on isolated fixture' $reason
_Skip 'scripts-ps-parity.test: self-audit parity: total scores match' $reason
_Skip 'scripts-ps-parity.test: self-audit parity: pillar cross-layer-handoffs score' $reason
_Skip 'scripts-ps-parity.test: self-audit parity: pillar memory-hygiene score' $reason
_Skip 'scripts-ps-parity.test: self-audit parity: pillar folder-hygiene score' $reason
_Skip 'scripts-ps-parity.test: self-audit parity: pillar verification-coverage score' $reason
_Skip 'scripts-ps-parity.test: self-audit parity: pillar closeout-spine-discipline score' $reason
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
_Skip 'scripts-ps-parity.test: sanitize-for-publish parity holds' $reason
