#!/usr/bin/env bash
# tiering: install-heavy — runs bootstrap.sh / install.sh ~28× across
# fresh-clone + re-render cases. Skipped by `make test-fast`.
# test-tier: slow
# tests/bootstrap.test.sh — bootstrap.sh acceptance tests.

BS="$REPO_ROOT/scripts/bootstrap.sh"

# --help exits 0
assert_exit "bootstrap.sh --help exits 0" 0 -- bash "$BS" --help

# Unknown arg exits 2
assert_exit "bootstrap.sh unknown arg exits 2" 2 -- bash "$BS" --bogus-flag

# --check exits 0 when all CLIs present and stub env clean
# (requires stubs — built in Task 3; placeholder until then)

# --- CLI check tests ---
# Shared stub dir for all CLI check tests.
BS_STUBS="$(mktemp -d)"

# Full set of stubs at the minimum acceptable version.
make_stub_cli "$BS_STUBS" codex "codex 0.132.0"
make_stub_cli "$BS_STUBS" gh    "gh version 2.50.0 (2026-01-01)"
make_stub_cli "$BS_STUBS" jq    "jq-1.7.0"
make_stub_cli "$BS_STUBS" rg    "ripgrep 14.0.0"
# gh auth status stub — exit 0 (authenticated)
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 2.50.0"; else echo "Logged in"; fi\nexit 0\n' > "$BS_STUBS/gh"
chmod +x "$BS_STUBS/gh"

# All-present run — should exit 0
bs_all_ok=0
PATH="$BS_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO_ROOT/scripts/bootstrap.sh" --check >/dev/null 2>&1 \
  || bs_all_ok=$?
assert_eq "bootstrap --check exits 0 when all CLIs present" "0" "$bs_all_ok"

# Missing CLI: remove rg stub
rm "$BS_STUBS/rg"
bs_missing_out="$(PATH="$BS_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO_ROOT/scripts/bootstrap.sh" --check 2>&1)" \
  || true
assert_contains "bootstrap --check reports missing rg" "$bs_missing_out" "rg"
assert_contains "bootstrap --check says not found"     "$bs_missing_out" "not found"

bs_missing_exit=0
PATH="$BS_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO_ROOT/scripts/bootstrap.sh" --check >/dev/null 2>&1 \
  || bs_missing_exit=$?
assert_eq "bootstrap --check exits non-zero on missing CLI" "1" "$bs_missing_exit"
make_stub_cli "$BS_STUBS" rg "ripgrep 14.0.0"  # restore

# Outdated CLI: give jq a version below 1.6.0
make_stub_cli "$BS_STUBS" jq "jq-1.5.0"
bs_old_out="$(PATH="$BS_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO_ROOT/scripts/bootstrap.sh" --check 2>&1)" \
  || true
assert_contains "bootstrap --check reports outdated jq" "$bs_old_out" "jq"
assert_contains "bootstrap --check reports version too old" "$bs_old_out" "1.5.0"
make_stub_cli "$BS_STUBS" jq "jq-1.7.0"  # restore

# Unparseable version: a present CLI whose --version has no semver must be
# handled gracefully (warn + continue), not crash the script under set -e.
make_stub_cli "$BS_STUBS" rg "ripgrep nightly"
bs_unparse_out="$(PATH="$BS_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO_ROOT/scripts/bootstrap.sh" --check 2>&1)" || true
assert_contains "bootstrap --check survives an unparseable CLI version" "$bs_unparse_out" "Some checks failed"
assert_contains "bootstrap --check still flags the unparseable CLI" "$bs_unparse_out" "rg"
make_stub_cli "$BS_STUBS" rg "ripgrep 14.0.0"  # restore

rm -rf "$BS_STUBS"

# --- install_clis dry-run tests ---
# Stub set WITH all CLIs present → install_clis should be a no-op (no brew call)
BS_INST="$(mktemp -d)"
make_stub_cli "$BS_INST" codex "codex 0.132.0"
make_stub_cli "$BS_INST" jq    "jq-1.7.0"
make_stub_cli "$BS_INST" rg    "ripgrep 14.0.0"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 2.50.0"; else echo "Logged in"; fi\nexit 0\n' > "$BS_INST/gh"
chmod +x "$BS_INST/gh"
printf '#!/bin/sh\necho "brew: should NOT be called"; exit 1\n' > "$BS_INST/brew"
chmod +x "$BS_INST/brew"

bs_noop_out="$(PATH="$BS_INST:/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO_ROOT/scripts/bootstrap.sh" \
  --dry-run --claude-config-dir /tmp/bs-test 2>&1)"
assert_not_contains "install_clis skips brew when all CLIs present" \
  "$bs_noop_out" "brew: should NOT be called"

# Remove rg → dry-run should print the install action
rm "$BS_INST/rg"
bs_dryrg_out="$(PATH="$BS_INST:/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO_ROOT/scripts/bootstrap.sh" \
  --dry-run --claude-config-dir /tmp/bs-test 2>&1)"
assert_contains "dry-run shows rg install action" "$bs_dryrg_out" "ripgrep"

# removed the 'agy install via Antigravity script' dry-run test case.
# bootstrap.sh no longer dispatches the Antigravity install — the agy unwire
# removed the elif block from install_clis. The remaining install methods
# (brew formula + npm pkg) are exercised by the rg + codex tests
# above and below.

rm -rf "$BS_INST"

# --- set_config_dir_env tests ---
# Use a temp HOME so we never touch the real ~/.zshenv.
BS_HOME="$(mktemp -d)"

# Fresh machine:.zshenv does not exist → bootstrap writes it.
bs_env_out="$(HOME="$BS_HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO_ROOT/scripts/bootstrap.sh" \
  --dry-run --claude-config-dir "/tmp/claude config" 2>&1)"  # path with space
assert_contains "dry-run reports zshenv write" "$bs_env_out" "zshenv"
assert_contains "dry-run mentions the config dir" "$bs_env_out" "/tmp/claude\\ config"

# Full mode:.zshenv created with quoted export.
BS_HOME2="$(mktemp -d)"
BS_STUBS2="$(mktemp -d)"
make_stub_cli "$BS_STUBS2" codex "codex 0.132.0"
make_stub_cli "$BS_STUBS2" jq    "jq-1.7.0"
make_stub_cli "$BS_STUBS2" rg    "ripgrep 14.0.0"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 2.50.0"; else echo "Logged in"; fi\nexit 0\n' > "$BS_STUBS2/gh"
chmod +x "$BS_STUBS2/gh"
BS_CFGDIR2="$BS_HOME2/claude - Local/claude-config"   # path with spaces
mkdir -p "$BS_CFGDIR2"
# Provide a minimal local.env so install.sh doesn't fail.
printf 'CLAUDE_CONFIG_DIR=%q\nOBSIDIAN_VAULT_PATH=%q\n' \
  "$BS_CFGDIR2" "/tmp/vault" > "$BS_HOME2/local.env"

# Run with a stub install.sh (so we don't call the real one in this unit test).
BS_REPO2="$(mktemp -d)"
cp -R "$REPO_ROOT/." "$BS_REPO2/"
rm -rf "$BS_REPO2/.git"
# Stub install.sh: exit 0 instantly
printf '#!/bin/sh\necho "stub install.sh"; exit 0\n' > "$BS_REPO2/scripts/install.sh"
chmod +x "$BS_REPO2/scripts/install.sh"
# Stub validate.sh: exit 0 instantly
printf '#!/bin/sh\nexit 0\n' > "$BS_REPO2/scripts/validate.sh"
chmod +x "$BS_REPO2/scripts/validate.sh"
# Use a local.env in the repo copy
cp "$BS_HOME2/local.env" "$BS_REPO2/local.env"

HOME="$BS_HOME2" PATH="$BS_STUBS2:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$BS_REPO2/scripts/bootstrap.sh" \
  --claude-config-dir "$BS_CFGDIR2" --vault-dir /tmp/vault >/dev/null 2>&1

zshenv2="$BS_HOME2/.zshenv"
assert_file "bootstrap created ~/.zshenv" "$zshenv2"
if [ -f "$zshenv2" ]; then
  zenv_content="$(cat "$zshenv2")"
  assert_contains "zshenv exports CLAUDE_CONFIG_DIR" "$zenv_content" "CLAUDE_CONFIG_DIR"
  assert_contains "zshenv value is quoted (has backslash or quotes)" \
    "$zenv_content" "claude\\ -\\ Local"
fi

# Idempotency: a second run should not duplicate the line.
HOME="$BS_HOME2" PATH="$BS_STUBS2:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$BS_REPO2/scripts/bootstrap.sh" \
  --claude-config-dir "$BS_CFGDIR2" --vault-dir /tmp/vault >/dev/null 2>&1
line_count="$(grep -c 'CLAUDE_CONFIG_DIR' "$zshenv2" 2>/dev/null || echo 0)"
assert_eq "zshenv has exactly one CLAUDE_CONFIG_DIR line (idempotent)" "1" "$line_count"

rm -rf "$BS_HOME" "$BS_HOME2" "$BS_STUBS2" "$BS_REPO2"

# --- check_auth: unauthenticated gh ---
BS_AUTH_STUBS="$(mktemp -d)"
make_stub_cli "$BS_AUTH_STUBS" codex "codex 0.132.0"
make_stub_cli "$BS_AUTH_STUBS" rg    "ripgrep 14.0.0"
make_stub_cli "$BS_AUTH_STUBS" jq    "jq-1.7.0"
# gh stub: auth status fails (unauthenticated)
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 2.50.0"; exit 0; fi\necho "Not logged in"; exit 1\n' \
  > "$BS_AUTH_STUBS/gh"; chmod +x "$BS_AUTH_STUBS/gh"

bs_auth_out="$(PATH="$BS_AUTH_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$REPO_ROOT/scripts/bootstrap.sh" --check 2>&1)" || true
assert_contains "check_auth warns on unauthenticated gh" "$bs_auth_out" "gh"

rm -rf "$BS_AUTH_STUBS"

# --- full end-to-end bootstrap test ---
# Uses stub CLIs + stub install.sh/validate.sh + temp HOME.
E2E_HOME="$(mktemp -d)"
E2E_STUBS="$(mktemp -d)"
E2E_REPO="$(mktemp -d)"
cp -R "$REPO_ROOT/." "$E2E_REPO/"; rm -rf "$E2E_REPO/.git"

make_stub_cli "$E2E_STUBS" codex "codex 0.132.0"
make_stub_cli "$E2E_STUBS" jq    "jq-1.7.0"
make_stub_cli "$E2E_STUBS" rg    "ripgrep 14.0.0"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 2.50.0"; exit 0; fi\necho "Logged in"; exit 0\n' \
  > "$E2E_STUBS/gh"; chmod +x "$E2E_STUBS/gh"
# Stub validate.sh: exit 0 instantly.
printf '#!/bin/sh\nexit 0\n' \
  > "$E2E_REPO/scripts/validate.sh"; chmod +x "$E2E_REPO/scripts/validate.sh"

E2E_CFG="$E2E_HOME/claude - Local/claude-config"  # spaces in path
mkdir -p "$E2E_CFG"
E2E_VAULT="/tmp/e2e-vault"
# Pre-populate local.env in the repo copy (so seed_local_env sees it as existing).
printf 'CLAUDE_CONFIG_DIR=%q\nOBSIDIAN_VAULT_PATH=%q\n' \
  "$E2E_CFG" "$E2E_VAULT" > "$E2E_REPO/local.env"

# Stub install.sh creates the expected entrypoint.
printf '#!/bin/sh\nmkdir -p "%s" && echo "stub" > "%s/CLAUDE.md"; exit 0\n' \
  "$E2E_CFG" "$E2E_CFG" > "$E2E_REPO/scripts/install.sh"
chmod +x "$E2E_REPO/scripts/install.sh"

e2e_exit=0
e2e_out="$(HOME="$E2E_HOME" PATH="$E2E_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$E2E_REPO/scripts/bootstrap.sh" \
  --claude-config-dir "$E2E_CFG" --vault-dir "$E2E_VAULT" 2>&1)" || e2e_exit=$?
assert_eq "full bootstrap exits 0" "0" "$e2e_exit"
assert_file "full bootstrap created ~/.zshenv" "$E2E_HOME/.zshenv"
assert_contains "full bootstrap sets CLAUDE_CONFIG_DIR in zshenv" \
  "$(cat "$E2E_HOME/.zshenv" 2>/dev/null)" "CLAUDE_CONFIG_DIR"
assert_contains "full bootstrap prints auth checklist" "$e2e_out" "gh auth login"

rm -rf "$E2E_HOME" "$E2E_STUBS" "$E2E_REPO" 2>/dev/null || true

# --- bootstrap.ps1 tests (skip if pwsh unavailable) ---
if command -v pwsh >/dev/null 2>&1; then
  PS1="$REPO_ROOT/scripts/bootstrap.ps1"
  PWSH_BIN="$(command -v pwsh)"

  # Stub every CLI in bootstrap.ps1's $cliMin at a version that satisfies the
  # minimum. Previously this wrote "<name> 1.0.0" for everything, which made jq
  # fail its 1.6.0 floor and masked the rg gate behind a jq version error.
  #
  # `bash` is NO LONGER in $cliMin (the no-bash route routes
  # install + validate through pwsh natively). The stub set must therefore
  # omit bash too — leaving it in is harmless but signals the wrong
  # expectation. See "bootstrap.ps1 NO LONGER requires bash" assertion below.
  PS_STUBS="$(mktemp -d)"
  make_stub_cli "$PS_STUBS" codex     "codex 0.132.0"
  make_stub_cli "$PS_STUBS" firecrawl "firecrawl 1.0.0"
  make_stub_cli "$PS_STUBS" jq        "jq-1.7.0"
  make_stub_cli "$PS_STUBS" rg        "ripgrep 14.0.0"
  # gh stub also responds to subcommands for the auth check.
  printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 2.50.0"; exit 0; fi\necho "Logged in"; exit 0\n' \
    > "$PS_STUBS/gh"; chmod +x "$PS_STUBS/gh"

  # Strip the inherited PATH down to ONLY the stub dir — even /usr/bin:/bin is
  # unsafe because Linux/CI hosts typically install rg/jq/gh under /usr/bin
  # (e.g. apt-installed), and removing a stub would still find the real binary
  # via that baseline. PWSH_BIN is invoked by absolute path so pwsh itself does
  # not need to be on PATH; every CLI bootstrap.ps1 checks is stubbed above.
  PS_TEST_PATH="$PS_STUBS"

  ps_ok=0
  PATH="$PS_TEST_PATH" "$PWSH_BIN" -File "$PS1" -Check 2>/dev/null || ps_ok=$?
  assert_eq "bootstrap.ps1 -Check exits 0 with all CLIs present" "0" "$ps_ok"

  # Remove rg → -Check exits non-zero
  rm "$PS_STUBS/rg"
  ps_miss=0
  PATH="$PS_TEST_PATH" "$PWSH_BIN" -File "$PS1" -Check 2>/dev/null || ps_miss=$?
  assert_eq "bootstrap.ps1 -Check exits 1 on missing CLI" "1" "$ps_miss"

  # -DryRun includes install action for missing rg
  ps_dry_out="$(PATH="$PS_TEST_PATH" "$PWSH_BIN" -File "$PS1" -DryRun 2>&1)"
  assert_contains "bootstrap.ps1 -DryRun mentions rg install" "$ps_dry_out" "rg"

  # --- bootstrap.ps1 NO LONGER requires bash ---
  # The script must not list `bash` in its required-CLI map and must not
  # shell out to `bash install.sh` / `bash validate.sh`. Static-source check
  # plus a behavioral check (no `bash` in $cliMin via -Check on a PATH
  # without bash).
  make_stub_cli "$PS_STUBS" rg "ripgrep 14.0.0"  # restore rg so -Check has all required CLIs

  # Build a PATH that DELIBERATELY excludes any system bash — only the stub
  # dir. -Check must still exit 0 because bash is no longer required.
  ps_nobash=0
  PATH="$PS_STUBS" "$PWSH_BIN" -File "$PS1" -Check 2>/dev/null || ps_nobash=$?
  assert_eq "bootstrap.ps1 -Check exits 0 without bash on PATH" "0" "$ps_nobash"

  # Static-source guards. Script must not declare `bash = "presence"` in
  # $cliMin and must not contain `& bash` shell-out calls. Codex F-2 +
  # F-3 amendments: also assert the pwsh binary is captured via
  # ProcessPath (not `& pwsh` by name) AND that the smoke path explicitly
  # calls check-drift.ps1.
  ps_src="$(cat "$PS1")"
  assert_not_contains "bootstrap.ps1 has no 'bash =' entry in cliMin" \
    "$ps_src" 'bash      = "presence"'
  assert_not_contains "bootstrap.ps1 has no '& bash ' shell-out" \
    "$ps_src" '& bash '
  assert_contains "bootstrap.ps1 captures pwsh path via ProcessPath" \
    "$ps_src" 'ProcessPath'
  assert_contains "bootstrap.ps1 Invoke-SmokeTest calls check-drift.ps1" \
    "$ps_src" 'check-drift.ps1'

  # The -DryRun mode should show the install action routed through pwsh, not
  # bash. With all CLIs present, -DryRun on full mode (not just -Check) lists
  # the install step. We need to stub install.ps1 to no-op so the script
  # completes; in dry-run it doesn't actually run.
  PS_HOME="$(mktemp -d)"
  PS_DRY_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$PS_DRY_REPO/"; rm -rf "$PS_DRY_REPO/.git"
  # Pre-seed local.env so seed_local_env is a no-op.
  printf 'CLAUDE_CONFIG_DIR=%s\nOBSIDIAN_VAULT_PATH=/tmp/vault\n' \
    "$PS_HOME/cfg" > "$PS_DRY_REPO/local.env"
  ps_dryrun_full="$(HOME="$PS_HOME" PATH="$PS_TEST_PATH" "$PWSH_BIN" -File \
    "$PS_DRY_REPO/scripts/bootstrap.ps1" -DryRun 2>&1)"
  assert_contains "bootstrap.ps1 -DryRun routes install through pwsh" \
    "$ps_dryrun_full" "install.ps1"
  assert_not_contains "bootstrap.ps1 -DryRun does NOT shell out to bash install.sh" \
    "$ps_dryrun_full" "bash $PS_DRY_REPO/scripts/install.sh"

  # --- first-run seed-empty install must succeed (PowerShell) ---
  # Parity with the bash cases below. Fresh clone, NO pre-existing
  # local.env, REAL template (empty values), value via -ClaudeConfigDir. Stub
  # install.ps1 re-imports the seeded local.env and FAILS (exit 90) if the build
  # target / vault do not resolve — mirroring real install.ps1. validate.ps1 +
  # check-drift.ps1 are stubbed to exit 0 (the temp repo is not a git checkout,
  # so the real drift gate would false-fail on the freshly generated tree).
  PS133_HOME="$(mktemp -d)"; PS133_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$PS133_REPO/"; rm -rf "$PS133_REPO/.git" "$PS133_REPO/local.env"
  cat > "$PS133_REPO/scripts/install.ps1" <<'PSSTUB'
#Requires -Version 7
param([string]$Harness='claude',[string]$Out='',[Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
for ($i=0; $i -lt $Rest.Count; $i++) {
  if ($Rest[$i] -eq '--out') { $Out = $Rest[$i+1]; $i++ }
  elseif ($Rest[$i] -eq '--harness') { $Harness = $Rest[$i+1]; $i++ }
}
$le = Join-Path (Split-Path $PSScriptRoot -Parent) 'local.env'
. (Join-Path $PSScriptRoot 'lib/local-env.ps1'); if (Test-Path $le) { Import-LocalEnv -Path $le }
$target = if ($Out) { $Out } else { $env:CLAUDE_CONFIG_DIR }
if (-not $target) { [Console]::Error.WriteLine('install.ps1: CLAUDE_CONFIG_DIR is not set (or pass -Out)'); exit 90 }
if (-not $env:OBSIDIAN_VAULT_PATH) { [Console]::Error.WriteLine('install.ps1: OBSIDIAN_VAULT_PATH resolves empty'); exit 90 }
New-Item -ItemType Directory -Path $target -Force | Out-Null
Set-Content -Path (Join-Path $target 'CLAUDE.md') -Value 'stub'
exit 0
PSSTUB
  printf '#Requires -Version 7\nexit 0\n' > "$PS133_REPO/scripts/validate.ps1"
  printf '#Requires -Version 7\nparam([string]$Manifest="")\nexit 0\n' > "$PS133_REPO/scripts/check-drift.ps1"
  PS133_CFG="$PS133_HOME/cfg"
  ps133_exit=0
  env -u CLAUDE_CONFIG_DIR -u OBSIDIAN_VAULT_PATH -u CODEX_HOME \
    HOME="$PS133_HOME" PATH="$PS_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" FIRECRAWL_API_KEY="k" \
    "$PWSH_BIN" -NoProfile -File "$PS133_REPO/scripts/bootstrap.ps1" \
    -ClaudeConfigDir "$PS133_CFG" -VaultDir /tmp/ps133-vault </dev/null >/dev/null 2>&1 || ps133_exit=$?
  assert_eq "bootstrap.ps1 first-run (flag) exits 0" "0" "$ps133_exit"
  assert_file "bootstrap.ps1 first-run produced the entrypoint" "$PS133_CFG/CLAUDE.md"
  assert_contains "bootstrap.ps1 seeded local.env carries the config dir" \
    "$(cat "$PS133_REPO/local.env" 2>/dev/null)" "$PS133_CFG"
  rm -rf "$PS133_HOME" "$PS133_REPO"

  # --- firecrawl is OPTIONAL in bootstrap.ps1 too ---
  # $cliMin must not list firecrawl; -Check exits 0 with firecrawl absent.
  PS137_SRC="$(cat "$PS1")"
  assert_not_contains "bootstrap.ps1 \$cliMin does not list firecrawl" \
    "$PS137_SRC" 'firecrawl = "presence"'
  PS137_STUBS="$(mktemp -d)"
  make_stub_cli "$PS137_STUBS" codex "codex 0.132.0"
  make_stub_cli "$PS137_STUBS" jq    "jq-1.7.0"
  make_stub_cli "$PS137_STUBS" rg    "ripgrep 14.0.0"
  printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 2.50.0"; exit 0; fi\necho "Logged in"; exit 0\n' \
    > "$PS137_STUBS/gh"; chmod +x "$PS137_STUBS/gh"
  ps137_check=0
  PATH="$PS137_STUBS" "$PWSH_BIN" -File "$PS1" -Check 2>/dev/null || ps137_check=$?
  assert_eq "bootstrap.ps1 -Check exits 0 with firecrawl absent" "0" "$ps137_check"
  rm -rf "$PS137_STUBS"

  rm -rf "$PS_STUBS" "$PS_HOME" "$PS_DRY_REPO"
else
  _skip "bootstrap.ps1 tests" "pwsh not available on this machine"
  _skip "bootstrap.ps1 -Check exits 0 without bash on PATH" "pwsh not available on this machine"
  _skip "bootstrap.ps1 has no 'bash =' entry in cliMin" "pwsh not available on this machine"
  _skip "bootstrap.ps1 has no '& bash ' shell-out" "pwsh not available on this machine"
  _skip "bootstrap.ps1 -DryRun routes install through pwsh" "pwsh not available on this machine"
  _skip "bootstrap.ps1 -DryRun does NOT shell out to bash install.sh" "pwsh not available on this machine"
  _skip "bootstrap.ps1 first-run (flag) exits 0" "pwsh not available on this machine"
  _skip "bootstrap.ps1 first-run produced the entrypoint" "pwsh not available on this machine"
  _skip "bootstrap.ps1 seeded local.env carries the config dir" "pwsh not available on this machine"
  _skip "bootstrap.ps1 \$cliMin does not list firecrawl" "pwsh not available on this machine"
  _skip "bootstrap.ps1 -Check exits 0 with firecrawl absent" "pwsh not available on this machine"
fi

# --- CLAUDE_CONFIG_DIR persisted after a fresh seed (no --claude-config-dir) ---
# Regression: set_config_dir_env must run AFTER local.env is seeded + reloaded,
# so a value that only exists in the seeded local.env still reaches ~/.zshenv.
PSEED_HOME="$(mktemp -d)"
PSEED_STUBS="$(mktemp -d)"
PSEED_REPO="$(mktemp -d)"
cp -R "$REPO_ROOT/." "$PSEED_REPO/"; rm -rf "$PSEED_REPO/.git" "$PSEED_REPO/local.env"
make_stub_cli "$PSEED_STUBS" codex "codex 0.132.0"
make_stub_cli "$PSEED_STUBS" firecrawl "firecrawl 1.0.0"
make_stub_cli "$PSEED_STUBS" jq    "jq-1.7.0"
make_stub_cli "$PSEED_STUBS" rg    "ripgrep 14.0.0"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 2.50.0"; exit 0; fi\necho "Logged in"; exit 0\n' \
  > "$PSEED_STUBS/gh"; chmod +x "$PSEED_STUBS/gh"
PSEED_CFG="$PSEED_HOME/cfg"
printf '#!/bin/sh\nmkdir -p "%s" && echo stub > "%s/CLAUDE.md"; exit 0\n' \
  "$PSEED_CFG" "$PSEED_CFG" > "$PSEED_REPO/scripts/install.sh"; chmod +x "$PSEED_REPO/scripts/install.sh"
printf '#!/bin/sh\nexit 0\n' > "$PSEED_REPO/scripts/validate.sh"; chmod +x "$PSEED_REPO/scripts/validate.sh"
# Doctor the template so the seeded local.env carries a real CLAUDE_CONFIG_DIR.
printf 'CLAUDE_CONFIG_DIR=%s\n' "$PSEED_CFG" > "$PSEED_REPO/templates/local.env.example"
env -u CLAUDE_CONFIG_DIR -u OBSIDIAN_VAULT_PATH -u CODEX_HOME \
  HOME="$PSEED_HOME" PATH="$PSEED_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$PSEED_REPO/scripts/bootstrap.sh" >/dev/null 2>&1 || true
assert_file "fresh seed persists CLAUDE_CONFIG_DIR to ~/.zshenv" "$PSEED_HOME/.zshenv"
assert_contains "seeded ~/.zshenv carries the config dir" \
  "$(cat "$PSEED_HOME/.zshenv" 2>/dev/null)" "$PSEED_CFG"
rm -rf "$PSEED_HOME" "$PSEED_STUBS" "$PSEED_REPO" 2>/dev/null || true

# --- T-90C: bootstrap.sh --check parity ---
# After, bootstrap.sh --check must NOT hard-fail on missing operator
# tools (lineark, codegraph, superpowers, agy). The only TRUE framework-required
# CLIs are codex, gh, jq, rg. Missing-tool warnings are advisory, not errors.
# Runtime-construct the tool sentinels per [[feedback_self_tripping_test_source]].
T90C_LINEARK="line""ark"
T90C_CODEGRAPH="code""graph"
T90C_SUPERPOWERS="super""powers"
T90C_AGY="a""gy"

T90C_TMP="$(mktemp -d)"
PARITY_STUBS="$T90C_TMP/parity-stubs"
mkdir -p "$PARITY_STUBS"
# Frame stubs for the true-required four.
make_stub_cli "$PARITY_STUBS" codex "codex 0.132.0"
make_stub_cli "$PARITY_STUBS" gh    "gh version 2.50.0 (2026-01-01)"
make_stub_cli "$PARITY_STUBS" jq    "jq-1.7.0"
make_stub_cli "$PARITY_STUBS" rg    "ripgrep 14.0.0"

# Run --check with minimal PATH + just the true-required stubs. Operator
# tools (lineark/codegraph/agy/superpowers) are absent.
parity_out="$(PATH="$PARITY_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$REPO_ROOT/scripts/bootstrap.sh" --check 2>&1 || true)"

# Expect zero FAIL/ERROR lines naming the absent operator tools. WARN lines
# are OK (advisory). The check_clis function uses "warn"/"WARNING:" for missing,
# but we strictly assert no fatal error tone.
for absent in "$T90C_LINEARK" "$T90C_CODEGRAPH" "$T90C_SUPERPOWERS" "$T90C_AGY"; do
  if printf '%s' "$parity_out" | grep -qiE "(FAIL|ERROR)[^:]*:?[^:]*$absent"; then
    _fail "bootstrap.sh --check hard-fails on absent operator tool: $absent" \
      "expected WARN (advisory) or no mention"
  else
    _pass "bootstrap.sh --check does not hard-fail on absent $absent"
  fi
done

rm -rf "$T90C_TMP" 2>/dev/null || true

# --- first-run seed-empty install must succeed (bash) ---
# Regression: a fresh clone with NO pre-existing local.env, run as
# bootstrap.sh --claude-config-dir <dir> </dev/null
# must install successfully. The pre-fix bug: seed_local_env copies the REAL
# template (CLAUDE_CONFIG_DIR= / OBSIDIAN_VAULT_PATH= are EMPTY), the reload
# re-sources those empty lines clobbering the flag value, and run_install calls
# install.sh without enough context — install.sh then dies on the empty-value
# gate and the build produces nothing.
#
# These tests deliberately use the REAL templates/local.env.example (empty
# values) — the prior end-to-end test pre-filled or doctored local.env, which is
# exactly why this path stayed untested. The stub install.sh below RE-SOURCES the
# seeded local.env and fails (exit 90) if CLAUDE_CONFIG_DIR / OBSIDIAN_VAULT_PATH
# do not resolve — mirroring real install.sh:90 so the test genuinely guards the
# regression rather than rubber-stamping a no-op stub.
q133_make_repro() {  # <repo-dir> — populate a fresh repo copy w/ guarded stubs
  local repo="$1"
  cp -R "$REPO_ROOT/." "$repo/"; rm -rf "$repo/.git" "$repo/local.env"
  # Guarded stub install.sh: re-source the seeded local.env and FAIL like the
  # real install.sh:90 if the build target / vault are not resolvable. On
  # success, create the entrypoint in CLAUDE_CONFIG_DIR.
  cat > "$repo/scripts/install.sh" <<'STUB'
#!/bin/sh
set -eu
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --harness) shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    *)         shift ;;
  esac
done
# Mirror install.sh: source local.env, then resolve the target (--out wins).
. "$(dirname "$0")/../local.env" 2>/dev/null || true
TARGET="${OUT:-${CLAUDE_CONFIG_DIR:-}}"
[ -n "$TARGET" ] || { echo "install.sh: CLAUDE_CONFIG_DIR is not set (or pass --out)" >&2; exit 90; }
[ -n "${OBSIDIAN_VAULT_PATH:-}" ] || { echo "install.sh: OBSIDIAN_VAULT_PATH resolves empty" >&2; exit 90; }
mkdir -p "$TARGET" && echo stub > "$TARGET/CLAUDE.md"
exit 0
STUB
  chmod +x "$repo/scripts/install.sh"
  printf '#!/bin/sh\nexit 0\n' > "$repo/scripts/validate.sh"; chmod +x "$repo/scripts/validate.sh"
}

q133_stubs() {  # <stub-dir> — the true-required four (no firecrawl)
  make_stub_cli "$1" codex "codex 0.132.0"
  make_stub_cli "$1" jq    "jq-1.7.0"
  make_stub_cli "$1" rg    "ripgrep 14.0.0"
  printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 2.50.0"; exit 0; fi\necho "Logged in"; exit 0\n' \
    > "$1/gh"; chmod +x "$1/gh"
}

# Case 1: value supplied via --claude-config-dir flag (no firecrawl on PATH).
Q133F_HOME="$(mktemp -d)"; Q133F_STUBS="$(mktemp -d)"; Q133F_REPO="$(mktemp -d)"
q133_make_repro "$Q133F_REPO"; q133_stubs "$Q133F_STUBS"
Q133F_CFG="$Q133F_HOME/cfg"
q133f_exit=0
env -u CLAUDE_CONFIG_DIR -u OBSIDIAN_VAULT_PATH -u CODEX_HOME \
  HOME="$Q133F_HOME" PATH="$Q133F_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" FIRECRAWL_API_KEY="k" \
  bash "$Q133F_REPO/scripts/bootstrap.sh" --claude-config-dir "$Q133F_CFG" --vault-dir /tmp/q133-vault \
  </dev/null >/dev/null 2>&1 || q133f_exit=$?
assert_eq "first-run (flag) bootstrap exits 0" "0" "$q133f_exit"
assert_file "first-run (flag) produced the entrypoint" "$Q133F_CFG/CLAUDE.md"
assert_contains "first-run (flag) seeded local.env carries the config dir" \
  "$(cat "$Q133F_REPO/local.env" 2>/dev/null)" "$Q133F_CFG"
rm -rf "$Q133F_HOME" "$Q133F_STUBS" "$Q133F_REPO" 2>/dev/null || true

# Case 2: value supplied via the ENVIRONMENT (no flag). Guards the env-clobber
# half of the bug — a --out passthrough alone would not fix this path because
# the empty reload would still wipe an env-inherited OBSIDIAN_VAULT_PATH.
Q133E_HOME="$(mktemp -d)"; Q133E_STUBS="$(mktemp -d)"; Q133E_REPO="$(mktemp -d)"
q133_make_repro "$Q133E_REPO"; q133_stubs "$Q133E_STUBS"
Q133E_CFG="$Q133E_HOME/cfg"
q133e_exit=0
env -u CODEX_HOME \
  HOME="$Q133E_HOME" PATH="$Q133E_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" FIRECRAWL_API_KEY="k" \
  CLAUDE_CONFIG_DIR="$Q133E_CFG" OBSIDIAN_VAULT_PATH="/tmp/q133-vault" \
  bash "$Q133E_REPO/scripts/bootstrap.sh" </dev/null >/dev/null 2>&1 || q133e_exit=$?
assert_eq "first-run (env) bootstrap exits 0" "0" "$q133e_exit"
assert_file "first-run (env) produced the entrypoint" "$Q133E_CFG/CLAUDE.md"
rm -rf "$Q133E_HOME" "$Q133E_STUBS" "$Q133E_REPO" 2>/dev/null || true

# --- firecrawl is OPTIONAL, not required ---
# bootstrap.sh --check must exit 0 with the four required CLIs present and
# firecrawl ABSENT from PATH. firecrawl powers the advisory firecrawl skill; its
# key is checked non-fatally in check_auth. Keeps the bootstrap loop in lockstep
# with the entrypoint prose (codex, gh, jq, rg).
Q137_STUBS="$(mktemp -d)"
q133_stubs "$Q137_STUBS"   # codex, gh, jq, rg — NO firecrawl
q137_check=0
PATH="$Q137_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$REPO_ROOT/scripts/bootstrap.sh" --check >/dev/null 2>&1 || q137_check=$?
assert_eq "--check exits 0 with firecrawl absent (firecrawl is optional)" "0" "$q137_check"
# And the required-loop warning set must NOT name firecrawl when it is missing.
q137_out="$(PATH="$Q137_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$REPO_ROOT/scripts/bootstrap.sh" --check 2>&1 || true)"
assert_not_contains "--check does not flag firecrawl as required (not found)" \
  "$q137_out" "firecrawl: not found (required)"
rm -rf "$Q137_STUBS" 2>/dev/null || true

