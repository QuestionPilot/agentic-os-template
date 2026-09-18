#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/install-lock-race.test.sh
#
# Race regression for the installer ownership lock. The worker A fixture pauses
# immediately after it moved a live skill into its private backup root. Worker B
# addresses the same physical target through a symlink alias. The old installer
# let B consume A's backup; the candidate must refuse B before B touches recovery,
# backup, or swap state.

LR_DIR="$(mktemp -d)"
LR_TARGET="$LR_DIR/target"
LR_ALIAS="$LR_DIR/target-alias"
LR_A_REPO="$LR_DIR/a-repo"
LR_B_REPO="$LR_DIR/b-repo"
LR_A_ENV="$LR_DIR/a.local.env"
LR_B_ENV="$LR_DIR/b.local.env"
LR_BARRIER="$LR_DIR/barrier"
LR_A_PID=""
cleanup_install_lock_race() {
  trap - RETURN
  [ -n "$LR_A_PID" ] && touch "$LR_BARRIER/release" 2>/dev/null || true
  [ -n "$LR_A_PID" ] && kill "$LR_A_PID" 2>/dev/null || true
  [ -n "$LR_A_PID" ] && wait "$LR_A_PID" 2>/dev/null || true
  rm -rf "$LR_DIR"
}
trap cleanup_install_lock_race RETURN
assert_absent_lock_race() {
  if [ ! -e "$2" ]; then _pass "$1"; else _fail "$1" "path still exists: $2"; fi
}
assert_dir_lock_race() {
  if [ -d "$2" ]; then _pass "$1"; else _fail "$1" "directory not found: $2"; fi
}
lock_mode_install_race() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

mkdir -p "$LR_TARGET" "$LR_BARRIER"
ln -s "$LR_TARGET" "$LR_ALIAS"
copy_repo_tracked "$LR_A_REPO"
copy_repo_tracked "$LR_B_REPO"
make_local_env "$LR_A_ENV" "$LR_TARGET" "$LR_DIR/vault"
make_local_env "$LR_B_ENV" "$LR_ALIAS" "$LR_DIR/vault"

# Distinguishable sources make a successful B swap observable. Only the copied
# A installer is instrumented; production code has no race-test pause hook.
printf '\n<!-- INSTALL-LOCK-RACE-A -->\n' >> "$LR_A_REPO/capabilities/closeout.md"
printf '\n<!-- INSTALL-LOCK-RACE-B -->\n' >> "$LR_B_REPO/capabilities/closeout.md"
LR_A_INSTALL_TMP="$LR_A_REPO/scripts/install.sh.race-tmp"
if ! awk '
  BEGIN { anchor = "        mv \"$TARGET/$name/$base\" \"$bak_root/$name/$base\" || return 1" }
  $0 == anchor {
    seen++
    print
    print "        if [ \"$name/$base\" = \"skills/closeout\" ]; then"
    print "          : > \"$RACE_INSTALL_LOCK_BARRIER/backup-ready\""
    print "          while [ ! -e \"$RACE_INSTALL_LOCK_BARRIER/release\" ]; do sleep 0.02; done"
    print "        fi"
    next
  }
  { print }
  END { if (seen != 1) exit 70 }
' "$LR_A_REPO/scripts/install.sh" > "$LR_A_INSTALL_TMP"; then
  _fail "install lock race: copied installer has one backup anchor" "could not inject explicit race barrier"
  return
fi
mv "$LR_A_INSTALL_TMP" "$LR_A_REPO/scripts/install.sh"

# Positive single-writer baseline supplies content for A to back up.
assert_exit "install lock race: single-writer baseline succeeds" 0 -- \
  env AI_CONFIG_LOCAL_ENV="$LR_A_ENV" bash "$REPO_ROOT/scripts/install.sh"

env AI_CONFIG_LOCAL_ENV="$LR_A_ENV" RACE_INSTALL_LOCK_BARRIER="$LR_BARRIER" \
  bash "$LR_A_REPO/scripts/install.sh" >"$LR_DIR/a.out" 2>"$LR_DIR/a.err" &
LR_A_PID=$!
LR_WAIT=0
while [ ! -e "$LR_BARRIER/backup-ready" ] && [ "$LR_WAIT" -lt 500 ]; do sleep 0.02; LR_WAIT=$((LR_WAIT + 1)); done
assert_file "install lock race: A pauses after owning backup" "$LR_BARRIER/backup-ready"
assert_file "install lock race: A lock exists while backup is live" "$LR_TARGET/.install-lock"
assert_eq "install lock race: Bash owner lock mode is private" "600" "$(lock_mode_install_race "$LR_TARGET/.install-lock")"
assert_file "install lock race: A backup survives while A is paused" "$LR_TARGET/.install-bak.d/skills/closeout/SKILL.md"

LR_B_OUT="$(AI_CONFIG_LOCAL_ENV="$LR_B_ENV" bash "$LR_B_REPO/scripts/install.sh" 2>&1)"; LR_B_RC=$?
assert_eq "install lock race: alias writer B refuses active owner" "1" "$LR_B_RC"
assert_contains "install lock race: B reports physical-target contention" "$LR_B_OUT" "another installer owns physical target"
assert_file "install lock race: B leaves A backup untouched" "$LR_TARGET/.install-bak.d/skills/closeout/SKILL.md"
assert_file "install lock race: B leaves A lock untouched" "$LR_TARGET/.install-lock"

# A changed owner token must survive A's cleanup. This guards against a release
# path that blindly deletes a replacement lock it does not own.
printf 'replacement owner\n' > "$LR_TARGET/.install-lock"
touch "$LR_BARRIER/release"
if wait "$LR_A_PID"; then LR_A_RC=0; else LR_A_RC=$?; fi
LR_A_PID=""
assert_eq "install lock race: A completes after release" "0" "$LR_A_RC"
assert_contains "install lock race: A output installed" "$(cat "$LR_TARGET/skills/closeout/SKILL.md")" "INSTALL-LOCK-RACE-A"
assert_absent_lock_race "install lock race: no shared backup remains after A" "$LR_TARGET/.install-bak.d"
assert_file "install lock race: changed owner token survives A cleanup" "$LR_TARGET/.install-lock"
assert_contains "install lock race: changed owner token stays intact" "$(cat "$LR_TARGET/.install-lock")" "replacement owner"
assert_absent_lock_race "install lock race: no nested closeout tree appears" "$LR_TARGET/skills/closeout/closeout"
rm -f "$LR_TARGET/.install-lock"

# The normal serial control proves the refusal did not permanently block B.
LR_SERIAL_OUT="$(AI_CONFIG_LOCAL_ENV="$LR_B_ENV" bash "$LR_B_REPO/scripts/install.sh" 2>&1)"; LR_SERIAL_RC=$?
assert_eq "install lock race: B succeeds after A released lock" "0" "$LR_SERIAL_RC"
assert_contains "install lock race: serial B output installed" "$(cat "$LR_TARGET/skills/closeout/SKILL.md")" "INSTALL-LOCK-RACE-B"
assert_absent_lock_race "install lock race: serial B leaves no lock" "$LR_TARGET/.install-lock"

# A foreign or crashed owner is never taken over automatically.
printf 'foreign owner\n' > "$LR_TARGET/.install-lock"
LR_FOREIGN_OUT="$(AI_CONFIG_LOCAL_ENV="$LR_A_ENV" bash "$LR_A_REPO/scripts/install.sh" 2>&1)"; LR_FOREIGN_RC=$?
assert_eq "install lock race: foreign or stale lock refuses manual takeover" "1" "$LR_FOREIGN_RC"
assert_file "install lock race: foreign lock remains for manual confirmation" "$LR_TARGET/.install-lock"
rm -f "$LR_TARGET/.install-lock"

# Codex's .agents mirror has its own physical lock. A mirror contention occurs
# after the main target is complete and names that partial outcome truthfully.
LR_CODEX="$LR_DIR/codex"; LR_AGENTS="$LR_DIR/agents"; LR_CODEX_ENV="$LR_DIR/codex.local.env"
mkdir -p "$LR_AGENTS/skills/closeout"
printf 'untouched mirror sentinel\n' > "$LR_AGENTS/skills/closeout/SKILL.md"
LR_AGENTS_SNAPSHOT="$LR_DIR/agents-before"
cp "$LR_AGENTS/skills/closeout/SKILL.md" "$LR_AGENTS_SNAPSHOT"
printf 'CODEX_HOME=%q\nOBSIDIAN_VAULT_PATH=%q\nAGENTS_DIR=%q\n' "$LR_CODEX" "$LR_DIR/vault" "$LR_AGENTS" > "$LR_CODEX_ENV"
printf 'foreign mirror owner\n' > "$LR_AGENTS/.install-lock"
LR_AGENTS_OUT="$(AI_CONFIG_LOCAL_ENV="$LR_CODEX_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness codex 2>&1)"; LR_AGENTS_RC=$?
assert_eq "install lock race: .agents contention fails after main target" "1" "$LR_AGENTS_RC"
assert_file "install lock race: .agents contention leaves main codex render" "$LR_CODEX/AGENTS.md"
assert_file "install lock race: .agents foreign lock survives" "$LR_AGENTS/.install-lock"
assert_contains "install lock race: .agents contention states mirror was untouched" "$LR_AGENTS_OUT" ".agents mirror was not touched"
if cmp -s "$LR_AGENTS_SNAPSHOT" "$LR_AGENTS/skills/closeout/SKILL.md"; then
  _pass "install lock race: .agents contention preserves mirror bytes"
else
  _fail "install lock race: .agents contention preserves mirror bytes" "mirror content changed"
fi
rm -f "$LR_AGENTS/.install-lock"

mkdir "$LR_TARGET/.install-lock"
LR_DIRLOCK_OUT="$(AI_CONFIG_LOCAL_ENV="$LR_A_ENV" bash "$LR_A_REPO/scripts/install.sh" 2>&1)"; LR_DIRLOCK_RC=$?
assert_eq "install lock race: directory lock refuses without blocking" "1" "$LR_DIRLOCK_RC"
assert_dir_lock_race "install lock race: directory lock is preserved" "$LR_TARGET/.install-lock"
rmdir "$LR_TARGET/.install-lock"

ln -s "$LR_DIR/missing-lock-target" "$LR_TARGET/.install-lock"
LR_SYMLINK_OUT="$(AI_CONFIG_LOCAL_ENV="$LR_A_ENV" bash "$LR_A_REPO/scripts/install.sh" 2>&1)"; LR_SYMLINK_RC=$?
assert_eq "install lock race: dangling symlink lock refuses without blocking" "1" "$LR_SYMLINK_RC"
if [ -L "$LR_TARGET/.install-lock" ]; then _pass "install lock race: dangling symlink lock is preserved"; else _fail "install lock race: dangling symlink lock is preserved" "link missing"; fi
rm -f "$LR_TARGET/.install-lock"

# Existing rollback coverage still executes under the lock, and its normal
# error path releases the lock for a later operator retry.
LR_FAIL_OUT="$(env AI_CONFIG_INSTALL_TEST_FAIL_SWAP=hooks AI_CONFIG_LOCAL_ENV="$LR_A_ENV" bash "$REPO_ROOT/scripts/install.sh" 2>&1)"; LR_FAIL_RC=$?
assert_eq "install lock race: forced swap error remains nonzero" "1" "$LR_FAIL_RC"
assert_absent_lock_race "install lock race: rollback error releases owned lock" "$LR_TARGET/.install-lock"
assert_absent_lock_race "install lock race: rollback error leaves no shared backup" "$LR_TARGET/.install-bak.d"
