#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tiering: install-heavy — runs bootstrap.sh / install.sh ~28× across
# fresh-clone + re-render cases. Skipped by `make test-fast`.
# test-tier: slow
# tests/bootstrap.test.sh — bootstrap.sh acceptance tests.

BS="$REPO_ROOT/scripts/bootstrap.sh"

# --help exits 0
assert_exit "bootstrap.sh --help exits 0" 0 -- bash "$BS" --help

# Unknown arg exits 2
assert_exit "bootstrap.sh unknown arg exits 2" 2 -- bash "$BS" --bogus-flag

# --- <TEAM>-260: unknown harness names are rejected up front (in --check too) ---
# Pre-fix, `--harness <typo> --check` exited 0 — an unknown name only suppressed
# the codex CLI requirement in check_clis, and only a real run died, deep in
# install.sh. validate_harnesses now rejects unknown names in every mode,
# mirroring install.sh's pre-mutation harness-name check.
assert_exit "bootstrap.sh --harness typo --check rejects unknown harness" 1 -- \
  bash "$BS" --harness typo --check
assert_exit "bootstrap.sh --harness typo (real run) rejects unknown harness" 1 -- \
  bash "$BS" --harness typo
bs_badharness_out="$(bash "$BS" --harness typo --check 2>&1 || true)"
assert_contains "bootstrap.sh unknown-harness error lists the known set" \
  "$bs_badharness_out" "claude, codex"
# A substring of a known name (codex2) is still unknown — exact membership, not
# substring. Replaces the old check_clis substring test below: codex2 no longer
# reaches check_clis because validate_harnesses rejects it first.
assert_exit "bootstrap.sh --harness codex2 (substring of a known name) rejected as unknown" 1 -- \
  bash "$BS" --harness codex2 --check

# --- hermes is first-class in bootstrap (harness handling + --hermes-home) ---
# F1d: --help advertises the hermes harness + the --hermes-home override.
bs_help_out="$(bash "$BS" --help 2>&1 || true)"
assert_contains "bootstrap.sh --help lists hermes as a target harness" \
  "$bs_help_out" "claude, codex, hermes"
assert_contains "bootstrap.sh --help documents --hermes-home" \
  "$bs_help_out" "--hermes-home"
# The unknown-harness message now names hermes in the known set too.
assert_contains "bootstrap.sh unknown-harness error names hermes in the known set" \
  "$bs_badharness_out" "hermes"
# F1a + first-class: a capital `Hermes` is a KNOWN harness (lowercased on
# accumulation), so validate_harnesses must NOT reject it as unknown. (Exit code
# then reflects only the CLI check, which is environment-dependent — so assert on
# the absence of the rejection message, not the exit code.)
bs_hermes_out="$(bash "$BS" --harness Hermes --check 2>&1 || true)"
assert_not_contains "bootstrap.sh --harness Hermes (capital) is not rejected as unknown" \
  "$bs_hermes_out" "unknown harness"
# F1c: --hermes-home is a recognized flag, not an 'unknown argument' (exit 2).
# Assert on the absence of the unknown-arg message rather than the exit code,
# which depends on whether gh/jq/rg are present on the runner.
bs_hh_out="$(bash "$BS" --hermes-home "$(mktemp -d)" --check 2>&1 || true)"
assert_not_contains "bootstrap.sh --hermes-home <dir> is a recognized flag (not unknown arg)" \
  "$bs_hh_out" "unknown argument"

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

# F6 (<TEAM>-295) version-floor parity: a tool reporting a 2-segment version EQUAL
# to a 3-segment floor must PASS — bash version_ge pads the missing segment with
# 0 (2.40 == 2.40.0). This is the boundary the PS twin's old [System.Version]
# path got wrong (unspecified Build = -1 made "2.40" sort below "2.40.0"); bash
# has always handled it. Pin it so both twins share one contract.
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 2.40"; exit 0; fi\necho "Logged in"; exit 0\n' \
  > "$BS_STUBS/gh"; chmod +x "$BS_STUBS/gh"   # gh floor is 2.40.0
bs_seg_ok=0
PATH="$BS_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO_ROOT/scripts/bootstrap.sh" --check >/dev/null 2>&1 \
  || bs_seg_ok=$?
assert_eq "bootstrap --check accepts a 2-segment version equal to a 3-segment floor (version_ge parity)" "0" "$bs_seg_ok"

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
copy_repo_tracked "$BS_REPO2"
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
copy_repo_tracked "$E2E_REPO"

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

# --- <TEAM>-297: co-located-by-default resolution (bootstrap.sh) ---
# Fresh clone, NO local.env, clean env -> claude+codex targets default to
# gitignored dot-dirs UNDER THE REPO; --scattered opts out to the home dir; an
# explicit --claude-config-dir still wins. Asserted via the --dry-run install
# --out lines (install.sh is never actually invoked in --dry-run). validate.sh is
# stubbed so smoke_test stays fast and quiet.
CL_REPO="$(mktemp -d)"; CL_HOME="$(mktemp -d)"
copy_repo_tracked "$CL_REPO"
printf '#!/bin/sh\nexit 0\n' > "$CL_REPO/scripts/validate.sh"; chmod +x "$CL_REPO/scripts/validate.sh"
CL_UNSET="env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u AI_CONFIG_DIR -u HERMES_HOME -u OBSIDIAN_VAULT_PATH"

cl_default="$($CL_UNSET HOME="$CL_HOME" bash "$CL_REPO/scripts/bootstrap.sh" \
  --harness claude --harness codex --dry-run 2>&1 || true)"
assert_contains "co-located default: claude target is <repo>/.claude" \
  "$cl_default" "install.sh --harness claude --out $CL_REPO/.claude"
assert_contains "co-located default: codex target is <repo>/.codex" \
  "$cl_default" "install.sh --harness codex --out $CL_REPO/.codex"

cl_scatter="$($CL_UNSET HOME="$CL_HOME" bash "$CL_REPO/scripts/bootstrap.sh" \
  --harness claude --harness codex --dry-run --scattered 2>&1 || true)"
assert_contains "--scattered: claude target is ~/.claude" \
  "$cl_scatter" "install.sh --harness claude --out $CL_HOME/.claude"
assert_contains "--scattered: codex target is ~/.codex" \
  "$cl_scatter" "install.sh --harness codex --out $CL_HOME/.codex"

cl_explicit="$($CL_UNSET HOME="$CL_HOME" bash "$CL_REPO/scripts/bootstrap.sh" \
  --harness claude --dry-run --claude-config-dir /tmp/cl-explicit 2>&1 || true)"
assert_contains "explicit --claude-config-dir wins over co-located default" \
  "$cl_explicit" "install.sh --harness claude --out /tmp/cl-explicit"
assert_not_contains "explicit run does not co-locate claude under the repo" \
  "$cl_explicit" "--out $CL_REPO/.claude"
rm -rf "$CL_REPO" "$CL_HOME" 2>/dev/null || true

# --- <TEAM>-297: co-located value-flow edge cases (cross-model panel) ---
# Guards the resolve_config_targets fixes: (A) a --dry-run with an EXISTING local.env
# whose values are empty must still preview co-located targets (the reload re-empties;
# the post-reload re-resolve re-fills); (B) --scattered un-does a prior co-located
# DEFAULT in local.env but (B2) preserves an operator-AUTHORED custom path; and the
# co-located default survives a repo path that contains a space.
CLE_HOME="$(mktemp -d)"
cle_setup() {  # <repo> — hermetic tracked-only repo copy (no .git/local.env), stub validate.sh (fast/quiet)
  copy_repo_tracked "$1"
  printf '#!/bin/sh\nexit 0\n' > "$1/scripts/validate.sh"; chmod +x "$1/scripts/validate.sh"
}
cle_run() {  # <repo> <expect-substr> <label> [extra bootstrap flags...]
  local repo="$1" want="$2" label="$3"; shift 3
  local out
  out="$(env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u AI_CONFIG_DIR -u HERMES_HOME -u OBSIDIAN_VAULT_PATH \
    HOME="$CLE_HOME" bash "$repo/scripts/bootstrap.sh" --dry-run "$@" 2>&1 || true)"
  assert_contains "$label" "$out" "$want"
}
# (A) existing local.env with EMPTY values + --dry-run -> co-located preview.
CLE_A="$(mktemp -d)"; cle_setup "$CLE_A"
printf 'CLAUDE_CONFIG_DIR=\nCODEX_HOME=\nOBSIDIAN_VAULT_PATH=\n' > "$CLE_A/local.env"
cle_run "$CLE_A" "install.sh --harness claude --out $CLE_A/.claude" \
  "co-located: --dry-run with an existing empty local.env still previews co-located" --harness claude
rm -rf "$CLE_A"
# (B) prior co-located DEFAULT in local.env + --scattered -> home (un-done).
CLE_B="$(mktemp -d)"; cle_setup "$CLE_B"
printf 'CLAUDE_CONFIG_DIR=%s/.claude\nOBSIDIAN_VAULT_PATH=\n' "$CLE_B" > "$CLE_B/local.env"
cle_run "$CLE_B" "install.sh --harness claude --out $CLE_HOME/.claude" \
  "--scattered un-does a prior co-located default in local.env" --harness claude --scattered
rm -rf "$CLE_B"
# (B2) operator-AUTHORED custom path + --scattered -> preserved (NOT clobbered).
CLE_B2="$(mktemp -d)"; cle_setup "$CLE_B2"
printf 'CLAUDE_CONFIG_DIR=/custom/claude\nOBSIDIAN_VAULT_PATH=\n' > "$CLE_B2/local.env"
cle_run "$CLE_B2" "install.sh --harness claude --out /custom/claude" \
  "--scattered preserves an operator-authored custom config path" --harness claude --scattered
rm -rf "$CLE_B2"
# (spaces) co-located default resolves under a repo path containing a space.
CLE_SPP="$(mktemp -d)"; CLE_SP="$CLE_SPP/repo with space"; mkdir -p "$CLE_SP"; cle_setup "$CLE_SP"
cle_run "$CLE_SP" "install.sh --harness claude --out $CLE_SP/.claude" \
  "co-located default resolves under a repo path containing a space" --harness claude
rm -rf "$CLE_SPP"
rm -rf "$CLE_HOME" 2>/dev/null || true

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
  # Stubs feeding a pwsh invocation use the _ps twins (tests/lib.sh): on a
  # Windows host they plant natively executable .cmd stubs — an extensionless
  # sh stub would ShellExecute into a GUI "Select an app" dialog per probe and
  # read as version-unknown. POSIX hosts get the identical sh stubs as before.
  PS_STUBS="$(mktemp -d)"
  make_stub_cli_ps "$PS_STUBS" codex     "codex 0.132.0"
  make_stub_cli_ps "$PS_STUBS" firecrawl "firecrawl 1.0.0"
  make_stub_cli_ps "$PS_STUBS" jq        "jq-1.7.0"
  make_stub_cli_ps "$PS_STUBS" rg        "ripgrep 14.0.0"
  # gh stub also responds to subcommands for the auth check.
  make_stub_gh_ps "$PS_STUBS" "gh version 2.50.0"

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
  rm_stub_cli_ps "$PS_STUBS" rg
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
  make_stub_cli_ps "$PS_STUBS" rg "ripgrep 14.0.0"  # restore rg so -Check has all required CLIs

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

  # --- <TEAM>-260: bootstrap.ps1 rejects unknown harness names + honest -Harness doc ---
  # Confirm-HarnessNames rejects a typo up front (in -Check too). The -Harness doc
  # drops the wrong "repeatable" claim AND must NOT recommend `-Harness claude,codex`
  # — under the documented `pwsh -File` invocation a comma value binds as a single
  # literal (no array split) and is rejected as unknown. codex is a supported
  # Windows build target (<TEAM>-296), so -Harness codex -Check now requires the
  # codex CLI; hermes remains the Windows-deferred harness, and install.ps1 owns
  # its unsupported message on a real/dry-run install path.
  ps_badharness_exit=0
  PATH="$PS_TEST_PATH" "$PWSH_BIN" -File "$PS1" -Harness typo -Check >/dev/null 2>&1 \
    || ps_badharness_exit=$?
  assert_eq "bootstrap.ps1 -Harness typo -Check rejects unknown harness" "1" "$ps_badharness_exit"
  ps_badharness_out="$(PATH="$PS_TEST_PATH" "$PWSH_BIN" -File "$PS1" -Harness typo -Check 2>&1 || true)"
  assert_contains "bootstrap.ps1 unknown-harness error lists the known set" \
    "$ps_badharness_out" "claude, codex"
  assert_not_contains "bootstrap.ps1 -Harness doc drops the wrong 'repeatable' claim" \
    "$ps_src" "(repeatable; default: claude)"
  assert_contains "bootstrap.ps1 -Harness doc warns the comma form is pwsh -File-hostile" \
    "$ps_src" "does NOT split"
  # <TEAM>-296: codex is now a supported Windows build target, so bootstrap.ps1's
  # Invoke-CheckClis requires the codex CLI when -Harness codex is requested
  # (parity with bootstrap.sh check_clis). With codex present (stubbed), -Check passes.
  ps_codex_check_exit=0
  PATH="$PS_TEST_PATH" "$PWSH_BIN" -File "$PS1" -Harness codex -Check >/dev/null 2>&1 \
    || ps_codex_check_exit=$?
  assert_eq "bootstrap.ps1 -Harness codex -Check passes when codex present (codex now required for -Harness codex)" \
    "0" "$ps_codex_check_exit"
  # Conditional requirement: with codex ABSENT, -Harness codex -Check flags it
  # (exit 1), but -Harness claude -Check still passes (codex not required for
  # claude). Mirrors bootstrap.sh's harness-conditional codex tests.
  rm_stub_cli_ps "$PS_STUBS" codex
  ps_codex_absent_exit=0
  PATH="$PS_TEST_PATH" "$PWSH_BIN" -File "$PS1" -Harness codex -Check >/dev/null 2>&1 \
    || ps_codex_absent_exit=$?
  assert_eq "bootstrap.ps1 -Harness codex -Check flags absent codex as required" "1" "$ps_codex_absent_exit"
  ps_claude_nocodex_exit=0
  PATH="$PS_TEST_PATH" "$PWSH_BIN" -File "$PS1" -Harness claude -Check >/dev/null 2>&1 \
    || ps_claude_nocodex_exit=$?
  assert_eq "bootstrap.ps1 -Check (claude) does not require codex" "0" "$ps_claude_nocodex_exit"
  make_stub_cli_ps "$PS_STUBS" codex "codex 0.132.0"  # restore for the dry-run tests below

  # The -DryRun mode should show the install action routed through pwsh, not
  # bash. With all CLIs present, -DryRun on full mode (not just -Check) lists
  # the install step. We need to stub install.ps1 to no-op so the script
  # completes; in dry-run it doesn't actually run.
  PS_HOME="$(mktemp -d)"
  PS_DRY_REPO="$(mktemp -d)"
  copy_repo_tracked "$PS_DRY_REPO"
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
  copy_repo_tracked "$PS133_REPO"
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
  make_stub_cli_ps "$PS137_STUBS" codex "codex 0.132.0"
  make_stub_cli_ps "$PS137_STUBS" jq    "jq-1.7.0"
  make_stub_cli_ps "$PS137_STUBS" rg    "ripgrep 14.0.0"
  make_stub_gh_ps "$PS137_STUBS" "gh version 2.50.0"
  ps137_check=0
  PATH="$PS137_STUBS" "$PWSH_BIN" -File "$PS1" -Check 2>/dev/null || ps137_check=$?
  assert_eq "bootstrap.ps1 -Check exits 0 with firecrawl absent" "0" "$ps137_check"
  rm -rf "$PS137_STUBS"

  # --- F6 (<TEAM>-295): PS version compare matches bash version_ge ---
  # A 2-segment version EQUAL to a 3-segment floor must PASS. The old
  # [System.Version] path sorted "2.40" BELOW "2.40.0" (unspecified Build = -1),
  # spuriously flagging an up-to-date CLI as outdated. Stub every required CLI at
  # 2-segment == floor and assert -Check still exits 0. (A bare single-segment
  # "13" can't reach the comparator via -Check — Get-CliVersion's regex requires
  # a dot — so the stubs use the 2-segment shape the [System.Version] bug hit.)
  PS_SEG_STUBS="$(mktemp -d)"
  make_stub_cli_ps "$PS_SEG_STUBS" codex     "codex 0.132.0"
  make_stub_cli_ps "$PS_SEG_STUBS" firecrawl "firecrawl 1.0.0"
  make_stub_cli_ps "$PS_SEG_STUBS" jq        "jq-1.6"        # 2-seg == floor 1.6.0
  make_stub_cli_ps "$PS_SEG_STUBS" rg        "ripgrep 13.0"   # 2-seg == floor 13.0.0
  make_stub_gh_ps "$PS_SEG_STUBS" "gh version 2.40"   # 2-seg == floor 2.40.0
  ps_seg_check=0
  PATH="$PS_SEG_STUBS" "$PWSH_BIN" -File "$PS1" -Check 2>/dev/null || ps_seg_check=$?
  assert_eq "bootstrap.ps1 -Check accepts segment-short versions equal to their floors (F6: version_ge parity, not [System.Version])" "0" "$ps_seg_check"
  rm -rf "$PS_SEG_STUBS"

  # F6 (<TEAM>-295) cross-model Finding 3: a pathological huge version segment must
  # NOT crash -Check. Get-CliVersion's regex passes the whole numeric run to
  # Test-VersionGe, where the old [long] cast overflowed (FormatException); the
  # [double] port yields +Inf and compares cleanly. Stub gh at a >Int64 version.
  PS_HUGE_STUBS="$(mktemp -d)"
  make_stub_cli_ps "$PS_HUGE_STUBS" codex     "codex 0.132.0"
  make_stub_cli_ps "$PS_HUGE_STUBS" firecrawl "firecrawl 1.0.0"
  make_stub_cli_ps "$PS_HUGE_STUBS" jq        "jq-1.7.0"
  make_stub_cli_ps "$PS_HUGE_STUBS" rg        "ripgrep 14.0.0"
  make_stub_gh_ps "$PS_HUGE_STUBS" "gh version 999999999999999999999.0.0"
  ps_huge_check=0
  PATH="$PS_HUGE_STUBS" "$PWSH_BIN" -File "$PS1" -Check 2>/dev/null || ps_huge_check=$?
  assert_eq "bootstrap.ps1 -Check survives an oversized (>Int64) version segment (F6: [double] port, no overflow crash)" "0" "$ps_huge_check"
  rm -rf "$PS_HUGE_STUBS"

  # --- probe guard: extensionless resolution counts as ABSENT on Windows ---
  # bootstrap.ps1's Resolve-ExecutableCommand must refuse a PATH hit that pwsh
  # cannot execute natively (extensionless shebang script) instead of falling
  # through to ShellExecute (GUI "Select an app" dialog, probe reads unknown).
  # Windows-host-only: on POSIX an extensionless stub IS executable and must
  # keep working — that side is covered by every _ps stub test above.
  if stub_host_is_windows; then
    PS517_STUBS="$(mktemp -d)"
    make_stub_cli_ps "$PS517_STUBS" codex "codex 0.132.0"
    make_stub_cli_ps "$PS517_STUBS" jq    "jq-1.7.0"
    make_stub_gh_ps "$PS517_STUBS" "gh version 2.50.0"
    # rg present ONLY as an extensionless sh script — must read as absent.
    make_stub_cli "$PS517_STUBS" rg "ripgrep 14.0.0"
    ps517_out="$(PATH="$PS517_STUBS" "$PWSH_BIN" -File "$PS1" -Check 2>&1)" \
      && ps517_exit=0 || ps517_exit=$?
    assert_eq "bootstrap.ps1 -Check treats an extensionless PATH hit as absent (exit 1, no ShellExecute)" \
      "1" "$ps517_exit"
    assert_contains "bootstrap.ps1 -Check reports the extensionless CLI as not found" \
      "$ps517_out" "rg: not found"
    # Shadowing: a rejected extensionless hit must not mask a real executable
    # elsewhere in the resolution order (panel finding — resolver walks -All
    # candidates). Plant the .cmd twin BESIDE the extensionless rg; -Check
    # must now resolve rg via the .cmd and pass.
    make_stub_cli_ps "$PS517_STUBS" rg "ripgrep 14.0.0"
    ps517_shadow=0
    PATH="$PS517_STUBS" "$PWSH_BIN" -File "$PS1" -Check >/dev/null 2>&1 || ps517_shadow=$?
    assert_eq "bootstrap.ps1 -Check resolves past a rejected extensionless hit to the .cmd twin" \
      "0" "$ps517_shadow"
    rm -rf "$PS517_STUBS"
  fi

  # --- <TEAM>-297: co-located-by-default resolution (bootstrap.ps1) ---
  # Fresh clone, NO local.env, clean env -> claude+codex default to gitignored
  # dot-dirs under the repo; -Scattered opts out to the home dir. Asserted via the
  # -DryRun "setenv User <VAR>=<path>" lines. Mirrors the bash co-located block;
  # execution-verified under local pwsh.
  CLPS_REPO="$(mktemp -d)"; CLPS_HOME="$(mktemp -d)"
  copy_repo_tracked "$CLPS_REPO"
  CLPS_UNSET="env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u AI_CONFIG_DIR -u HERMES_HOME -u OBSIDIAN_VAULT_PATH"
  clps_default="$($CLPS_UNSET HOME="$CLPS_HOME" "$PWSH_BIN" -NoProfile -File \
    "$CLPS_REPO/scripts/bootstrap.ps1" -DryRun 2>&1 || true)"
  assert_contains "bootstrap.ps1 co-located: CLAUDE_CONFIG_DIR defaults to <repo>/.claude" \
    "$clps_default" "setenv User CLAUDE_CONFIG_DIR=$CLPS_REPO/.claude"
  assert_contains "bootstrap.ps1 co-located: CODEX_HOME defaults to <repo>/.codex" \
    "$clps_default" "setenv User CODEX_HOME=$CLPS_REPO/.codex"
  clps_scatter="$($CLPS_UNSET HOME="$CLPS_HOME" "$PWSH_BIN" -NoProfile -File \
    "$CLPS_REPO/scripts/bootstrap.ps1" -DryRun -Scattered 2>&1 || true)"
  assert_contains "bootstrap.ps1 -Scattered: targets resolve under the home dir" \
    "$clps_scatter" "setenv User CLAUDE_CONFIG_DIR=$CLPS_HOME/.claude"
  rm -rf "$CLPS_REPO" "$CLPS_HOME" 2>/dev/null || true

  # --- <TEAM>-297: co-located value-flow edge cases (cross-model panel), PS twin ---
  CLEP_HOME="$(mktemp -d)"
  clep_setup() { copy_repo_tracked "$1"; }
  clep_run() {  # <repo> <expect-substr> <label> [extra -flags...]
    local repo="$1" want="$2" label="$3"; shift 3
    local out
    out="$(env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u AI_CONFIG_DIR -u HERMES_HOME -u OBSIDIAN_VAULT_PATH \
      HOME="$CLEP_HOME" "$PWSH_BIN" -NoProfile -File "$repo/scripts/bootstrap.ps1" -DryRun "$@" 2>&1 || true)"
    assert_contains "$label" "$out" "$want"
  }
  # (A) existing empty local.env + -DryRun -> co-located.
  CLEP_A="$(mktemp -d)"; clep_setup "$CLEP_A"
  printf 'CLAUDE_CONFIG_DIR=\nCODEX_HOME=\nOBSIDIAN_VAULT_PATH=\n' > "$CLEP_A/local.env"
  clep_run "$CLEP_A" "setenv User CLAUDE_CONFIG_DIR=$CLEP_A/.claude" \
    "bootstrap.ps1 co-located: -DryRun with an existing empty local.env still resolves co-located"
  rm -rf "$CLEP_A"
  # (B) prior co-located default + -Scattered -> home.
  CLEP_B="$(mktemp -d)"; clep_setup "$CLEP_B"
  printf 'CLAUDE_CONFIG_DIR=%s/.claude\nOBSIDIAN_VAULT_PATH=\n' "$CLEP_B" > "$CLEP_B/local.env"
  clep_run "$CLEP_B" "setenv User CLAUDE_CONFIG_DIR=$CLEP_HOME/.claude" \
    "bootstrap.ps1 -Scattered un-does a prior co-located default in local.env" -Scattered
  rm -rf "$CLEP_B"
  # (spaces) co-located resolves under a repo path with a space.
  CLEP_SPP="$(mktemp -d)"; CLEP_SP="$CLEP_SPP/repo with space"; mkdir -p "$CLEP_SP"; clep_setup "$CLEP_SP"
  clep_run "$CLEP_SP" "setenv User CLAUDE_CONFIG_DIR=$CLEP_SP/.claude" \
    "bootstrap.ps1 co-located resolves under a repo path containing a space"
  rm -rf "$CLEP_SPP"
  rm -rf "$CLEP_HOME" 2>/dev/null || true

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
  _skip "bootstrap.ps1 -Harness typo -Check rejects unknown harness" "pwsh not available on this machine"
  _skip "bootstrap.ps1 unknown-harness error lists the known set" "pwsh not available on this machine"
  _skip "bootstrap.ps1 -Harness doc drops the wrong 'repeatable' claim" "pwsh not available on this machine"
  _skip "bootstrap.ps1 -Harness doc warns the comma form is pwsh -File-hostile" "pwsh not available on this machine"
  _skip "bootstrap.ps1 -Harness codex -Check passes (known; Windows-unsupported deferred to install.ps1)" "pwsh not available on this machine"
  _skip "bootstrap.ps1 -Check accepts segment-short versions equal to their floors (F6: version_ge parity, not [System.Version])" "pwsh not available on this machine"
  _skip "bootstrap.ps1 -Check survives an oversized (>Int64) version segment (F6: [double] port, no overflow crash)" "pwsh not available on this machine"
  _skip "bootstrap.ps1 co-located: CLAUDE_CONFIG_DIR defaults to <repo>/.claude" "pwsh not available on this machine"
  _skip "bootstrap.ps1 co-located: CODEX_HOME defaults to <repo>/.codex" "pwsh not available on this machine"
  _skip "bootstrap.ps1 -Scattered: targets resolve under the home dir" "pwsh not available on this machine"
  _skip "bootstrap.ps1 co-located: -DryRun with an existing empty local.env still resolves co-located" "pwsh not available on this machine"
  _skip "bootstrap.ps1 -Scattered un-does a prior co-located default in local.env" "pwsh not available on this machine"
  _skip "bootstrap.ps1 co-located resolves under a repo path containing a space" "pwsh not available on this machine"
fi

# --- co-located default reaches ~/.zshenv on a fresh seed (<TEAM>-297) ---
# Replaces the prior doctored-template regression: with the shipped template's
# CLAUDE_CONFIG_DIR / CODEX_HOME EMPTY, a fresh bootstrap with no override now
# DEFAULTS both to gitignored dirs under the repo and exports them to ~/.zshenv.
# Still guards the seed -> persist -> reload -> export ordering — the value
# reaching ~/.zshenv now originates from the co-located default rather than a
# doctored template. (Operator-supplied values reaching ~/.zshenv stay guarded by
# the Q133E/Q133F + full end-to-end cases above.)
PSEED_HOME="$(mktemp -d)"
PSEED_STUBS="$(mktemp -d)"
PSEED_REPO="$(mktemp -d)"
copy_repo_tracked "$PSEED_REPO"
make_stub_cli "$PSEED_STUBS" codex "codex 0.132.0"
make_stub_cli "$PSEED_STUBS" firecrawl "firecrawl 1.0.0"
make_stub_cli "$PSEED_STUBS" jq    "jq-1.7.0"
make_stub_cli "$PSEED_STUBS" rg    "ripgrep 14.0.0"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 2.50.0"; exit 0; fi\necho "Logged in"; exit 0\n' \
  > "$PSEED_STUBS/gh"; chmod +x "$PSEED_STUBS/gh"
# Co-located install.sh stub: create the entrypoint at the in-repo .claude dir
# (the co-located default target run_install passes via --out).
printf '#!/bin/sh\nmkdir -p "%s/.claude" && echo stub > "%s/.claude/CLAUDE.md"; exit 0\n' \
  "$PSEED_REPO" "$PSEED_REPO" > "$PSEED_REPO/scripts/install.sh"; chmod +x "$PSEED_REPO/scripts/install.sh"
printf '#!/bin/sh\nexit 0\n' > "$PSEED_REPO/scripts/validate.sh"; chmod +x "$PSEED_REPO/scripts/validate.sh"
# No flag, no env, REAL (empty) template -> co-located default fills both vars.
env -u CLAUDE_CONFIG_DIR -u OBSIDIAN_VAULT_PATH -u CODEX_HOME -u AI_CONFIG_DIR -u HERMES_HOME \
  HOME="$PSEED_HOME" PATH="$PSEED_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$PSEED_REPO/scripts/bootstrap.sh" >/dev/null 2>&1 || true
assert_file "fresh seed persists CLAUDE_CONFIG_DIR to ~/.zshenv" "$PSEED_HOME/.zshenv"
pseed_zsh="$(cat "$PSEED_HOME/.zshenv" 2>/dev/null)"
assert_contains "seeded ~/.zshenv carries the config dir" "$pseed_zsh" "$PSEED_REPO/.claude"
assert_contains "fresh seed exports co-located CODEX_HOME to ~/.zshenv" "$pseed_zsh" "$PSEED_REPO/.codex"
rm -rf "$PSEED_HOME" "$PSEED_STUBS" "$PSEED_REPO" 2>/dev/null || true

# --- T-90C: bootstrap.sh --check parity ---
# After, bootstrap.sh --check must NOT hard-fail on missing operator
# tools (lineark, codegraph, superpowers, agy). The universal framework-required
# CLIs are gh, jq, rg (codex is required only for the codex harness). Missing-tool
# warnings are advisory, not errors.
# Runtime-construct the tool sentinels per [[feedback_self_tripping_test_source]].
T90C_LINEARK="line""ark"
T90C_CODEGRAPH="code""graph"
T90C_SUPERPOWERS="super""powers"
T90C_AGY="a""gy"

T90C_TMP="$(mktemp -d)"
PARITY_STUBS="$T90C_TMP/parity-stubs"
mkdir -p "$PARITY_STUBS"
# Frame stubs for gh/jq/rg (+ codex; harmless here — codex is not required for
# the default claude --check, but its presence does not hurt this parity check).
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

# --- T-90D: codex is harness-conditional, not universally required ---
# Regression for the codex-required-for-claude fix: a claude-only bootstrap (the
# default) must pass --check with the codex CLI ABSENT; only --harness codex
# requires it. gh/jq/rg stay universally required.
T90D_TMP="$(mktemp -d)"
T90D_STUBS="$T90D_TMP/stubs"
mkdir -p "$T90D_STUBS"
# Stub only the universal three — codex is deliberately absent.
make_stub_cli "$T90D_STUBS" gh "gh version 2.50.0 (2026-01-01)"
make_stub_cli "$T90D_STUBS" jq "jq-1.7.0"
make_stub_cli "$T90D_STUBS" rg "ripgrep 14.0.0"

# Default harness (claude): codex absent must NOT be flagged as a missing requirement.
t90d_claude_out="$(PATH="$T90D_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$REPO_ROOT/scripts/bootstrap.sh" --check 2>&1 || true)"
if printf '%s' "$t90d_claude_out" | grep -qiE "codex: not found"; then
  _fail "bootstrap.sh --check (claude) requires codex" \
    "codex must not be required for the claude harness"
else
  _pass "bootstrap.sh --check (claude) does not require codex"
fi

# Codex harness: codex absent MUST be flagged as a missing requirement.
t90d_codex_out="$(PATH="$T90D_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$REPO_ROOT/scripts/bootstrap.sh" --harness codex --check 2>&1 || true)"
if printf '%s' "$t90d_codex_out" | grep -qiE "codex: not found"; then
  _pass "bootstrap.sh --check --harness codex flags absent codex as required"
else
  _fail "bootstrap.sh --check --harness codex did not flag absent codex" \
    "codex is required when the codex harness is targeted"
fi

# Case-folded: install.sh lowercases harness names, so --harness CODEX is the
# codex harness and MUST require codex.
t90d_upper_out="$(PATH="$T90D_STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$REPO_ROOT/scripts/bootstrap.sh" --harness CODEX --check 2>&1 || true)"
if printf '%s' "$t90d_upper_out" | grep -qiE "codex: not found"; then
  _pass "bootstrap.sh --check --harness CODEX (case-folded) flags absent codex"
else
  _fail "bootstrap.sh --check --harness CODEX did not flag absent codex" \
    "harness match must be case-insensitive (install.sh lowercases harness names)"
fi

# NOTE: the codex-substring case (e.g. `--harness codex2` must not pull the codex
# requirement) is now covered up front by validate_harnesses — codex2 is rejected
# as an unknown harness before check_clis runs. See the <TEAM>-260 block near the top
# of this file ("substring of a known name ... rejected as unknown").

rm -rf "$T90D_TMP" 2>/dev/null || true

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
  copy_repo_tracked "$repo"
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

