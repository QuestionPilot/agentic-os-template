#!/usr/bin/env bash
# tests/space-in-path.test.sh
#
# <TEAM>-298 #3 — space-in-path robustness. The operator's OBSIDIAN_VAULT_PATH
# contains a space, and after the co-location default (<TEAM>-297) CLAUDE_CONFIG_DIR
# can sit under a spaced repo path ("Agentic OS") too. Shared scripts must quote
# every spaced-path var so they neither word-split nor glob. mktemp gives
# no-space dirs, so the rest of the suite never exercises this — this file drives
# install.sh, --dry-run, and self-audit from paths that DO contain a space, end
# to end. A single unquoted "$TARGET" / "$VAULT_DIR" would fail one of these.

SP_ROOT="$(mktemp -d)"
SP_TGT="$SP_ROOT/config dir"       # space in the config dir (co-located case)
SP_VAULT="$SP_ROOT/my vault"       # space in the vault path (operator's real case)
mkdir -p "$SP_TGT" "$SP_VAULT"
SP_ENV="$SP_ROOT/local.env"
make_local_env "$SP_ENV" "$SP_TGT" "$SP_VAULT"

# install.sh must build into a spaced config dir without word-splitting.
sp_install=0
AI_CONFIG_LOCAL_ENV="$SP_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1 || sp_install=$?
assert_eq "install.sh builds into a config dir containing a space" "0" "$sp_install"
assert_file "install produced CLAUDE.md in the spaced config dir" "$SP_TGT/CLAUDE.md"
assert_file "install produced a spine skill in the spaced config dir" "$SP_TGT/skills/closeout/SKILL.md"

# --dry-run must classify a spaced target correctly (in sync right after install).
sp_dry="$(AI_CONFIG_LOCAL_ENV="$SP_ENV" bash "$REPO_ROOT/scripts/install.sh" --dry-run 2>/dev/null || true)"
assert_contains "--dry-run handles a spaced config dir (reports in sync)" \
  "$sp_dry" "in sync with the current framework"

# self-audit with a spaced --vault-dir must carry the path through intact: plant a
# .git in the spaced vault and confirm the Drive-git guard still fires on it (proves
# the spaced path reached the check whole, not split into "my" + "vault").
mkdir -p "$SP_VAULT/.git"
sp_audit="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$REPO_ROOT" --vault-dir "$SP_VAULT" --json 2>/dev/null || true)"
assert_contains "self-audit Drive-git guard fires on a spaced vault path" \
  "$sp_audit" "Live .git inside the sync-hosted vault"

# Sanity: a re-install over the spaced target is still idempotent (exit 0).
sp_reinstall=0
AI_CONFIG_LOCAL_ENV="$SP_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1 || sp_reinstall=$?
assert_eq "re-install over a spaced config dir stays idempotent" "0" "$sp_reinstall"

rm -rf "$SP_ROOT"
