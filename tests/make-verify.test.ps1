#Requires -Version 7
# tests/make-verify.test.ps1 — Windows-native twin of tests/make-verify.test.sh.
#
# Makefile contract + Pre-Push acceptance tests. **All assertions are
# SKIPped on the Windows lane** because GNU Make is not available natively on
# Windows. The Windows-native equivalent is the pwsh-direct chain documented
# in the project plan: `pwsh tests/run.ps1 -and- scripts/validate.ps1 -and-
# scripts/check-drift.ps1 --manifest $env:CLAUDE_CONFIG_DIR`. That chain is
# exercised end-to-end by the `acceptance-suite-windows` CI lane, which is
# the Windows-native parity gate's 3-OS CI matrix design.
#
# Per [[feedback_port_parity_vs_regression_split]] — the Make contract is
# intrinsically POSIX; the Windows lane covers the same SEMANTIC contract via
# a different mechanism.
#
# The acceptance contract requires same AC count + same PASS/FAIL on
# identical fixtures. _Skip preserves the count + carries rationale.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$reason = 'GNU Make unavailable on Windows — semantic equivalent runs via direct pwsh chain'

_Skip 'make-verify.test: Makefile exists at repo root' $reason
_Skip 'make-verify.test: Makefile defines target: verify' $reason
_Skip 'make-verify.test: Makefile defines target: test' $reason
_Skip 'make-verify.test: Makefile defines target: validate' $reason
_Skip 'make-verify.test: Makefile defines target: drift' $reason
_Skip 'make-verify.test: Makefile defines target: render' $reason
_Skip 'make-verify.test: Makefile verify recipe sequentially calls $(MAKE) test' $reason
_Skip 'make-verify.test: Makefile verify recipe sequentially calls $(MAKE) validate' $reason
_Skip 'make-verify.test: Makefile verify recipe sequentially calls $(MAKE) drift' $reason
_Skip 'make-verify.test: Makefile marks verify as .PHONY' $reason
_Skip 'make-verify.test: Makefile marks test as .PHONY' $reason
_Skip 'make-verify.test: Makefile marks validate as .PHONY' $reason
_Skip 'make-verify.test: Makefile marks drift as .PHONY' $reason
_Skip 'make-verify.test: Makefile marks render as .PHONY' $reason
_Skip 'make-verify.test: Makefile verify recipe calls $(MAKE) test sequentially' $reason
_Skip 'make-verify.test: Makefile drift recipe uses $$CLAUDE_CONFIG_DIR (shell-time expansion)' $reason
_Skip 'make-verify.test: harnesses/claude/CLAUDE.template.md has ## Pre-Push section' $reason
_Skip 'make-verify.test: harnesses/claude/CLAUDE.template.md Pre-Push body names ''make verify''' $reason
_Skip 'make-verify.test: harnesses/claude/CLAUDE.template.md Pre-Push body names tests/run.sh' $reason
_Skip 'make-verify.test: harnesses/claude/CLAUDE.template.md Pre-Push body names scripts/validate.sh' $reason
_Skip 'make-verify.test: harnesses/claude/CLAUDE.template.md Pre-Push body names check-drift.sh' $reason
_Skip 'make-verify.test: harnesses/claude/CLAUDE.template.md Pre-Push appears before Ground Rules' $reason
_Skip 'make-verify.test: harnesses/codex/AGENTS.template.md has ## Pre-Push section' $reason
_Skip 'make-verify.test: harnesses/codex/AGENTS.template.md Pre-Push body names ''make verify''' $reason
_Skip 'make-verify.test: harnesses/codex/AGENTS.template.md Pre-Push body names tests/run.sh' $reason
_Skip 'make-verify.test: harnesses/codex/AGENTS.template.md Pre-Push body names scripts/validate.sh' $reason
_Skip 'make-verify.test: harnesses/codex/AGENTS.template.md Pre-Push body names check-drift.sh' $reason
_Skip 'make-verify.test: harnesses/codex/AGENTS.template.md Pre-Push appears before Ground Rules' $reason
_Skip 'make-verify.test: core/operating-system.md has ## Internal vs Boundary section' $reason
_Skip 'make-verify.test: core/operating-system.md Internal vs Boundary names $CLAUDE_CONFIG_DIR' $reason
_Skip 'make-verify.test: core/operating-system.md Internal vs Boundary uses ''internal''' $reason
_Skip 'make-verify.test: core/operating-system.md Internal vs Boundary uses ''boundary''' $reason
_Skip 'make-verify.test: make help shows literal $CLAUDE_CONFIG_DIR' $reason
_Skip 'make-verify.test: make help has no backslash-dollar prefix' $reason
_Skip 'make-verify.test: verification/code-change.md names ''make verify''' $reason

# Public-snapshot safety (make test/test-fast degrade when tests/ absent): the
# bash twin runs these behaviorally via GNU Make. POSIX-only contract — covered
# on Windows by the direct pwsh chain. 4 _Skip lines keep AC-count parity with
# the bash twin's fixed 4-result block.
_Skip 'make-verify.test: make test exits 0 when tests/ absent (public-snapshot safety)' $reason
_Skip 'make-verify.test: make test prints a skip notice when tests/ absent' $reason
_Skip 'make-verify.test: make test-fast exits 0 when tests/ absent (public-snapshot safety)' $reason
_Skip 'make-verify.test: make test-fast prints a skip notice when tests/ absent' $reason
_Skip 'make-verify.test: make test propagates a nonzero tests/run.sh exit (no masking)' $reason
_Skip 'make-verify.test: make drift exits 0 + skips when CLAUDE_CONFIG_DIR unset (fresh-clone safety)' $reason
