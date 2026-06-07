#Requires -Version 7
# tests/install-orphan-hardening.test.ps1 — Windows-native twin of
# tests/install-orphan-hardening.test.sh.
#
# install.sh orphan-skill deletion hardening (path-traversal /
# control-chars / positive hash evidence). **All assertions are SKIPped on
# the Windows lane** because `install.ps1` does not currently implement
# orphan-skill cleanup — the prototype uses a full-dir swap rather
# than the per-subdir orphan-detection logic. Per the project memory body
# line 237: "install.ps1 has NO orphan-skill routine (full-dir swap per
# prototype) — propagation owed to ". The propagation to
# install.ps1 is owed by a sibling follow-on.
#
# Per [[feedback_port_parity_vs_regression_split]] — when install.ps1 gets
# the orphan-skill routine, these SKIPs lift to live assertions. The bash
# twin still runs on macOS/Linux lanes.
#
# The acceptance contract requires same AC count + same PASS/FAIL on
# identical fixtures. _Skip preserves the count + carries rationale.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$reason = 'install.ps1 has no orphan-skill routine (full-dir swap) — port owed to follow-on'

_Skip 'install-orphan-hardening.test: T1: well-formed orphan with hash-match deleted' $reason
_Skip 'install-orphan-hardening.test: T2: $TARGET sentinel preserved against `..` orphan attack' $reason
_Skip 'install-orphan-hardening.test: T2: install.sh emits warning on `..` orphan rejection' $reason
_Skip 'install-orphan-hardening.test: T2: install.sh exit code on `..` orphan rejection is 0' $reason
_Skip 'install-orphan-hardening.test: T3: Shape C survivor preserved against `.` orphan attack' $reason
_Skip 'install-orphan-hardening.test: T3: install.sh emits warning on `.` orphan rejection' $reason
_Skip 'install-orphan-hardening.test: T3: install.sh exit code on `.` orphan rejection is 0' $reason
_Skip 'install-orphan-hardening.test: T4: survivor preserved against control-char orphan attack' $reason
_Skip 'install-orphan-hardening.test: T4: install.sh emits warning on control-char orphan rejection' $reason
_Skip 'install-orphan-hardening.test: T4: install.sh exit code on control-char rejection is 0' $reason
_Skip 'install-orphan-hardening.test: T5: orphan dir without hash evidence is preserved' $reason
_Skip 'install-orphan-hardening.test: T5: install.sh exit code on no-hash-evidence preservation is 0' $reason
_Skip 'install-orphan-hardening.test: T6: LF-driven false-positive orphan half-a preserved' $reason
_Skip 'install-orphan-hardening.test: T6: LF-driven false-positive orphan half-b preserved' $reason
_Skip 'install-orphan-hardening.test: T6: install.sh exit code on LF-driven preservation is 0' $reason
_Skip 'install-orphan-hardening.test: T7: symlink orphan preserved against deletion attempt' $reason
_Skip 'install-orphan-hardening.test: T7: external symlink target preserved' $reason
_Skip 'install-orphan-hardening.test: T7: install.sh emits warning on symlink orphan rejection' $reason
_Skip 'install-orphan-hardening.test: T7: install.sh exit code on symlink orphan rejection is 0' $reason
_Skip 'install-orphan-hardening.test: T8: Shape C survivor preserved on corrupt-manifest path' $reason
_Skip 'install-orphan-hardening.test: T8: install.sh emits warning on corrupt-manifest enumeration' $reason
_Skip 'install-orphan-hardening.test: T8: install.sh exit code on corrupt-manifest skip is 0' $reason
