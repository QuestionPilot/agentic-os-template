#!/usr/bin/env bash
# tests/tiers.test.sh — test-tiering mechanism.
#
# Verifies the _test_tier_of / _tier_should_run helpers in tests/lib.sh, the
# TEST_TIER wiring in tests/run.sh + the Makefile, the TIERS.md doc, and the
# marker-presence guard (the known clone/build-heavy files stay slow-marked so
# `make test-fast` keeps skipping them).
#
# SELF-TRIP GUARD: this file must never contain the literal slow marker as a
# column-0 comment line, or run.sh would classify THIS test as slow and
# `make test-fast` would skip the tier test itself. The marker is therefore
# assembled at runtime from non-matching halves. See [[feedback_self_tripping_test_source]].

# Build the canonical marker without ever emitting it at start-of-line in source.
_tt_slow="sl""ow"
_tt_marker="# test-tier: ${_tt_slow}"

_tt_tmp="$(mktemp -d)"

# Fixture 1: a column-0 marker → slow.
{ printf '#!/usr/bin/env bash\n'; printf '%s\n' "$_tt_marker"; printf '_pass "x"\n'; } \
  > "$_tt_tmp/slowfix.test.sh"
# Fixture 2: no marker → fast.
{ printf '#!/usr/bin/env bash\n# an ordinary fast test\n_pass "y"\n'; } \
  > "$_tt_tmp/fastfix.test.sh"
# Fixture 3: marker only as a quoted value and as an indented line → must stay
# fast (the ^# anchor rejects both — this is the self-trip protection itself).
{ printf '#!/usr/bin/env bash\n'; printf 'x="%s"\n' "$_tt_marker"; printf '   %s\n' "$_tt_marker"; } \
  > "$_tt_tmp/quotedfix.test.sh"
# Fixture 4: a column-0 marker on a CRLF line → still slow (the trailing-space
# class includes \r). Locks in cross-platform detection of CRLF-authored files.
{ printf '#!/usr/bin/env bash\r\n'; printf '%s\r\n' "$_tt_marker"; printf '_pass "z"\r\n'; } \
  > "$_tt_tmp/crlffix.test.sh"

assert_eq "_test_tier_of detects a column-0 slow marker" \
  "slow" "$(_test_tier_of "$_tt_tmp/slowfix.test.sh")"
assert_eq "_test_tier_of defaults an unmarked file to fast" \
  "fast" "$(_test_tier_of "$_tt_tmp/fastfix.test.sh")"
assert_eq "_test_tier_of ignores a quoted/indented marker (self-trip guard)" \
  "fast" "$(_test_tier_of "$_tt_tmp/quotedfix.test.sh")"
assert_eq "_test_tier_of detects a CRLF-terminated slow marker" \
  "slow" "$(_test_tier_of "$_tt_tmp/crlffix.test.sh")"

# --- _tier_should_run honors TEST_TIER (save/restore: this file is SOURCED into
# run.sh's shell, so a leaked TEST_TIER would mis-tier every later test file). --
if [ -n "${TEST_TIER+x}" ]; then _tt_orig_set=1; _tt_orig="$TEST_TIER"; else _tt_orig_set=0; fi

TEST_TIER=fast
_tier_should_run "$_tt_tmp/fastfix.test.sh" && _tt_r=run || _tt_r=skip
assert_eq "fast tier RUNS a fast file" "run" "$_tt_r"
_tier_should_run "$_tt_tmp/slowfix.test.sh" && _tt_r=run || _tt_r=skip
assert_eq "fast tier SKIPS a slow file" "skip" "$_tt_r"

TEST_TIER=full
_tier_should_run "$_tt_tmp/slowfix.test.sh" && _tt_r=run || _tt_r=skip
assert_eq "full tier RUNS a slow file" "run" "$_tt_r"

unset TEST_TIER
_tier_should_run "$_tt_tmp/slowfix.test.sh" && _tt_r=run || _tt_r=skip
assert_eq "default (unset) tier RUNS a slow file" "run" "$_tt_r"

TEST_TIER=bogus
_tier_should_run "$_tt_tmp/slowfix.test.sh" && _tt_r=run || _tt_r=skip
assert_eq "unexpected tier value RUNS a slow file (no silent skip)" "run" "$_tt_r"

if [ "$_tt_orig_set" = 1 ]; then TEST_TIER="$_tt_orig"; else unset TEST_TIER; fi
rm -rf "$_tt_tmp"

# --- Marker-presence guard: the known clone/build-heavy files MUST stay slow
# (else test-fast silently stops skipping them and the inner loop slows again).
# Both twins of each stem are checked so a bash-only or pwsh-only edit can't
# drift the marker off one side — the fast tier must skip the file under BOTH
# runners.
for _tt_stem in \
  links.test \
  bootstrap.test \
; do
  for _tt_ext in sh ps1; do
    assert_eq "slow-tier file $_tt_stem.$_tt_ext carries the marker" \
      "slow" "$(_test_tier_of "$REPO_ROOT/tests/$_tt_stem.$_tt_ext")"
  done
done

# --- Wiring guards: run.sh gate + Makefile target + the doc. ---
_tt_run="$(cat "$REPO_ROOT/tests/run.sh")"
assert_contains "run.sh consults the tier gate before sourcing" "$_tt_run" "_tier_should_run"

_tt_mk="$(cat "$REPO_ROOT/Makefile")"
assert_contains "Makefile defines a test-fast target" "$_tt_mk" "test-fast:"
assert_contains "Makefile test-fast drives the fast tier" "$_tt_mk" "TEST_TIER=fast"

assert_file "tests/TIERS.md documents the tiers" "$REPO_ROOT/tests/TIERS.md"

unset _tt_slow _tt_marker _tt_tmp _tt_r _tt_orig _tt_orig_set _tt_stem _tt_ext _tt_run _tt_mk
