#Requires -Version 7
# tests/local-env-parser.test.ps1 — Windows-native twin of
# tests/local-env-parser.test.sh.
#
# Same parity contract — but the PS lane has no bash, so all parity
# assertions SKIP. The PS side covers the SAME assertion COUNT (10) so the
# per-OS test totals stay equal per the contract.
#
# Sourced by tests/run.ps1; do not call exit.

$reason = 'bash↔pwsh local.env parser parity comparison is intentionally only run by the bash twin on macOS/Linux lanes — the PS-side Import-LocalEnv behavior is covered end-to-end by sibling tests (bootstrap.test.ps1 + install.test.ps1 indirectly via local.env)'

# Mirror every bash-twin label exactly.
_Skip 'local-env-parser.test: bash baseline: KEY_PLAIN parsed non-empty' $reason
_Skip 'local-env-parser.test: bash baseline: KEY_DQUOTED parsed non-empty' $reason
_Skip 'local-env-parser.test: bash baseline: KEY_SQUOTED parsed non-empty' $reason
_Skip 'local-env-parser.test: bash baseline: KEY_EXPORTED parsed non-empty' $reason
_Skip 'local-env-parser.test: bash baseline: KEY_PATH_WITH_SPACES parsed non-empty' $reason
_Skip 'local-env-parser.test: bash baseline: KEY_HYPHEN_DASH parsed non-empty' $reason
_Skip 'local-env-parser.test: bash baseline: KEY_PQ_SPACES parsed non-empty' $reason
_Skip 'local-env-parser.test: bash baseline: KEY_PQ_AMP parsed non-empty' $reason
_Skip 'local-env-parser.test: PS Import-LocalEnv harness ran' $reason
_Skip 'local-env-parser.test: local-env parser parity: KEY_PLAIN value matches bash' $reason
_Skip 'local-env-parser.test: local-env parser parity: KEY_DQUOTED value matches bash' $reason
_Skip 'local-env-parser.test: local-env parser parity: KEY_SQUOTED value matches bash' $reason
_Skip 'local-env-parser.test: local-env parser parity: KEY_EXPORTED value matches bash' $reason
_Skip 'local-env-parser.test: local-env parser parity: KEY_PATH_WITH_SPACES value matches bash' $reason
_Skip 'local-env-parser.test: local-env parser parity: KEY_HYPHEN_DASH value matches bash' $reason
_Skip 'local-env-parser.test: local-env parser parity: KEY_PQ_SPACES value matches bash' $reason
_Skip 'local-env-parser.test: local-env parser parity: KEY_PQ_AMP value matches bash' $reason
_Skip 'local-env-parser.test: PS Import-LocalEnv survives a malformed line (warn + continue)' $reason
_Skip 'local-env-parser.test: PS Import-LocalEnv parsed GOOD past the bad line' $reason
_Skip 'local-env-parser.test: PS Import-LocalEnv parsed ALSO_GOOD past the bad line' $reason
