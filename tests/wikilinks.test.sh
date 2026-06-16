#!/usr/bin/env bash
# tests/wikilinks.test.sh — behavioral tests for scripts/check-wikilinks.sh.
#
# The check resolves every [[wikilink]] in a drafted session-log body the SAME
# way the vault audit's checkWikilinks (bin/memory-vault-audit.js) does: a target
# resolves iff the vault contains a note at that full vault-relative path (±ext)
# or — for the vault ROOT only — a note with that bare name. Fails closed: exit 0
# = all resolve (or none present), 1 = one or more unresolved, 2 = usage error.
#
# Sourced by tests/run.sh; do NOT set -e or call exit.

CMD_SCRIPT="$REPO_ROOT/scripts/check-wikilinks.sh"

# _mkvault <dir> — a fixture vault: two root notes (START, README), two subfolder
# notes (10-Wiki/Concepts/Foo, 02-Areas/Bar), one root .base, one subfolder .base.
_mkvault() {
  local v="$1"
  mkdir -p "$v/10-Wiki/Concepts" "$v/02-Areas"
  printf -- '---\ntitle: START\n---\n'  > "$v/START.md"
  printf -- '---\ntitle: README\n---\n' > "$v/README.md"
  printf -- '---\ntitle: Foo\n---\n'    > "$v/10-Wiki/Concepts/Foo.md"
  printf -- '---\ntitle: Bar\n---\n'    > "$v/02-Areas/Bar.md"
  printf 'rootbase\n'                   > "$v/RootView.base"
  printf 'subbase\n'                    > "$v/10-Wiki/SubView.base"
}

# _draft <content> — write content to a fresh temp file, echo its path.
_draft() {
  local f; f=$(mktemp 2>/dev/null) || f="/tmp/wl-draft-$$-$RANDOM"
  printf '%s\n' "$1" > "$f"
  printf '%s' "$f"
}

VAULT=$(mktemp -d 2>/dev/null) || VAULT="/tmp/wl-vault-$$"
_mkvault "$VAULT"

# === 1. Full vault-relative path resolves → exit 0, PASS.
D1=$(_draft 'See [[10-Wiki/Concepts/Foo]] for details.')
OUT1=$(bash "$CMD_SCRIPT" --draft "$D1" --vault "$VAULT" 2>&1); RC1=$?
assert_eq "wl: full-path link exits 0" "0" "$RC1"
assert_contains "wl: full-path link reports PASS" "$OUT1" "PASS all 1 wikilink"

# === 2. Root-level bare name resolves (the only bare form that may) → exit 0.
D2=$(_draft 'Start at [[START]] and [[README]].')
assert_exit "wl: root bare names resolve → exit 0" 0 -- \
  bash "$CMD_SCRIPT" --draft "$D2" --vault "$VAULT"

# === 3. Bare-basename SUBFOLDER link fails closed → exit 1, names it + suggests.
D3=$(_draft 'Bad bare [[Foo]] subfolder link.')
OUT3=$(bash "$CMD_SCRIPT" --draft "$D3" --vault "$VAULT" 2>&1); RC3=$?
assert_eq "wl: bare subfolder link exits 1 (fail closed)" "1" "$RC3"
assert_contains "wl: names the unresolved target" "$OUT3" "unresolved wikilink:"
assert_contains "wl: names the bare target Foo" "$OUT3" "-> Foo"
assert_contains "wl: suggests the full path" "$OUT3" "[[10-Wiki/Concepts/Foo]]"
assert_contains "wl: failure summary counts unresolved" "$OUT3" "1 of 1 wikilink target(s) unresolved"

# === 4. Alias `|` and heading `#` are stripped; the path still resolves → exit 0.
D4=$(_draft 'Alias [[10-Wiki/Concepts/Foo|nickname]] and heading [[10-Wiki/Concepts/Foo#a-section]].')
assert_exit "wl: aliased + heading links resolve (separator stripped) → exit 0" 0 -- \
  bash "$CMD_SCRIPT" --draft "$D4" --vault "$VAULT"

# === 5. Backticked memory-store names are NOT wikilinks → ignored → exit 0.
D5=$(_draft 'Memory notes `project-foo`, `feedback-bar`, `reference-baz` are backticked.')
OUT5=$(bash "$CMD_SCRIPT" --draft "$D5" --vault "$VAULT" 2>&1); RC5=$?
assert_eq "wl: backticked memory names ignored → exit 0" "0" "$RC5"
assert_contains "wl: backticked-only draft has 0 wikilinks" "$OUT5" "all 0 wikilink"

# === 6. A memory-store name WRONGLY wikilinked fails (enforces backticking) → exit 1.
D6=$(_draft 'Wrong [[project-foo]] should be backticked.')
OUT6=$(bash "$CMD_SCRIPT" --draft "$D6" --vault "$VAULT" 2>&1); RC6=$?
assert_eq "wl: wrongly-wikilinked memory name fails → exit 1" "1" "$RC6"
assert_contains "wl: names the wrongly-wikilinked target" "$OUT6" "-> project-foo"

# === 7. No wikilinks at all → exit 0 (all 0).
D7=$(_draft 'Just prose, nothing to resolve.')
assert_exit "wl: no wikilinks → exit 0" 0 -- \
  bash "$CMD_SCRIPT" --draft "$D7" --vault "$VAULT"

# === 8. Explicit .md / .base extension in the link resolves → exit 0.
D8=$(_draft 'Ext [[10-Wiki/Concepts/Foo.md]] and base [[10-Wiki/SubView.base]].')
assert_exit "wl: explicit .md / .base extension resolves → exit 0" 0 -- \
  bash "$CMD_SCRIPT" --draft "$D8" --vault "$VAULT"

# === 9. .base resolution mirrors .md: root .base bare resolves, subfolder .base bare fails.
D9OK=$(_draft 'Root base [[RootView]] ok.')
assert_exit "wl: root-level .base bare name resolves → exit 0" 0 -- \
  bash "$CMD_SCRIPT" --draft "$D9OK" --vault "$VAULT"
D9BAD=$(_draft 'Sub base [[SubView]] bad.')
assert_exit "wl: subfolder .base bare name fails → exit 1" 1 -- \
  bash "$CMD_SCRIPT" --draft "$D9BAD" --vault "$VAULT"

# === 10. Malformed empty link [[ ]] is fail-closed (the audit flags it too).
D10=$(_draft 'Empty [[ ]] link.')
OUT10=$(bash "$CMD_SCRIPT" --draft "$D10" --vault "$VAULT" 2>&1); RC10=$?
assert_eq "wl: empty [[ ]] target fails closed → exit 1" "1" "$RC10"
assert_contains "wl: empty target reported as (empty)" "$OUT10" "-> (empty)"

# === 11. Mixed draft: distinct targets counted; some resolve, some not → exit 1.
D11=$(_draft 'Good [[START]] and [[10-Wiki/Concepts/Foo]], bad [[Bar]] and [[Nope]].')
OUT11=$(bash "$CMD_SCRIPT" --draft "$D11" --vault "$VAULT" 2>&1); RC11=$?
assert_eq "wl: mixed draft exits 1" "1" "$RC11"
assert_contains "wl: mixed draft counts 2 of 4 distinct unresolved" "$OUT11" "2 of 4 wikilink target(s) unresolved"
assert_contains "wl: mixed flags Bar" "$OUT11" "-> Bar"
assert_contains "wl: mixed flags Nope" "$OUT11" "-> Nope"

# === 12. Duplicate links dedup to distinct targets in the count.
D12=$(_draft '[[START]] again [[START]] and once more [[START]].')
OUT12=$(bash "$CMD_SCRIPT" --draft "$D12" --vault "$VAULT" 2>&1)
assert_contains "wl: duplicate links dedup to 1 distinct target" "$OUT12" "all 1 wikilink"

# === 13. Ambiguous basename → bare name fails with NO suggestion (two folders share it).
AMB=$(mktemp -d 2>/dev/null) || AMB="/tmp/wl-amb-$$"
mkdir -p "$AMB/A" "$AMB/B"
printf 'a\n' > "$AMB/A/Dup.md"
printf 'b\n' > "$AMB/B/Dup.md"
D13=$(_draft 'Ambiguous [[Dup]].')
OUT13=$(bash "$CMD_SCRIPT" --draft "$D13" --vault "$AMB" 2>&1); RC13=$?
assert_eq "wl: ambiguous bare name fails → exit 1" "1" "$RC13"
assert_not_contains "wl: ambiguous bare name gives NO suggestion" "$OUT13" "did you mean"

# === 14. Vault derived from OBSIDIAN_VAULT_PATH when --vault omitted.
OUT14=$(OBSIDIAN_VAULT_PATH="$VAULT" bash "$CMD_SCRIPT" --draft "$D1" 2>&1); RC14=$?
assert_eq "wl: vault from OBSIDIAN_VAULT_PATH env → exit 0" "0" "$RC14"

# === 15. Spaced vault path (cloud-vault realism) resolves space-safely.
VSPACE=$(mktemp -d 2>/dev/null)/"My Vault"; mkdir -p "$VSPACE/10-Wiki/Concepts"
printf -- '---\ntitle: Foo\n---\n' > "$VSPACE/10-Wiki/Concepts/Foo.md"
assert_exit "wl: spaced vault path resolves → exit 0" 0 -- \
  bash "$CMD_SCRIPT" --draft "$D1" --vault "$VSPACE"

# === 16. Usage errors → exit 2.
assert_exit "wl: missing --draft → exit 2" 2 -- \
  bash "$CMD_SCRIPT" --vault "$VAULT"
assert_exit "wl: nonexistent draft → exit 2" 2 -- \
  bash "$CMD_SCRIPT" --draft "/tmp/no-such-draft-$$" --vault "$VAULT"
assert_exit "wl: nonexistent vault → exit 2" 2 -- \
  bash "$CMD_SCRIPT" --draft "$D1" --vault "/tmp/no-such-vault-$$"
assert_exit "wl: no --vault + no OBSIDIAN_VAULT_PATH → exit 2" 2 -- \
  env -i bash "$CMD_SCRIPT" --draft "$D1"
assert_exit "wl: unknown arg → exit 2" 2 -- \
  bash "$CMD_SCRIPT" --draft "$D1" --vault "$VAULT" --bogus

# === 17. --help exits 0 and prints the banner.
HELP_OUT=$(bash "$CMD_SCRIPT" --help 2>&1)
assert_eq "wl: --help exits 0" "0" "$?"
assert_contains "wl: --help prints the banner" "$HELP_OUT" "check-wikilinks.sh"

# === 18. The check does NOT strip code spans — a wikilink inside inline code is
# still resolved (matches the audit, which does not exempt code). A backticked
# PLAIN name (no brackets) stays ignored; only a real [[ ]] is a link.
D18=$(_draft 'Inline code with a real link `[[Foo]]` is still checked.')
assert_exit "wl: wikilink inside inline-code is still checked (audit fidelity)" 1 -- \
  bash "$CMD_SCRIPT" --draft "$D18" --vault "$VAULT"

# === 19. No display-sentinel collision: a vault note literally named `(empty)`
# makes [[(empty)]] resolve (the reference would too), while a malformed [[ ]]
# still fails closed and is rendered as "(empty)". Proves the empty target is
# carried as "" through resolution, not as a colliding sentinel string.
VEMPTY=$(mktemp -d 2>/dev/null) || VEMPTY="/tmp/wl-vempty-$$"
printf -- '---\ntitle: empty\n---\n' > "$VEMPTY/(empty).md"
D19a=$(_draft 'Link to [[(empty)]] real root note.')
assert_exit "wl: [[(empty)]] resolves to a real (empty).md (no sentinel collision)" 0 -- \
  bash "$CMD_SCRIPT" --draft "$D19a" --vault "$VEMPTY"
D19b=$(_draft 'Malformed [[ ]] link.')
OUT19b=$(bash "$CMD_SCRIPT" --draft "$D19b" --vault "$VEMPTY" 2>&1); RC19b=$?
assert_eq "wl: malformed [[ ]] still fails even when (empty).md exists" "1" "$RC19b"
assert_contains "wl: malformed empty target rendered as (empty)" "$OUT19b" "-> (empty)"

# === 20. Wiring is pinned: capabilities/closeout.md invokes the check so a future
# refactor that drops the pre-drain gate is caught here.
CLOSEOUT_BODY=$(cat "$REPO_ROOT/capabilities/closeout.md")
assert_contains "wl: closeout.md wires the pre-drain check invocation" "$CLOSEOUT_BODY" "scripts/check-wikilinks.sh --draft"

# === 21. Unreadable (but existing) draft → exit 2 (mirrors bash `[ -r ]`).
# Guarded: a root-run CI can read 000 files, so skip rather than false-fail.
UNREAD=$(_draft 'x [[START]]')
chmod 000 "$UNREAD" 2>/dev/null
if [ -r "$UNREAD" ]; then
  _skip "wl: unreadable draft → exit 2" "cannot revoke read (running as root?)"
else
  assert_exit "wl: unreadable draft → exit 2" 2 -- \
    bash "$CMD_SCRIPT" --draft "$UNREAD" --vault "$VAULT"
fi
chmod 644 "$UNREAD" 2>/dev/null

# --- Cleanup.
rm -rf "$VAULT" "$AMB" "$VSPACE" "$VEMPTY" \
  "$D1" "$D2" "$D3" "$D4" "$D5" "$D6" "$D7" "$D8" "$D9OK" "$D9BAD" "$D10" \
  "$D11" "$D12" "$D13" "$D18" "$D19a" "$D19b" "$UNREAD"
