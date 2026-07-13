#!/usr/bin/env bash
# tests/machine-paths.test.sh — behavioral tests for scripts/check-machine-paths.sh.
#
# The check scans a drafted session-log body line-by-line for a machine-specific
# absolute home path the SAME way the vault audit's checkAgnostic
# (obsidian/vault-scaffolding/bin/memory-vault-audit.js) does: it flags a real
# /Users/<name> or /home/<name> segment (NOT preceded by a URL host char) and a
# C:\Users\<name> segment, while leaving a URL path and a lone "Users" prose token
# alone. Fails closed: exit 0 = clean, 1 = one or more offending lines, 2 = usage.
#
# Sourced by tests/run.sh; do NOT set -e or call exit.

CMD_SCRIPT="$REPO_ROOT/scripts/check-machine-paths.sh"

# _draft <content> — write content (with literal newlines) to a fresh temp file,
# echo its path. printf '%b' expands the \n escapes so multi-line fixtures land on
# distinct lines (needed to assert the offender's line number).
_draft() {
  local f; f=$(mktemp 2>/dev/null) || f="/tmp/mp-draft-$$-$RANDOM"
  printf '%b' "$1" > "$f"
  printf '%s' "$f"
}

# === 1. Clean draft (prose + a URL path with a Users segment) → exit 0, PASS.
# Covers the URL-exclusion case AND the lone-"Users"-word case in one fixture.
D1=$(_draft 'Session note.\nSee https://example.com/Users/foo for docs.\nUsers manage their own settings.\n')
OUT1=$(bash "$CMD_SCRIPT" --draft "$D1" 2>&1); RC1=$?
assert_eq "mp: clean draft (URL + prose) exits 0" "0" "$RC1"
assert_contains "mp: clean draft reports PASS" "$OUT1" "PASS no machine-specific absolute paths"

# === 2. A bare /Users/<name> path fails closed → exit 1, names <draft>:<line>.
D2=$(_draft 'intro line\nlog at /Users/dana/thing here\n')
OUT2=$(bash "$CMD_SCRIPT" --draft "$D2" 2>&1); RC2=$?
assert_eq "mp: /Users/<name> path exits 1 (fail closed)" "1" "$RC2"
assert_contains "mp: names the offending line 2" "$OUT2" "$D2:2"
assert_contains "mp: prints the offender message" "$OUT2" "machine-specific absolute path"
assert_contains "mp: failure summary counts offenders" "$OUT2" "1 offending line(s)"

# === 3. A Windows C:\Users\<name> path fails closed → exit 1.
D3=$(_draft 'win path C:\\Users\\bob\\notes today\n')
OUT3=$(bash "$CMD_SCRIPT" --draft "$D3" 2>&1); RC3=$?
assert_eq "mp: C:\\Users\\<name> path exits 1" "1" "$RC3"
assert_contains "mp: names the Windows offender line 1" "$OUT3" "$D3:1"

# === 4. A /home/<name> path fails closed → exit 1 (the other Unix home root).
D4=$(_draft 'linux path /home/alice/config ok\n')
assert_exit "mp: /home/<name> path exits 1" 1 -- \
  bash "$CMD_SCRIPT" --draft "$D4"

# === 5. URL-exclusion is explicit: a home path preceded by an alnum or dot host
# char is NOT flagged (a/Users, example.com/Users, 2.0/Users all pass), while a
# delimiter-preceded path (=, backtick, line start) IS flagged.
D5OK=$(_draft 'a/Users/dave\nexample.com/Users/eric\nversion 2.0/Users/frank\n')
OUT5OK=$(bash "$CMD_SCRIPT" --draft "$D5OK" 2>&1); RC5OK=$?
assert_eq "mp: alnum/dot-prefixed (URL-host) paths pass → exit 0" "0" "$RC5OK"
D5BAD=$(_draft 'path=/Users/bob\n')
assert_exit "mp: delimiter-prefixed (=) real path fails → exit 1" 1 -- \
  bash "$CMD_SCRIPT" --draft "$D5BAD"

# === 6. A lone home-root token WITHOUT a username segment does not trip (the
# `[^/…]+` tail requires a real segment): "/Users/" or "/home" alone passes.
D6=$(_draft 'the /Users/ root and the word home are fine\n')
assert_exit "mp: home root without a username segment passes → exit 0" 0 -- \
  bash "$CMD_SCRIPT" --draft "$D6"

# === 7. Mixed draft: multiple offenders on distinct lines, count + line numbers.
D7=$(_draft 'ok line\n/Users/one/a\nok\nC:\\Users\\two\\b\n/home/three/c\n')
OUT7=$(bash "$CMD_SCRIPT" --draft "$D7" 2>&1); RC7=$?
assert_eq "mp: mixed draft exits 1" "1" "$RC7"
assert_contains "mp: mixed counts 3 offending lines" "$OUT7" "3 offending line(s)"
assert_contains "mp: mixed flags line 2" "$OUT7" "$D7:2"
assert_contains "mp: mixed flags line 4" "$OUT7" "$D7:4"
assert_contains "mp: mixed flags line 5" "$OUT7" "$D7:5"

# === 8. No raw-evidence exemption: a machine path anywhere (even framed as an
# observation) is flagged — the whole file is scanned.
D8=$(_draft '## Raw observations\ntool-output: /Users/dana/x\n')
assert_exit "mp: machine path under Raw observations is still flagged → exit 1" 1 -- \
  bash "$CMD_SCRIPT" --draft "$D8"

# === 9. Usage errors → exit 2.
assert_exit "mp: missing --draft → exit 2" 2 -- \
  bash "$CMD_SCRIPT"
assert_exit "mp: nonexistent draft → exit 2" 2 -- \
  bash "$CMD_SCRIPT" --draft "/tmp/no-such-mp-draft-$$"
assert_exit "mp: unknown arg → exit 2" 2 -- \
  bash "$CMD_SCRIPT" --draft "$D1" --bogus

# === 10. --help exits 0 and prints the banner.
HELP_OUT=$(bash "$CMD_SCRIPT" --help 2>&1)
assert_eq "mp: --help exits 0" "0" "$?"
assert_contains "mp: --help prints the banner" "$HELP_OUT" "check-machine-paths.sh"

# === 11. Spaced draft path (cloud-vault realism) is space-safe in the report.
SPACED=$(mktemp -d 2>/dev/null)/"My Drafts"; mkdir -p "$SPACED"
D11="$SPACED/log.md"; printf '%b' 'bad /Users/x/y\n' > "$D11"
OUT11=$(bash "$CMD_SCRIPT" --draft "$D11" 2>&1); RC11=$?
assert_eq "mp: spaced draft path exits 1" "1" "$RC11"
assert_contains "mp: spaced draft path reported intact" "$OUT11" "$D11:1"

# === 12. Unreadable (but existing) draft → exit 2 (mirrors bash `[ -r ]`).
# Guarded: a root-run CI can read 000 files, so skip rather than false-fail.
UNREAD=$(_draft 'x /Users/y/z\n')
chmod 000 "$UNREAD" 2>/dev/null
if [ -r "$UNREAD" ]; then
  _skip "mp: unreadable draft → exit 2" "cannot revoke read (running as root?)"
else
  assert_exit "mp: unreadable draft → exit 2" 2 -- \
    bash "$CMD_SCRIPT" --draft "$UNREAD"
fi
chmod 644 "$UNREAD" 2>/dev/null

# === 13. Wiring is pinned: capabilities/closeout.md invokes the check so a future
# refactor that drops the pre-drain gate is caught here.
CLOSEOUT_BODY=$(cat "$REPO_ROOT/capabilities/closeout.md")
assert_contains "mp: closeout.md wires the pre-drain check invocation" "$CLOSEOUT_BODY" "scripts/check-machine-paths.sh --draft"

# === 14. Offender on the FINAL line with NO trailing newline is still caught —
# the editor-strips-trailing-newline shape. Guards the single-pass grep scan:
# grep must match (and number) an unterminated final line.
D14=$(mktemp 2>/dev/null) || D14="/tmp/mp-draft-$$-$RANDOM"
printf 'ok line\nbad /Users/dana/x' > "$D14"   # deliberately no trailing newline
OUT14=$(bash "$CMD_SCRIPT" --draft "$D14" 2>&1); RC14=$?
assert_eq "mp: offender on final newline-less line exits 1" "1" "$RC14"
assert_contains "mp: final newline-less offender flagged at line 2" "$OUT14" "$D14:2"

# === 15. Two machine paths on ONE line count as ONE offending line — the report
# and count are line-based, not match-based.
D15=$(_draft 'both /Users/one/a and /home/two/b on one line\n')
OUT15=$(bash "$CMD_SCRIPT" --draft "$D15" 2>&1); RC15=$?
assert_eq "mp: two paths on one line exit 1" "1" "$RC15"
assert_contains "mp: two paths on one line count as 1 offending line" "$OUT15" "1 offending line(s)"

# === 16. Lowercase home root is NOT flagged — documents the case-sensitivity
# trade-off inherited from the reference (checkAgnostic matches case-sensitively).
D16=$(_draft 'lowercase /users/dana/x stays unflagged\n')
assert_exit "mp: lowercase /users/<name> passes (case-sensitive by contract) → exit 0" 0 -- \
  bash "$CMD_SCRIPT" --draft "$D16"

# === 17. Relative draft path resolves against the caller's CWD (parity pin with
# the PS twin's relative-path case).
RELDIR=$(mktemp -d 2>/dev/null) || RELDIR="/tmp/mp-rel-$$"
mkdir -p "$RELDIR"
printf '%b' 'ok\nbad /Users/dana/y\n' > "$RELDIR/rel-draft.md"
OUT17=$( (cd "$RELDIR" && bash "$CMD_SCRIPT" --draft "rel-draft.md") 2>&1 ); RC17=$?
assert_eq "mp: relative draft path from its own dir exits 1" "1" "$RC17"
assert_contains "mp: relative draft offender flagged at line 2" "$OUT17" "rel-draft.md:2"

# === 18. A directory passed as --draft is a usage error → exit 2.
DIRDRAFT=$(mktemp -d 2>/dev/null) || { DIRDRAFT="/tmp/mp-dir-$$"; mkdir -p "$DIRDRAFT"; }
assert_exit "mp: directory as --draft → exit 2" 2 -- \
  bash "$CMD_SCRIPT" --draft "$DIRDRAFT"

# --- Cleanup.
rm -rf "$SPACED" "$RELDIR" "$DIRDRAFT" \
  "$D1" "$D2" "$D3" "$D4" "$D5OK" "$D5BAD" "$D6" "$D7" "$D8" "$D14" "$D15" "$D16" "$UNREAD"
