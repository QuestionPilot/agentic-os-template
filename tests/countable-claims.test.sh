#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/countable-claims.test.sh — pin the framework's countable "N of a kind"
# facts to the filesystem so a prose count and reality can't silently diverge.
#
# Three claims recur in shipped prose and drift independently of the code:
#   * adapter count = harnesses/<name>/adapter.md dirs        (today: 3)
#   * native spine  = capabilities/*.md with `kind: native`   (today: 3)
#   * pillar count  = PILLAR_KEYS entries in self-audit.sh     (today: 5)
#
# Each count is DERIVED FROM THE FILESYSTEM, mapped to its English number-word,
# and the shipped prose is asserted to use that word. So when the filesystem
# grows — a 4th harness, a 4th native capability, a 6th pillar — but the prose is
# left stale, this test goes RED — which is the guard's whole job: it must fail
# when `ls harnesses/` and the prose disagree. No count is hard-coded on the
# prose side; only the small num->word table is fixed.
#
# Per [[reference_shell_grep_overlay]] use /usr/bin/grep (BSD semantics, not the
# interactive zsh ugrep alias). Per [[reference_awk_portability]] wrap awk with
# LC_ALL=C. This file is FAST tier — it only reads tracked files.

GREP=/usr/bin/grep

# num_word <n> — English word for a small non-negative integer (0..9). The guard
# only ever needs single digits. An out-of-range count echoes its digits so the
# prose assertion fails loudly rather than matching some bogus empty string.
num_word() {
  case "$1" in
    0) printf 'zero';;  1) printf 'one';;   2) printf 'two';;
    3) printf 'three';; 4) printf 'four';;  5) printf 'five';;
    6) printf 'six';;   7) printf 'seven';; 8) printf 'eight';; 9) printf 'nine';;
    # Empty (e.g. a parse that produced nothing) -> a non-matchable sentinel, so
    # the prose assertion fails loudly rather than matching a bare " <noun>".
    *) printf '%s' "${1:-NONE}";;
  esac
}

# === ground truth #1: adapter count = harnesses/*/adapter.md =================
adapter_count=0
for d in "$REPO_ROOT"/harnesses/*/adapter.md; do
  [ -f "$d" ] && adapter_count=$((adapter_count + 1))
done
adapter_word="$(num_word "$adapter_count")"
assert_eq "adapters: harnesses/*/adapter.md parsed (non-empty)" "yes" \
  "$([ "$adapter_count" -ge 1 ] && echo yes || echo no)"
CAP_README="$(cat "$REPO_ROOT/capabilities/README.md")"
assert_contains "capabilities/README.md adapter count matches the filesystem ($adapter_count -> '$adapter_word')" \
  "$CAP_README" "$adapter_word adapter"

# === ground truth #2: native spine = capabilities/*.md with `kind: native` ===
# Exact-line match (-x): README.md's schema-example line `kind: native | vendored`
# is NOT a native capability and must not be counted.
native_count=0
for f in "$REPO_ROOT"/capabilities/*.md; do
  LC_ALL=C $GREP -qx 'kind: native' "$f" && native_count=$((native_count + 1))
done
native_word="$(num_word "$native_count")"
assert_eq "spine: capabilities/*.md kind:native parsed (non-empty)" "yes" \
  "$([ "$native_count" -ge 1 ] && echo yes || echo no)"
SELF_AUDIT_MD="$(cat "$REPO_ROOT/capabilities/self-audit.md")"
assert_contains "self-audit.md spine count matches the filesystem ($native_count -> '$native_word')" \
  "$SELF_AUDIT_MD" "$native_word spine"

# Cross-form pin: the DIGIT-form claim in harnesses/codex/adapter.md must agree
# with the same filesystem counts. The word-form anchors above don't cover prose
# that spells the number with a digit — a 4th harness/capability that refreshes
# the word anchors but leaves "N spine capabilities × N harnesses" stale is
# exactly the drift this catches.
CODEX_ADAPTER="$(cat "$REPO_ROOT/harnesses/codex/adapter.md")"
assert_contains "codex/adapter.md digit claim matches the filesystem ($native_count spine x $adapter_count harnesses)" \
  "$CODEX_ADAPTER" "$native_count spine capabilities × $adapter_count harnesses"

# === ground truth #3: pillar count = PILLAR_KEYS entries in self-audit.sh =====
# Count the quoted entries inside the `PILLAR_KEYS=( ... )` array literal — the
# code's own source of truth for how many pillars the scorer scores. gsub counts
# quoted strings PER LINE and stops at the line bearing the closing `)`, so the
# count is robust to array reformatting — indented `)`, an inline last entry
# (`"e" )`), or the whole array on one line. Held in a variable so the detector
# unit tests below can exercise it against those exact shapes.
_PILLAR_AWK='
  /PILLAR_KEYS=\(/ { inarr=1 }
  inarr && !done   { n += gsub(/"[^"]+"/, ""); if ($0 ~ /\)/) done=1 }
  END { print n+0 }
'
pillar_count="$(LC_ALL=C awk "$_PILLAR_AWK" "$REPO_ROOT/scripts/self-audit.sh")"
pillar_word="$(num_word "$pillar_count")"
assert_eq "pillars: self-audit.sh PILLAR_KEYS parsed (non-empty)" "yes" \
  "$([ "$pillar_count" -ge 1 ] && echo yes || echo no)"
assert_contains "self-audit.md pillar count matches self-audit.sh PILLAR_KEYS ($pillar_count -> '$pillar_word')" \
  "$SELF_AUDIT_MD" "$pillar_word pillars"
SELF_AUDIT_SH="$(cat "$REPO_ROOT/scripts/self-audit.sh")"
assert_contains "self-audit.sh header pillar count matches PILLAR_KEYS ($pillar_count -> '$pillar_word')" \
  "$SELF_AUDIT_SH" "$pillar_word pillars"

# === ground truth #4: README harness-compat matrix == adapter "Verified against"
# The README's harness-compatibility table SUMMARIZES each adapter's "Verified
# against vX.Y.Z" line and names the adapter as the source of truth. Pin the
# summary to that source: extract each adapter's verified version and assert the
# README matrix carries the same string. Bump an adapter without the README (or
# vice-versa) and this goes RED — the same prose-vs-truth drift this file guards.
for _h in claude codex hermes cursor; do
  _adapter="$REPO_ROOT/harnesses/$_h/adapter.md"
  # The adapter's "Verified against **<Display Name> vX.Y.Z**" carries BOTH the
  # harness display name and the version — extract both, so the README check can
  # bind the version to the correctly-NAMED matrix row (a row-swap or a version
  # that only appears in prose must fail, not just "version present somewhere").
  _label="$(LC_ALL=C $GREP -oE 'Verified against \*\*[^*]*\*\*' "$_adapter" \
    | head -1 | sed -E 's/^Verified against \*\*//; s/\*\*$//')"
  _ver="$(printf '%s' "$_label" | $GREP -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  _name="$(printf '%s' "$_label" | sed -E 's/ v[0-9].*$//')"
  assert_eq "$_h/adapter.md declares a Verified-against version (non-empty)" "yes" \
    "$([ -n "$_ver" ] && echo yes || echo no)"
  # The matrix ROW for this harness (a table line naming it) must carry its version.
  _row="$(LC_ALL=C $GREP -E "^\|.*${_name}.*\|" "$REPO_ROOT/README.md" | head -1)"
  assert_contains "README compat matrix row for '$_name' carries adapter version ($_ver)" \
    "$_row" "$_ver"
done

# === negative regressions: the specific stale count claims stay fixed ========
# File-scoped so the contextually-correct pairwise "two adapters" sentence in
# harnesses/claude/adapter.md (this-file-vs-Codex) is intentionally NOT in scope.
assert_not_contains "capabilities/README.md no longer claims 'two adapters'" \
  "$CAP_README" "two adapters"
# Single-line needle (CRLF-immune for the PS twin): the corrected example lists
# hermes. "[claude, codex]" is NOT a substring of "[claude, codex, hermes]" (the
# char after 'codex' is ',' not ']'), so this also goes red on a revert.
LIFECYCLE_MD="$(cat "$REPO_ROOT/core/lifecycle.md")"
assert_contains "core/lifecycle.md capability example includes hermes (not the stale [claude, codex])" \
  "$LIFECYCLE_MD" "harnesses: [claude, codex, hermes]"

# === detector unit tests: num_word + a stale-prose fixture trips the guard ====
assert_eq "num_word maps 3 -> three" "three" "$(num_word 3)"
assert_eq "num_word maps 5 -> five" "five" "$(num_word 5)"
assert_eq "num_word maps 4 -> four (the next-harness case)" "four" "$(num_word 4)"

# Simulate a 4th harness landing (FS count 4 -> 'four') while the prose still
# says 'three adapters'. The contains-check the real guard uses must MISS — i.e.
# the guard would go RED. Assert the miss (grep -F returns non-zero) and, as a
# control, that it HOLDS when FS and prose agree.
fixture_prose="the framework ships three adapters today"
assert_eq "guard trips when FS count (4->four) disagrees with stale prose ('three')" "1" \
  "$(printf '%s' "$fixture_prose" | LC_ALL=C $GREP -qF "$(num_word 4) adapter"; echo $?)"
assert_eq "guard holds when FS count (3->three) agrees with prose" "0" \
  "$(printf '%s' "$fixture_prose" | LC_ALL=C $GREP -qF "three adapter"; echo $?)"

# pillar parser robustness — it must count ENTRIES, not lines, regardless of how
# the array literal is formatted (the cross-model panel flagged the original
# line-based parser as brittle to reformatting).
_pillar_fix="$(mktemp)"
printf 'PILLAR_KEYS=(\n  "a"\n  "b"\n  "c"\n)\n' > "$_pillar_fix"
assert_eq "pillar parser: standard multi-line array -> 3" "3" \
  "$(LC_ALL=C awk "$_PILLAR_AWK" "$_pillar_fix")"
printf 'PILLAR_KEYS=( "a" "b" "c" "d" )\n' > "$_pillar_fix"
assert_eq "pillar parser: single-line array -> 4" "4" \
  "$(LC_ALL=C awk "$_PILLAR_AWK" "$_pillar_fix")"
printf 'PILLAR_KEYS=(\n  "a"\n  "b" )\n' > "$_pillar_fix"
assert_eq "pillar parser: inline closing paren -> 2" "2" \
  "$(LC_ALL=C awk "$_PILLAR_AWK" "$_pillar_fix")"
rm -f "$_pillar_fix"
