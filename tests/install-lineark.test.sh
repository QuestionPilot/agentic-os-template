#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/install-lineark.test.sh — behavioral tests for scripts/install-lineark.sh,
# the pinned checksum-verified installer that replaced the upstream `curl … | sh`
# instruction for the optional `lineark` CLI.
#
# What is under test is the REFUSAL contract, because that is the whole reason
# the script exists — an installer that happily installs is indistinguishable
# from `curl | sh`:
#
#   - correct checksum              -> installs, version smoke passes, exit 0
#   - checksum MISMATCH             -> exit 1, nothing installed, expected vs
#                                      actual both printed
#   - tag ABSENT from the pin file  -> exit 1, "unvetted release", nothing
#                                      installed, re-vet procedure named
#   - version smoke MISMATCH        -> exit 1, the binary removed again
#   - unsupported platform          -> exit 3, both documented alternatives named
#
# HERMETIC. No network: the release mirror is a local directory served through
# `file://`, and the "binary" is a two-line /bin/sh script so `--version` works.
# EVERY invocation pins LINEARK_VERSION, LINEARK_CHECKSUM_FILE, LINEARK_BASE_URL
# and LINEARK_INSTALL_DIR, so the operator's real pin file, real install dir and
# real network are never reachable from this suite.
#
# Sourced by tests/run.sh; do NOT set -e or call exit.

LK_SCRIPT="$REPO_ROOT/scripts/install-lineark.sh"
LK_SUMS_REAL="$REPO_ROOT/scripts/lineark-checksums.sha256"

assert_file "install-lineark: scripts/install-lineark.sh exists" "$LK_SCRIPT"
assert_file "install-lineark: scripts/lineark-checksums.sha256 exists" "$LK_SUMS_REAL"
assert_file "install-lineark: the PowerShell twin exists" "$REPO_ROOT/scripts/install-lineark.ps1"

# The docs tell operators to run it directly; a 644 file turns that into
# "permission denied" for everyone who copies the documented command.
if [ -x "$LK_SCRIPT" ]; then
  _pass "install-lineark: the installer is executable"
else
  _fail "install-lineark: the installer is executable" "not executable: $LK_SCRIPT"
fi

# --- sha256 helper: the same probe order the script uses --------------------
_lk_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# --- host -> asset name, mirroring the script's own platform table ----------
LK_ASSET=""
case "$(uname -s)" in
  Linux)
    case "$(uname -m)" in
      x86_64|amd64)  LK_ASSET="lineark_linux_x86_64" ;;
      aarch64|arm64) LK_ASSET="lineark_linux_aarch64" ;;
    esac
    ;;
  Darwin)
    case "$(uname -m)" in
      arm64|aarch64) LK_ASSET="lineark_macos_aarch64" ;;
    esac
    ;;
esac

LK_TMP="$(mktemp -d)"
LK_VER="v9.9.9"
LK_MIRROR="$LK_TMP/mirror"

# _lk_run <version> <sums-file> <base-url> <install-dir> — run the installer with
# EVERY override pinned; sets LK_OUT and LK_RC. Nothing is inherited from the
# operator's environment.
_lk_run() {
  LK_OUT="$(env \
    LINEARK_VERSION="$1" \
    LINEARK_CHECKSUM_FILE="$2" \
    LINEARK_BASE_URL="$3" \
    LINEARK_INSTALL_DIR="$4" \
    bash "$LK_SCRIPT" 2>&1)"
  LK_RC=$?
}

# _lk_fake_asset <path> <version-string> — a stand-in release artifact that is a
# real executable, so the version smoke is exercised rather than stubbed out.
_lk_fake_asset() {
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\nprintf "lineark %s\\n"\n' "$2" > "$1"
}

# === A. The pin file the framework actually ships parses and is well-formed.
# A POSITIVE fixture for the lookup parser: without it, a lookup that matched
# nothing at all would still pass every refusal test below.
LK_REAL_ENTRIES="$(grep -cE '^[0-9a-f]{64}[[:space:]]+v[0-9]+\.[0-9]+\.[0-9]+/lineark_' "$LK_SUMS_REAL" 2>/dev/null || true)"
if [ "${LK_REAL_ENTRIES:-0}" -ge 3 ]; then
  _pass "install-lineark: the shipped pin file carries well-formed entries (found $LK_REAL_ENTRIES)"
else
  _fail "install-lineark: the shipped pin file carries well-formed entries" \
    "expected >=3 '<sha256>  <tag>/<asset>' lines, found ${LK_REAL_ENTRIES:-0}"
fi
LK_SUMS_BODY="$(cat "$LK_SUMS_REAL" 2>/dev/null || printf '')"
assert_contains "install-lineark: the pin file pins the default tag for linux x86_64" \
  "$LK_SUMS_BODY" "v3.1.0/lineark_linux_x86_64"
assert_contains "install-lineark: the pin file pins the default tag for linux aarch64" \
  "$LK_SUMS_BODY" "v3.1.0/lineark_linux_aarch64"
assert_contains "install-lineark: the pin file pins the default tag for macos aarch64" \
  "$LK_SUMS_BODY" "v3.1.0/lineark_macos_aarch64"
assert_contains "install-lineark: the pin file names the re-vet procedure" \
  "$LK_SUMS_BODY" "linear/linear-setup.md"
# The default pin is declared exactly once in the script, and it is the tag the
# pin file covers — a bump that edits one and not the other must break loudly.
LK_SCRIPT_BODY="$(cat "$LK_SCRIPT" 2>/dev/null || printf '')"
assert_contains "install-lineark: the script declares the default pinned tag" \
  "$LK_SCRIPT_BODY" 'LINEARK_DEFAULT_VERSION="v3.1.0"'

if [ -z "$LK_ASSET" ]; then
  # No prebuilt asset for this host: the install-path cases cannot be exercised
  # here. Named skips, never silent — see the unsupported-platform case (E),
  # which IS exercised on every host via a stubbed `uname`.
  for _lk_label in \
    "install-lineark: a correct checksum installs the binary" \
    "install-lineark: a correct checksum exits 0" \
    "install-lineark: the version smoke output is printed" \
    "install-lineark: a checksum mismatch exits 1" \
    "install-lineark: a checksum mismatch installs NOTHING" \
    "install-lineark: an unvetted tag exits 1" \
    "install-lineark: an unvetted tag installs NOTHING" \
    "install-lineark: a version-smoke mismatch exits 1" \
    "install-lineark: a non-default checksum file warns about the trust root" \
    "install-lineark: a non-default base URL warns about the trust root" \
    "install-lineark: a non-default tag is announced as such" \
    "install-lineark: the installed file is re-hashed in place after the move" \
    "install-lineark: a superset version (13.1.0 vs 3.1.0) is REFUSED" \
    "install-lineark: a longer version (9.9.9.0 vs 9.9.9) is REFUSED" \
    "install-lineark: a CRLF pin file still resolves the entry" \
    "install-lineark: a pin entry with trailing whitespace still resolves" \
    "install-lineark: conflicting pin entries exit 1" \
    "install-lineark: the conflict names the offending line numbers" \
    "install-lineark: identical duplicate pin entries are accepted" \
    "install-lineark: tampering during the move is caught before execution"; do
    _skip "$_lk_label" "no upstream lineark asset for $(uname -s)/$(uname -m)"
  done
else
  _lk_fake_asset "$LK_MIRROR/$LK_VER/$LK_ASSET" "9.9.9"
  LK_GOOD_SHA="$(_lk_sha256 "$LK_MIRROR/$LK_VER/$LK_ASSET")"

  # === B. POSITIVE — correct checksum installs and the version smoke passes.
  # The fixture pin file leads with a comment and a blank line so the lookup's
  # comment-skipping is exercised by the case that must succeed.
  LK_SUMS_OK="$LK_TMP/sums-ok"
  { printf '# fixture pin file — comment lines must be skipped by the lookup\n'
    printf '\n'
    printf '%s  %s/%s\n' "$LK_GOOD_SHA" "$LK_VER" "$LK_ASSET"
  } > "$LK_SUMS_OK"

  LK_DIR_OK="$LK_TMP/bin-ok"
  _lk_run "$LK_VER" "$LK_SUMS_OK" "file://$LK_MIRROR" "$LK_DIR_OK"
  assert_eq "install-lineark: a correct checksum exits 0" "0" "$LK_RC"
  assert_contains "install-lineark: the verified sha is reported" "$LK_OUT" "sha256 verified ($LK_GOOD_SHA)"
  assert_contains "install-lineark: the version smoke output is printed" "$LK_OUT" "lineark 9.9.9"
  assert_contains "install-lineark: the success verdict names the pinned tag" "$LK_OUT" "PASS lineark $LK_VER installed and verified"
  if [ -x "$LK_DIR_OK/lineark" ]; then
    _pass "install-lineark: a correct checksum installs the binary"
  else
    _fail "install-lineark: a correct checksum installs the binary" "not an executable file: $LK_DIR_OK/lineark"
  fi

  # === B2. TRANSPARENCY, asserted on the run that SUCCEEDS. Every invocation in
  # this suite overrides the checksum file and the base URL, i.e. moves the trust
  # root off the repo defaults — that must be stated out loud, and a tag other
  # than the compiled-in default must be announced rather than silently applied
  # (a silent downgrade onto a withdrawn release is the threat).
  assert_contains "install-lineark: a non-default checksum file warns about the trust root" \
    "$LK_OUT" "WARNING non-default trust root: LINEARK_CHECKSUM_FILE=$LK_SUMS_OK"
  assert_contains "install-lineark: a non-default base URL warns about the trust root" \
    "$LK_OUT" "WARNING non-default trust root: LINEARK_BASE_URL=file://$LK_MIRROR"
  assert_contains "install-lineark: a non-default tag is announced as such" \
    "$LK_OUT" "note: installing non-default tag $LK_VER (current default: v3.1.0)"
  # POSITIVE fixture for the post-move re-hash: if this line never appeared, the
  # TOCTOU check below could be dead code and its negative case would still pass.
  assert_contains "install-lineark: the installed file is re-hashed in place after the move" \
    "$LK_OUT" "post-install sha256 re-verified in place"

  # _lk_case <name> <tag> <printed-version> — build a one-off mirror + matching
  # pin file whose sha is correct, so the case under test is the ONLY variable.
  # Sets LK_CASE_MIRROR / LK_CASE_SUMS / LK_CASE_DIR.
  _lk_case() {
    LK_CASE_MIRROR="$LK_TMP/m-$1"
    LK_CASE_SUMS="$LK_TMP/s-$1"
    LK_CASE_DIR="$LK_TMP/d-$1"
    _lk_fake_asset "$LK_CASE_MIRROR/$2/$LK_ASSET" "$3"
    printf '%s  %s/%s\n' "$(_lk_sha256 "$LK_CASE_MIRROR/$2/$LK_ASSET")" "$2" "$LK_ASSET" > "$LK_CASE_SUMS"
  }

  # === B3. EXACT version smoke. A substring test passes `lineark 13.1.0` against
  # a v3.1.0 pin — a completely different release wearing the right suffix. Both
  # directions of "contains but is not equal" are pinned.
  _lk_case "superset" "v3.1.0" "13.1.0"
  _lk_run "v3.1.0" "$LK_CASE_SUMS" "file://$LK_CASE_MIRROR" "$LK_CASE_DIR"
  assert_eq "install-lineark: a superset version (13.1.0 vs 3.1.0) is REFUSED" "1" "$LK_RC"
  assert_contains "install-lineark: the superset refusal shows the parsed token" "$LK_OUT" "parsed version: 13.1.0"
  assert_contains "install-lineark: the superset refusal states exact match is required" \
    "$LK_OUT" "exact match against 3.1.0 required"
  assert_not_contains "install-lineark: a superset version leaves no binary behind" \
    "$(ls -A "$LK_CASE_DIR" 2>/dev/null || printf '')" "lineark"

  _lk_case "longer" "$LK_VER" "9.9.9.0"
  _lk_run "$LK_VER" "$LK_CASE_SUMS" "file://$LK_CASE_MIRROR" "$LK_CASE_DIR"
  assert_eq "install-lineark: a longer version (9.9.9.0 vs 9.9.9) is REFUSED" "1" "$LK_RC"
  assert_contains "install-lineark: the longer-version refusal shows the parsed token" "$LK_OUT" "parsed version: 9.9.9.0"

  # === B4. PIN-FILE NORMALIZATION, and it is a TWIN-PARITY contract. A pin file
  # saved with CRLF endings, or an entry carrying trailing spaces, must resolve
  # the same way in both twins. Before the strip, bash refused a CRLF file as an
  # "unvetted release" while PS accepted it — the two twins disagreeing about
  # which releases are vetted is worse than either behavior alone.
  LK_SUMS_CRLF="$LK_TMP/sums-crlf"
  printf '# fixture with CRLF endings\r\n%s  %s/%s\r\n' "$LK_GOOD_SHA" "$LK_VER" "$LK_ASSET" > "$LK_SUMS_CRLF"
  LK_DIR_CRLF="$LK_TMP/bin-crlf"
  _lk_run "$LK_VER" "$LK_SUMS_CRLF" "file://$LK_MIRROR" "$LK_DIR_CRLF"
  assert_eq "install-lineark: a CRLF pin file still resolves the entry" "0" "$LK_RC"
  assert_not_contains "install-lineark: a CRLF pin file is not misread as unvetted" "$LK_OUT" "unvetted release"

  LK_SUMS_TRAIL="$LK_TMP/sums-trailing"
  printf '%s  %s/%s   \n' "$LK_GOOD_SHA" "$LK_VER" "$LK_ASSET" > "$LK_SUMS_TRAIL"
  LK_DIR_TRAIL="$LK_TMP/bin-trailing"
  _lk_run "$LK_VER" "$LK_SUMS_TRAIL" "file://$LK_MIRROR" "$LK_DIR_TRAIL"
  assert_eq "install-lineark: a pin entry with trailing whitespace still resolves" "0" "$LK_RC"

  # === B5. CONFLICTING PINS. Two entries for one key with different hashes: the
  # file cannot say which artifact is vetted, and "first match wins" would let an
  # appended line decide silently. Identical duplicates are a harmless merge
  # artifact and must still install — otherwise the guard is just a nuisance.
  LK_OTHER_SHA="1111111111111111111111111111111111111111111111111111111111111111"
  LK_SUMS_CONFLICT="$LK_TMP/sums-conflict"
  { printf '# conflicting fixture\n'
    printf '%s  %s/%s\n' "$LK_GOOD_SHA" "$LK_VER" "$LK_ASSET"
    printf '%s  %s/%s\n' "$LK_OTHER_SHA" "$LK_VER" "$LK_ASSET"
  } > "$LK_SUMS_CONFLICT"
  LK_DIR_CONFLICT="$LK_TMP/bin-conflict"
  _lk_run "$LK_VER" "$LK_SUMS_CONFLICT" "file://$LK_MIRROR" "$LK_DIR_CONFLICT"
  assert_eq "install-lineark: conflicting pin entries exit 1" "1" "$LK_RC"
  assert_contains "install-lineark: the conflict is named as such" "$LK_OUT" "FAIL conflicting pin entries"
  # Line numbers are what make the refusal actionable — the operator has to find
  # and reconcile the entries by hand.
  assert_contains "install-lineark: the conflict names the offending line numbers" "$LK_OUT" "at line(s): 2 3"
  if [ ! -e "$LK_DIR_CONFLICT/lineark" ]; then
    _pass "install-lineark: conflicting pin entries install NOTHING"
  else
    _fail "install-lineark: conflicting pin entries install NOTHING" "installed anyway: $LK_DIR_CONFLICT/lineark"
  fi

  LK_SUMS_DUP="$LK_TMP/sums-dup"
  { printf '%s  %s/%s\n' "$LK_GOOD_SHA" "$LK_VER" "$LK_ASSET"
    printf '%s  %s/%s\n' "$LK_GOOD_SHA" "$LK_VER" "$LK_ASSET"
  } > "$LK_SUMS_DUP"
  LK_DIR_DUP="$LK_TMP/bin-dup"
  _lk_run "$LK_VER" "$LK_SUMS_DUP" "file://$LK_MIRROR" "$LK_DIR_DUP"
  assert_eq "install-lineark: identical duplicate pin entries are accepted" "0" "$LK_RC"

  # === B6. TOCTOU — the artifact is swapped BETWEEN the verified read and the
  # execution. A stubbed `mv` stands in for whatever could rewrite the file
  # during the move (a cross-filesystem copy re-reading a mutating source, a
  # writable install dir). Without the post-move re-hash the swapped binary would
  # be executed; with it, the file is removed before `--version` ever runs.
  LK_MVSTUB="$LK_TMP/mvstub"
  mkdir -p "$LK_MVSTUB"
  cat > "$LK_MVSTUB/mv" <<'LKMV'
#!/bin/sh
# Stand-in for a move whose destination does not end up holding the verified
# bytes. Writes tampered content instead of the source file.
printf '#!/bin/sh\nprintf "lineark 9.9.9\\n"\nexit 0\n# tampered\n' > "$2"
chmod +x "$2"
rm -f "$1"
LKMV
  chmod +x "$LK_MVSTUB/mv"
  LK_DIR_TOCTOU="$LK_TMP/bin-toctou"
  LK_OUT="$(env \
    PATH="$LK_MVSTUB:$PATH" \
    LINEARK_VERSION="$LK_VER" \
    LINEARK_CHECKSUM_FILE="$LK_SUMS_OK" \
    LINEARK_BASE_URL="file://$LK_MIRROR" \
    LINEARK_INSTALL_DIR="$LK_DIR_TOCTOU" \
    bash "$LK_SCRIPT" 2>&1)"
  LK_RC=$?
  assert_eq "install-lineark: tampering during the move is caught before execution" "1" "$LK_RC"
  assert_contains "install-lineark: the post-install mismatch is named as such" "$LK_OUT" "FAIL post-install checksum mismatch"
  assert_contains "install-lineark: the post-install mismatch says it was NOT executed" "$LK_OUT" "NOT executed"
  # The smoke line only prints when the binary is run; its ABSENCE is the proof
  # that the re-hash fired first.
  assert_not_contains "install-lineark: the tampered binary is never executed" "$LK_OUT" "PASS lineark"
  if [ ! -e "$LK_DIR_TOCTOU/lineark" ]; then
    _pass "install-lineark: the tampered binary is removed"
  else
    _fail "install-lineark: the tampered binary is removed" "still present: $LK_DIR_TOCTOU/lineark"
  fi

  # === C. NEGATIVE — checksum mismatch. Nothing installed, both hashes named.
  LK_BAD_SHA="0000000000000000000000000000000000000000000000000000000000000000"
  LK_SUMS_BAD="$LK_TMP/sums-bad"
  printf '%s  %s/%s\n' "$LK_BAD_SHA" "$LK_VER" "$LK_ASSET" > "$LK_SUMS_BAD"

  LK_DIR_BAD="$LK_TMP/bin-bad"
  _lk_run "$LK_VER" "$LK_SUMS_BAD" "file://$LK_MIRROR" "$LK_DIR_BAD"
  assert_eq "install-lineark: a checksum mismatch exits 1" "1" "$LK_RC"
  assert_contains "install-lineark: a checksum mismatch is named as such" "$LK_OUT" "FAIL checksum mismatch"
  assert_contains "install-lineark: the mismatch prints the EXPECTED hash" "$LK_OUT" "expected: $LK_BAD_SHA"
  assert_contains "install-lineark: the mismatch prints the ACTUAL hash" "$LK_OUT" "actual:   $LK_GOOD_SHA"
  assert_contains "install-lineark: the mismatch states nothing was installed" "$LK_OUT" "NOTHING was installed"
  # Not just "no binary named lineark" — no executable artifact of ANY name may
  # survive in the install dir.
  LK_BAD_LEFTOVERS="$(find "$LK_DIR_BAD" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [ ! -e "$LK_DIR_BAD/lineark" ] && [ "$LK_BAD_LEFTOVERS" = "0" ]; then
    _pass "install-lineark: a checksum mismatch installs NOTHING"
  else
    _fail "install-lineark: a checksum mismatch installs NOTHING" \
      "files left under $LK_DIR_BAD: $LK_BAD_LEFTOVERS"
  fi

  # === D. NEGATIVE — the tag is absent from the pin file (unvetted release).
  # The pin file is valid and non-empty; it just does not cover THIS tag. That
  # distinction matters: the refusal must come from the lookup, not from an
  # unreadable file.
  LK_SUMS_OTHER="$LK_TMP/sums-other"
  printf '%s  v0.0.1/%s\n' "$LK_GOOD_SHA" "$LK_ASSET" > "$LK_SUMS_OTHER"
  LK_DIR_UNVETTED="$LK_TMP/bin-unvetted"
  _lk_run "$LK_VER" "$LK_SUMS_OTHER" "file://$LK_MIRROR" "$LK_DIR_UNVETTED"
  assert_eq "install-lineark: an unvetted tag exits 1" "1" "$LK_RC"
  assert_contains "install-lineark: an unvetted tag is named as such" "$LK_OUT" "FAIL unvetted release"
  assert_contains "install-lineark: the unvetted refusal names the missing key" "$LK_OUT" "$LK_VER/$LK_ASSET"
  assert_contains "install-lineark: the unvetted refusal points at the re-vet procedure" \
    "$LK_OUT" "linear/linear-setup.md §3.2"
  if [ ! -d "$LK_DIR_UNVETTED" ] || [ -z "$(find "$LK_DIR_UNVETTED" -type f 2>/dev/null || true)" ]; then
    _pass "install-lineark: an unvetted tag installs NOTHING"
  else
    _fail "install-lineark: an unvetted tag installs NOTHING" "files left under $LK_DIR_UNVETTED"
  fi

  # === D2. NEGATIVE — version smoke mismatch. The bytes verify, but the binary
  # reports a different version than the tag claims, so the pin file and the tag
  # disagree and the binary must not stay on PATH.
  LK_MIRROR_WRONG="$LK_TMP/mirror-wrong"
  _lk_fake_asset "$LK_MIRROR_WRONG/$LK_VER/$LK_ASSET" "1.2.3"
  LK_WRONG_SHA="$(_lk_sha256 "$LK_MIRROR_WRONG/$LK_VER/$LK_ASSET")"
  LK_SUMS_WRONG="$LK_TMP/sums-wrong"
  printf '%s  %s/%s\n' "$LK_WRONG_SHA" "$LK_VER" "$LK_ASSET" > "$LK_SUMS_WRONG"
  LK_DIR_WRONG="$LK_TMP/bin-wrong"
  _lk_run "$LK_VER" "$LK_SUMS_WRONG" "file://$LK_MIRROR_WRONG" "$LK_DIR_WRONG"
  assert_eq "install-lineark: a version-smoke mismatch exits 1" "1" "$LK_RC"
  assert_contains "install-lineark: the smoke failure is named as such" "$LK_OUT" "FAIL version smoke failed"
  assert_contains "install-lineark: the smoke failure quotes what --version said" "$LK_OUT" "lineark 1.2.3"
  assert_contains "install-lineark: the smoke failure names the pinned version" "$LK_OUT" "pinned version 9.9.9"
  if [ ! -e "$LK_DIR_WRONG/lineark" ]; then
    _pass "install-lineark: a version-smoke mismatch removes the installed binary"
  else
    _fail "install-lineark: a version-smoke mismatch removes the installed binary" \
      "still present: $LK_DIR_WRONG/lineark"
  fi
fi

# === E. Unsupported platform — exercised on EVERY host by stubbing `uname`
# ahead of the script's PATH, so this path is never a dead branch.
LK_STUB="$LK_TMP/stub"
mkdir -p "$LK_STUB"
cat > "$LK_STUB/uname" <<'LKUNAME'
#!/bin/sh
case "$1" in
  -s) printf 'Darwin\n' ;;
  -m) printf 'x86_64\n' ;;
  *)  printf 'Darwin\n' ;;
esac
LKUNAME
chmod +x "$LK_STUB/uname"

LK_DIR_UNSUP="$LK_TMP/bin-unsup"
LK_OUT="$(env \
  PATH="$LK_STUB:$PATH" \
  LINEARK_VERSION="$LK_VER" \
  LINEARK_CHECKSUM_FILE="$LK_SUMS_REAL" \
  LINEARK_BASE_URL="file://$LK_MIRROR" \
  LINEARK_INSTALL_DIR="$LK_DIR_UNSUP" \
  bash "$LK_SCRIPT" 2>&1)"
LK_RC=$?
assert_eq "install-lineark: an unsupported platform exits 3" "3" "$LK_RC"
assert_contains "install-lineark: the unsupported platform is named" "$LK_OUT" "unsupported platform: Darwin/x86_64"
assert_contains "install-lineark: the unsupported path offers the cargo alternative" "$LK_OUT" "cargo install lineark"
assert_contains "install-lineark: the unsupported path offers the Linear MCP fallback" \
  "$LK_OUT" "linear/linear-setup.md §3.3"
if [ ! -d "$LK_DIR_UNSUP" ]; then
  _pass "install-lineark: an unsupported platform installs NOTHING"
else
  _fail "install-lineark: an unsupported platform installs NOTHING" "created: $LK_DIR_UNSUP"
fi

# === E2. LINEARK_BASE_URL scheme allowlist. Only https:// and file:// are
# accepted; plain http:// is the transport this installer exists to stop
# trusting, so it is refused before anything is fetched. Platform-independent:
# the guard runs before platform detection.
LK_OUT="$(env \
  LINEARK_VERSION="$LK_VER" \
  LINEARK_CHECKSUM_FILE="$LK_SUMS_REAL" \
  LINEARK_BASE_URL="http://example.invalid/releases" \
  LINEARK_INSTALL_DIR="$LK_TMP/bin-scheme" \
  bash "$LK_SCRIPT" 2>&1)"
LK_RC=$?
assert_eq "install-lineark: a plain http:// base URL exits 2" "2" "$LK_RC"
assert_contains "install-lineark: the scheme refusal names the offending URL" \
  "$LK_OUT" "disallowed LINEARK_BASE_URL scheme: http://example.invalid/releases"
assert_contains "install-lineark: the scheme refusal states the allowlist" "$LK_OUT" "Only https:// and file:// are accepted"
# The allowed schemes must NOT be caught by the same guard — a guard that
# refuses everything would pass the assertion above while breaking every install.
LK_OUT="$(env \
  LINEARK_VERSION="v0.0.0-absent" \
  LINEARK_CHECKSUM_FILE="$LK_SUMS_REAL" \
  LINEARK_BASE_URL="https://example.invalid/releases" \
  LINEARK_INSTALL_DIR="$LK_TMP/bin-scheme-ok" \
  bash "$LK_SCRIPT" 2>&1)"
LK_RC=$?
assert_not_contains "install-lineark: an https:// base URL passes the scheme guard" \
  "$LK_OUT" "disallowed LINEARK_BASE_URL scheme"

# === E3. LINEARK_VERSION syntax guard. The tag becomes a path segment in the
# download URL and the lookup key, so a traversal shape is refused outright
# rather than sanitized.
LK_OUT="$(env \
  LINEARK_VERSION="../v3.1.0" \
  LINEARK_CHECKSUM_FILE="$LK_SUMS_REAL" \
  LINEARK_BASE_URL="file://$LK_MIRROR" \
  LINEARK_INSTALL_DIR="$LK_TMP/bin-version-syntax" \
  bash "$LK_SCRIPT" 2>&1)"
LK_RC=$?
assert_eq "install-lineark: a traversal-shaped LINEARK_VERSION exits 2" "2" "$LK_RC"
assert_contains "install-lineark: the version-syntax refusal names the value" "$LK_OUT" "malformed LINEARK_VERSION: ../v3.1.0"
assert_contains "install-lineark: the version-syntax refusal states the allowed shape" \
  "$LK_OUT" "^v?[A-Za-z0-9._-]+$"

# === F. Usage error — an unknown flag is exit 2, not a silently ignored word.
LK_OUT="$(env \
  LINEARK_VERSION="$LK_VER" \
  LINEARK_CHECKSUM_FILE="$LK_SUMS_REAL" \
  LINEARK_BASE_URL="file://$LK_MIRROR" \
  LINEARK_INSTALL_DIR="$LK_TMP/bin-usage" \
  bash "$LK_SCRIPT" --force 2>&1)"
LK_RC=$?
assert_eq "install-lineark: an unknown flag exits 2" "2" "$LK_RC"
assert_contains "install-lineark: the usage error names the offending argument" "$LK_OUT" "unknown argument: --force"

# === G. The docs no longer teach the unpinned curl-to-shell install.
LK_SETUP_BODY="$(cat "$REPO_ROOT/linear/linear-setup.md" 2>/dev/null || printf '')"
assert_not_contains "install-lineark: linear-setup.md no longer pipes the upstream installer into a shell" \
  "$LK_SETUP_BODY" "install.sh | sh"
assert_contains "install-lineark: linear-setup.md documents the pinned installer" \
  "$LK_SETUP_BODY" "bash scripts/install-lineark.sh"
assert_contains "install-lineark: linear-setup.md documents the pwsh form" \
  "$LK_SETUP_BODY" "scripts/install-lineark.ps1"
assert_contains "install-lineark: linear-setup.md documents the re-vet procedure" \
  "$LK_SETUP_BODY" "Updating / re-vetting a new release"
assert_contains "install-lineark: linear-setup.md documents the rollback lever" \
  "$LK_SETUP_BODY" "LINEARK_VERSION="
assert_contains "install-lineark: linear-setup.md names the checksum pin file" \
  "$LK_SETUP_BODY" "scripts/lineark-checksums.sha256"
# Revocation is the half operators forget: keeping old entries enables rollback,
# and DELETING one is the only way to make a withdrawn release un-installable.
# Both halves must be stated, in the doc and in the pin file's own comments.
assert_contains "install-lineark: linear-setup.md documents revocation by entry removal" \
  "$LK_SETUP_BODY" "Removing an entry from"
assert_contains "install-lineark: linear-setup.md says a revoked tag becomes unvetted" \
  "$LK_SETUP_BODY" "refuses that tag as an unvetted release"
assert_contains "install-lineark: the pin file documents revocation by entry removal" \
  "$LK_SUMS_BODY" "REVOCATION mechanism"
assert_contains "install-lineark: the pin file says old tags are kept for rollback" \
  "$LK_SUMS_BODY" "KEEPING old tags listed is deliberate"

LK_README_BODY="$(cat "$REPO_ROOT/README.md" 2>/dev/null || printf '')"
assert_not_contains "install-lineark: README no longer says the lineark doc reproduces curl-to-shell" \
  "$LK_README_BODY" "reproduce the upstream installer's"
assert_contains "install-lineark: README points at the pinned installer" \
  "$LK_README_BODY" "scripts/install-lineark.sh"

# Inline cleanup — tests/run.sh sources this file, so an EXIT trap would fire for
# every subsequent test.
rm -rf "$LK_TMP"
