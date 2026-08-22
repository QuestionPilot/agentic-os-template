#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/install-linear-cli.test.sh — behavioral tests for
# scripts/install-linear-cli.sh, the pinned checksum-verified installer for the
# `linear` CLI (schpet/linear-cli).
#
# What is under test is the REFUSAL contract, because that is the whole reason
# the script exists — an installer that happily installs is indistinguishable
# from `curl | sh`:
#
#   - correct checksum              -> installs, version smoke passes, exit 0
#   - checksum MISMATCH             -> exit 1, artifact deleted, nothing
#                                      installed, expected vs actual printed
#   - tag ABSENT from the pin file  -> exit 1, "unvetted release", nothing
#                                      installed, re-vet procedure named
#   - version smoke MISMATCH        -> exit 1, the binary removed again
#   - unsupported platform          -> exit 3, both documented alternatives named
#
# The release asset is an ARCHIVE (tar.xz on
# macOS/Linux, zip on Windows) containing the binary, so the archive-shape
# refusals are pinned too — an archive holding TWO candidate binaries and an
# archive holding NONE are both exit 1 ("expected exactly one"), never a guess.
#
# HERMETIC. No network: the release mirror is a local directory served through
# `file://`, and the "binary" inside the archive is a two-line /bin/sh script so
# `--version` works (Git Bash executes a shebang script even when it is named
# linear.exe, which is what the MINGW lane installs). EVERY invocation pins
# LINEAR_CLI_VERSION, LINEAR_CLI_CHECKSUM_FILE, LINEAR_CLI_BASE_URL and
# LINEAR_CLI_INSTALL_DIR, so the operator's real pin file, real install dir and
# real network are never reachable from this suite.
#
# Sourced by tests/run.sh; do NOT set -e or call exit.

LC_SCRIPT="$REPO_ROOT/scripts/install-linear-cli.sh"
LC_SUMS_REAL="$REPO_ROOT/scripts/linear-cli-checksums.sha256"

assert_file "install-linear-cli: scripts/install-linear-cli.sh exists" "$LC_SCRIPT"
assert_file "install-linear-cli: scripts/linear-cli-checksums.sha256 exists" "$LC_SUMS_REAL"
assert_file "install-linear-cli: the PowerShell twin exists" "$REPO_ROOT/scripts/install-linear-cli.ps1"

# The docs tell operators to run it directly; a 644 file turns that into
# "permission denied" for everyone who copies the documented command.
if [ -x "$LC_SCRIPT" ]; then
  _pass "install-linear-cli: the installer is executable"
else
  _fail "install-linear-cli: the installer is executable" "not executable: $LC_SCRIPT"
fi

# --- sha256 helper: the same probe order the script uses --------------------
_lc_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# --- host -> asset name + binname, mirroring the script's own platform map ---
LC_ASSET=""
LC_BIN="linear"
case "$(uname -s)" in
  Linux)
    case "$(uname -m)" in
      x86_64|amd64)  LC_ASSET="linear-x86_64-unknown-linux-gnu.tar.xz" ;;
      aarch64|arm64) LC_ASSET="linear-aarch64-unknown-linux-gnu.tar.xz" ;;
    esac
    ;;
  Darwin)
    case "$(uname -m)" in
      arm64|aarch64) LC_ASSET="linear-aarch64-apple-darwin.tar.xz" ;;
      x86_64)        LC_ASSET="linear-x86_64-apple-darwin.tar.xz" ;;
    esac
    ;;
  MINGW*|MSYS*|CYGWIN*)
    case "$(uname -m)" in
      x86_64|amd64)  LC_ASSET="linear-x86_64-pc-windows-msvc.zip"; LC_BIN="linear.exe" ;;
    esac
    ;;
esac

LC_TMP="$(mktemp -d)"
LC_VER="v9.9.9"
LC_MIRROR="$LC_TMP/mirror"

# _lc_fileurl <dir> — a file:// URL curl can actually open. Git Bash's curl is a
# NATIVE Windows build: file:///tmp/... resolves against the current drive, not
# the MSYS root, so the Windows lane must hand it the Windows-form path.
_lc_fileurl() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) printf 'file:///%s' "$(cygpath -m "$1")" ;;
    *)                    printf 'file://%s' "$1" ;;
  esac
}

# _lc_run <version> <sums-file> <base-url> <install-dir> — run the installer with
# EVERY override pinned; sets LC_OUT (combined) plus LC_STDOUT / LC_STDERR, and
# LC_RC. Split capture exists so the trust-root warnings can be pinned to STDERR
# specifically, not just "somewhere in the output". Nothing is inherited from the
# operator's environment.
_lc_run() {
  env \
    LINEAR_CLI_VERSION="$1" \
    LINEAR_CLI_CHECKSUM_FILE="$2" \
    LINEAR_CLI_BASE_URL="$3" \
    LINEAR_CLI_INSTALL_DIR="$4" \
    bash "$LC_SCRIPT" >"$LC_TMP/.out" 2>"$LC_TMP/.err"
  LC_RC=$?
  LC_STDOUT="$(cat "$LC_TMP/.out")"
  LC_STDERR="$(cat "$LC_TMP/.err")"
  LC_OUT="$LC_STDOUT
$LC_STDERR"
}

# _lc_stub <path> <version-string> — the stand-in binary that goes INSIDE the
# archive: a real executable so the version smoke is exercised rather than
# stubbed out. The version banner is wrapped in ANSI color the way the real CLI
# colors its own, so the installer's ANSI stripping is on the hook every run.
_lc_stub() {
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\nprintf "\\033[1mlinear\\033[0m %s\\n"\n' "$2" > "$1"
  chmod +x "$1"
}

# _lc_pack <srcdir> <out-archive> — pack the dir's CONTENTS into the archive the
# platform map will request: tar.xz via `tar -cJf`, zip via whichever zip writer
# this host has (the `zip` CLI, Windows' bundled bsdtar, or Compress-Archive).
_lc_pack() {
  case "$2" in
    *.tar.xz)
      tar -C "$1" -cJf "$2" .
      ;;
    *.zip)
      if command -v zip >/dev/null 2>&1; then
        (cd "$1" && zip -qr "$2" .)
      elif [ -x /c/Windows/System32/tar.exe ]; then
        /c/Windows/System32/tar.exe -a -cf "$2" -C "$1" .
      else
        pwsh -NoProfile -Command \
          "Compress-Archive -Path '$(cygpath -w "$1")\\*' -DestinationPath '$(cygpath -w "$2")'"
      fi
      ;;
  esac
}

# _lc_release <mirror> <tag> <printed-version> — a complete fake release: stub
# binary packed into the platform-appropriate archive at <mirror>/<tag>/<asset>.
_lc_release() {
  local src="$LC_TMP/src-$RANDOM$RANDOM"
  mkdir -p "$src" "$1/$2"
  _lc_stub "$src/$LC_BIN" "$3"
  _lc_pack "$src" "$1/$2/$LC_ASSET"
  rm -rf "$src"
}

# === A. The pin file the framework actually ships parses and is well-formed.
# A POSITIVE fixture for the lookup parser: without it, a lookup that matched
# nothing at all would still pass every refusal test below.
LC_REAL_ENTRIES="$(grep -cE '^[0-9a-f]{64}[[:space:]]+v[0-9]+\.[0-9]+\.[0-9]+/linear-' "$LC_SUMS_REAL" 2>/dev/null || true)"
if [ "${LC_REAL_ENTRIES:-0}" -ge 5 ]; then
  _pass "install-linear-cli: the shipped pin file carries well-formed entries (found $LC_REAL_ENTRIES)"
else
  _fail "install-linear-cli: the shipped pin file carries well-formed entries" \
    "expected >=5 '<sha256>  <tag>/<asset>' lines, found ${LC_REAL_ENTRIES:-0}"
fi
LC_SUMS_BODY="$(cat "$LC_SUMS_REAL" 2>/dev/null || printf '')"
assert_contains "install-linear-cli: the pin file pins the default tag for linux x86_64" \
  "$LC_SUMS_BODY" "v2.5.0/linear-x86_64-unknown-linux-gnu.tar.xz"
assert_contains "install-linear-cli: the pin file pins the default tag for linux aarch64" \
  "$LC_SUMS_BODY" "v2.5.0/linear-aarch64-unknown-linux-gnu.tar.xz"
assert_contains "install-linear-cli: the pin file pins the default tag for macos arm64" \
  "$LC_SUMS_BODY" "v2.5.0/linear-aarch64-apple-darwin.tar.xz"
assert_contains "install-linear-cli: the pin file pins the default tag for macos x86_64" \
  "$LC_SUMS_BODY" "v2.5.0/linear-x86_64-apple-darwin.tar.xz"
assert_contains "install-linear-cli: the pin file pins the default tag for windows x86_64" \
  "$LC_SUMS_BODY" "v2.5.0/linear-x86_64-pc-windows-msvc.zip"
assert_contains "install-linear-cli: the pin file names the re-vet procedure" \
  "$LC_SUMS_BODY" "linear/linear-setup.md"
# The default pin is declared exactly once in the script, and it is the tag the
# pin file covers — a bump that edits one and not the other must break loudly.
LC_SCRIPT_BODY="$(cat "$LC_SCRIPT" 2>/dev/null || printf '')"
assert_contains "install-linear-cli: the script declares the default pinned tag" \
  "$LC_SCRIPT_BODY" 'LINEAR_CLI_DEFAULT_VERSION="v2.5.0"'

if [ -z "$LC_ASSET" ]; then
  # No prebuilt asset for this host: the install-path cases cannot be exercised
  # here. Named skips, never silent — see the unsupported-platform case (E),
  # which IS exercised on every host via a stubbed `uname`.
  for _lc_label in \
    "install-linear-cli: a correct checksum installs the binary" \
    "install-linear-cli: a correct checksum exits 0" \
    "install-linear-cli: the archive sha is verified and reported" \
    "install-linear-cli: the version smoke output is printed" \
    "install-linear-cli: the success verdict names the pinned tag" \
    "install-linear-cli: the installed file is re-hashed in place after the move" \
    "install-linear-cli: the trust-root warnings go to STDERR" \
    "install-linear-cli: a non-default checksum file warns about the trust root" \
    "install-linear-cli: a non-default base URL warns about the trust root" \
    "install-linear-cli: a non-default tag is announced as such" \
    "install-linear-cli: a CRLF pin file still resolves the entry" \
    "install-linear-cli: a pin entry with trailing whitespace still resolves" \
    "install-linear-cli: conflicting pin entries exit 1" \
    "install-linear-cli: the conflict names the offending line numbers" \
    "install-linear-cli: identical duplicate pin entries are accepted" \
    "install-linear-cli: a checksum mismatch exits 1" \
    "install-linear-cli: a checksum mismatch installs NOTHING" \
    "install-linear-cli: an unvetted tag exits 1" \
    "install-linear-cli: an unvetted tag installs NOTHING" \
    "install-linear-cli: a version-smoke mismatch exits 1" \
    "install-linear-cli: a version-smoke mismatch removes the installed binary" \
    "install-linear-cli: a version-smoke mismatch leaves no staged file behind" \
    "install-linear-cli: upgrade fixture: the initial install succeeds" \
    "install-linear-cli: a failed-smoke upgrade exits 1" \
    "install-linear-cli: a failed-smoke upgrade preserves the previous binary" \
    "install-linear-cli: the preserved binary still reports its original version" \
    "install-linear-cli: a failed-smoke upgrade leaves no staged file behind" \
    "install-linear-cli: an archive with TWO candidate binaries is REFUSED" \
    "install-linear-cli: an archive with NO candidate binary is REFUSED"; do
    _skip "$_lc_label" "no upstream linear-cli asset for $(uname -s)/$(uname -m)"
  done
else
  _lc_release "$LC_MIRROR" "$LC_VER" "9.9.9"
  LC_GOOD_SHA="$(_lc_sha256 "$LC_MIRROR/$LC_VER/$LC_ASSET")"
  LC_MIRROR_URL="$(_lc_fileurl "$LC_MIRROR")"

  # === B. POSITIVE — correct checksum installs and the version smoke passes.
  # The fixture pin file leads with a comment and a blank line so the lookup's
  # comment-skipping is exercised by the case that must succeed.
  LC_SUMS_OK="$LC_TMP/sums-ok"
  { printf '# fixture pin file — comment lines must be skipped by the lookup\n'
    printf '\n'
    printf '%s  %s/%s\n' "$LC_GOOD_SHA" "$LC_VER" "$LC_ASSET"
  } > "$LC_SUMS_OK"

  LC_DIR_OK="$LC_TMP/bin-ok"
  _lc_run "$LC_VER" "$LC_SUMS_OK" "$LC_MIRROR_URL" "$LC_DIR_OK"
  assert_eq "install-linear-cli: a correct checksum exits 0" "0" "$LC_RC"
  assert_contains "install-linear-cli: the archive sha is verified and reported" \
    "$LC_OUT" "archive sha256 verified ($LC_GOOD_SHA)"
  assert_contains "install-linear-cli: the version smoke output is printed" "$LC_OUT" "9.9.9"
  assert_contains "install-linear-cli: the success verdict names the pinned tag" \
    "$LC_OUT" "PASS linear-cli $LC_VER installed and verified"
  if [ -x "$LC_DIR_OK/$LC_BIN" ]; then
    _pass "install-linear-cli: a correct checksum installs the binary"
  else
    _fail "install-linear-cli: a correct checksum installs the binary" "not an executable file: $LC_DIR_OK/$LC_BIN"
  fi

  # === B2. TRANSPARENCY, asserted on the run that SUCCEEDS, and pinned to the
  # STREAM. Every invocation in this suite overrides the checksum file and the
  # base URL, i.e. moves the trust root off the repo defaults — that must be
  # stated out loud ON STDERR (diagnostics never pollute machine-readable
  # stdout), and a tag other than the compiled-in default must be announced
  # rather than silently applied (a silent downgrade onto a withdrawn release is
  # the threat).
  assert_contains "install-linear-cli: a non-default checksum file warns about the trust root" \
    "$LC_STDERR" "WARNING non-default trust root: LINEAR_CLI_CHECKSUM_FILE=$LC_SUMS_OK"
  assert_contains "install-linear-cli: a non-default base URL warns about the trust root" \
    "$LC_STDERR" "WARNING non-default trust root: LINEAR_CLI_BASE_URL=$LC_MIRROR_URL"
  assert_not_contains "install-linear-cli: the trust-root warnings go to STDERR" \
    "$LC_STDOUT" "WARNING non-default trust root"
  assert_contains "install-linear-cli: a non-default tag is announced as such" \
    "$LC_STDOUT" "note: installing non-default tag $LC_VER (current default: v2.5.0)"
  # POSITIVE fixture for the post-move re-hash: if this line never appeared, the
  # TOCTOU re-verify could be dead code and nothing here would notice.
  assert_contains "install-linear-cli: the installed file is re-hashed in place after the move" \
    "$LC_OUT" "post-install sha256 re-verified in place"

  # === B4. PIN-FILE NORMALIZATION, and it is a TWIN-PARITY contract. A pin file
  # saved with CRLF endings, or an entry carrying trailing spaces, must resolve
  # the same way in both twins — the two disagreeing about which releases are
  # vetted is worse than either behavior alone.
  LC_SUMS_CRLF="$LC_TMP/sums-crlf"
  printf '# fixture with CRLF endings\r\n%s  %s/%s\r\n' "$LC_GOOD_SHA" "$LC_VER" "$LC_ASSET" > "$LC_SUMS_CRLF"
  _lc_run "$LC_VER" "$LC_SUMS_CRLF" "$LC_MIRROR_URL" "$LC_TMP/bin-crlf"
  assert_eq "install-linear-cli: a CRLF pin file still resolves the entry" "0" "$LC_RC"
  assert_not_contains "install-linear-cli: a CRLF pin file is not misread as unvetted" "$LC_OUT" "unvetted release"

  LC_SUMS_TRAIL="$LC_TMP/sums-trailing"
  printf '%s  %s/%s   \n' "$LC_GOOD_SHA" "$LC_VER" "$LC_ASSET" > "$LC_SUMS_TRAIL"
  _lc_run "$LC_VER" "$LC_SUMS_TRAIL" "$LC_MIRROR_URL" "$LC_TMP/bin-trailing"
  assert_eq "install-linear-cli: a pin entry with trailing whitespace still resolves" "0" "$LC_RC"

  # === B5. CONFLICTING PINS. Two entries for one key with different hashes: the
  # file cannot say which artifact is vetted, and "first match wins" would let an
  # appended line decide silently. Identical duplicates are a harmless merge
  # artifact and must still install — otherwise the guard is just a nuisance.
  LC_OTHER_SHA="1111111111111111111111111111111111111111111111111111111111111111"
  LC_SUMS_CONFLICT="$LC_TMP/sums-conflict"
  { printf '# conflicting fixture\n'
    printf '%s  %s/%s\n' "$LC_GOOD_SHA" "$LC_VER" "$LC_ASSET"
    printf '%s  %s/%s\n' "$LC_OTHER_SHA" "$LC_VER" "$LC_ASSET"
  } > "$LC_SUMS_CONFLICT"
  LC_DIR_CONFLICT="$LC_TMP/bin-conflict"
  _lc_run "$LC_VER" "$LC_SUMS_CONFLICT" "$LC_MIRROR_URL" "$LC_DIR_CONFLICT"
  assert_eq "install-linear-cli: conflicting pin entries exit 1" "1" "$LC_RC"
  assert_contains "install-linear-cli: the conflict is named as such" "$LC_OUT" "FAIL conflicting pin entries"
  # Line numbers are what make the refusal actionable — the operator has to find
  # and reconcile the entries by hand.
  assert_contains "install-linear-cli: the conflict names the offending line numbers" "$LC_OUT" "at line(s): 2 3"
  if [ ! -e "$LC_DIR_CONFLICT/$LC_BIN" ]; then
    _pass "install-linear-cli: conflicting pin entries install NOTHING"
  else
    _fail "install-linear-cli: conflicting pin entries install NOTHING" "installed anyway: $LC_DIR_CONFLICT/$LC_BIN"
  fi

  LC_SUMS_DUP="$LC_TMP/sums-dup"
  { printf '%s  %s/%s\n' "$LC_GOOD_SHA" "$LC_VER" "$LC_ASSET"
    printf '%s  %s/%s\n' "$LC_GOOD_SHA" "$LC_VER" "$LC_ASSET"
  } > "$LC_SUMS_DUP"
  _lc_run "$LC_VER" "$LC_SUMS_DUP" "$LC_MIRROR_URL" "$LC_TMP/bin-dup"
  assert_eq "install-linear-cli: identical duplicate pin entries are accepted" "0" "$LC_RC"

  # === C. NEGATIVE — checksum mismatch. The archive is deleted, nothing is
  # installed, and both hashes are named so the operator can compare them
  # against upstream's manifest by eye.
  LC_BAD_SHA="0000000000000000000000000000000000000000000000000000000000000000"
  LC_SUMS_BAD="$LC_TMP/sums-bad"
  printf '%s  %s/%s\n' "$LC_BAD_SHA" "$LC_VER" "$LC_ASSET" > "$LC_SUMS_BAD"
  LC_DIR_BAD="$LC_TMP/bin-bad"
  _lc_run "$LC_VER" "$LC_SUMS_BAD" "$LC_MIRROR_URL" "$LC_DIR_BAD"
  assert_eq "install-linear-cli: a checksum mismatch exits 1" "1" "$LC_RC"
  assert_contains "install-linear-cli: a checksum mismatch is named as such" "$LC_OUT" "FAIL checksum mismatch"
  assert_contains "install-linear-cli: the mismatch prints the EXPECTED hash" "$LC_OUT" "expected: $LC_BAD_SHA"
  assert_contains "install-linear-cli: the mismatch prints the ACTUAL hash" "$LC_OUT" "actual:   $LC_GOOD_SHA"
  assert_contains "install-linear-cli: the mismatch says the artifact was deleted" \
    "$LC_OUT" "The downloaded artifact was deleted and NOTHING was installed"
  # Not just "no binary named linear" — no artifact of ANY name may survive in
  # the install dir.
  LC_BAD_LEFTOVERS="$(find "$LC_DIR_BAD" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [ ! -e "$LC_DIR_BAD/$LC_BIN" ] && [ "$LC_BAD_LEFTOVERS" = "0" ]; then
    _pass "install-linear-cli: a checksum mismatch installs NOTHING"
  else
    _fail "install-linear-cli: a checksum mismatch installs NOTHING" \
      "files left under $LC_DIR_BAD: $LC_BAD_LEFTOVERS"
  fi

  # === D. NEGATIVE — the tag is absent from the pin file (unvetted release).
  # The pin file is valid and non-empty; it just does not cover THIS tag. That
  # distinction matters: the refusal must come from the lookup, not from an
  # unreadable file.
  LC_SUMS_OTHER="$LC_TMP/sums-other"
  printf '%s  v0.0.1/%s\n' "$LC_GOOD_SHA" "$LC_ASSET" > "$LC_SUMS_OTHER"
  LC_DIR_UNVETTED="$LC_TMP/bin-unvetted"
  _lc_run "$LC_VER" "$LC_SUMS_OTHER" "$LC_MIRROR_URL" "$LC_DIR_UNVETTED"
  assert_eq "install-linear-cli: an unvetted tag exits 1" "1" "$LC_RC"
  assert_contains "install-linear-cli: an unvetted tag is named as such" "$LC_OUT" "FAIL unvetted release"
  assert_contains "install-linear-cli: the unvetted refusal names the missing key" "$LC_OUT" "$LC_VER/$LC_ASSET"
  assert_contains "install-linear-cli: the unvetted refusal points at the re-vet procedure" \
    "$LC_OUT" "linear/linear-setup.md §3.2"
  if [ ! -d "$LC_DIR_UNVETTED" ] || [ -z "$(find "$LC_DIR_UNVETTED" -type f 2>/dev/null || true)" ]; then
    _pass "install-linear-cli: an unvetted tag installs NOTHING"
  else
    _fail "install-linear-cli: an unvetted tag installs NOTHING" "files left under $LC_DIR_UNVETTED"
  fi

  # === D2. NEGATIVE — version smoke mismatch. The bytes verify, but the binary
  # reports a different version than the tag claims, so the pin file and the tag
  # disagree and the binary must not stay on PATH.
  LC_MIRROR_WRONG="$LC_TMP/mirror-wrong"
  _lc_release "$LC_MIRROR_WRONG" "$LC_VER" "1.2.3"
  LC_SUMS_WRONG="$LC_TMP/sums-wrong"
  printf '%s  %s/%s\n' "$(_lc_sha256 "$LC_MIRROR_WRONG/$LC_VER/$LC_ASSET")" "$LC_VER" "$LC_ASSET" > "$LC_SUMS_WRONG"
  LC_DIR_WRONG="$LC_TMP/bin-wrong"
  _lc_run "$LC_VER" "$LC_SUMS_WRONG" "$(_lc_fileurl "$LC_MIRROR_WRONG")" "$LC_DIR_WRONG"
  assert_eq "install-linear-cli: a version-smoke mismatch exits 1" "1" "$LC_RC"
  assert_contains "install-linear-cli: the smoke failure is named as such" "$LC_OUT" "FAIL version smoke failed"
  assert_contains "install-linear-cli: the smoke failure shows the parsed token" "$LC_OUT" "parsed version: 1.2.3"
  assert_contains "install-linear-cli: the smoke failure names the pinned version" "$LC_OUT" "pinned version 9.9.9"
  if [ ! -e "$LC_DIR_WRONG/$LC_BIN" ]; then
    _pass "install-linear-cli: a version-smoke mismatch removes the installed binary"
  else
    _fail "install-linear-cli: a version-smoke mismatch removes the installed binary" \
      "still present: $LC_DIR_WRONG/$LC_BIN"
  fi
  # With staging, the candidate never reaches $dest on a smoke failure: the
  # STAGED file must be deleted and no file of ANY name may remain (there was no
  # prior install here, so $dest simply never appears).
  LC_WRONG_LEFT="$(find "$LC_DIR_WRONG" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$LC_WRONG_LEFT" = "0" ]; then
    _pass "install-linear-cli: a version-smoke mismatch leaves no staged file behind"
  else
    _fail "install-linear-cli: a version-smoke mismatch leaves no staged file behind" \
      "files left under $LC_DIR_WRONG: $LC_WRONG_LEFT"
  fi

  # === D2c. REGRESSION — a failed upgrade preserves the previous installation.
  # Install a WORKING binary first, then attempt an upgrade whose version smoke
  # FAILS (the candidate prints the wrong version). The staged candidate must be
  # deleted while the ORIGINAL binary survives at $dest and still executes with
  # its original version output — "nothing is left installed" means the previous
  # state is preserved, not that a working install is deleted.
  LC_DIR_UPG="$LC_TMP/bin-upgrade"
  _lc_run "$LC_VER" "$LC_SUMS_OK" "$LC_MIRROR_URL" "$LC_DIR_UPG"
  assert_eq "install-linear-cli: upgrade fixture: the initial install succeeds" "0" "$LC_RC"
  _lc_run "$LC_VER" "$LC_SUMS_WRONG" "$(_lc_fileurl "$LC_MIRROR_WRONG")" "$LC_DIR_UPG"
  assert_eq "install-linear-cli: a failed-smoke upgrade exits 1" "1" "$LC_RC"
  if [ -x "$LC_DIR_UPG/$LC_BIN" ]; then
    _pass "install-linear-cli: a failed-smoke upgrade preserves the previous binary"
  else
    _fail "install-linear-cli: a failed-smoke upgrade preserves the previous binary" \
      "missing or not executable: $LC_DIR_UPG/$LC_BIN"
  fi
  LC_UPG_OUT="$("$LC_DIR_UPG/$LC_BIN" --version 2>&1 || true)"
  assert_contains "install-linear-cli: the preserved binary still reports its original version" \
    "$LC_UPG_OUT" "9.9.9"
  LC_UPG_FILES="$(find "$LC_DIR_UPG" -type f 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "install-linear-cli: a failed-smoke upgrade leaves no staged file behind" "1" "$LC_UPG_FILES"

  # === D3. NEGATIVE, archive-specific — TWO candidate binaries inside one
  # verified archive. The pin covers the archive, not the binary, so an archive
  # that offers a CHOICE of binaries is a refusal: picking either one would
  # execute a file the vetting never singled out.
  LC_SRC_TWO="$LC_TMP/src-two"
  mkdir -p "$LC_SRC_TWO/nested"
  _lc_stub "$LC_SRC_TWO/$LC_BIN" "9.9.9"
  _lc_stub "$LC_SRC_TWO/nested/$LC_BIN" "6.6.6"
  LC_MIRROR_TWO="$LC_TMP/mirror-two"
  mkdir -p "$LC_MIRROR_TWO/$LC_VER"
  _lc_pack "$LC_SRC_TWO" "$LC_MIRROR_TWO/$LC_VER/$LC_ASSET"
  LC_SUMS_TWO="$LC_TMP/sums-two"
  printf '%s  %s/%s\n' "$(_lc_sha256 "$LC_MIRROR_TWO/$LC_VER/$LC_ASSET")" "$LC_VER" "$LC_ASSET" > "$LC_SUMS_TWO"
  LC_DIR_TWO="$LC_TMP/bin-two"
  _lc_run "$LC_VER" "$LC_SUMS_TWO" "$(_lc_fileurl "$LC_MIRROR_TWO")" "$LC_DIR_TWO"
  assert_eq "install-linear-cli: an archive with TWO candidate binaries is REFUSED" "1" "$LC_RC"
  assert_contains "install-linear-cli: the two-binary refusal says exactly one is expected" \
    "$LC_OUT" "expected exactly one $LC_BIN"
  assert_contains "install-linear-cli: the two-binary refusal reports the count found" "$LC_OUT" "found 2"
  if [ ! -e "$LC_DIR_TWO/$LC_BIN" ]; then
    _pass "install-linear-cli: an archive with TWO candidate binaries installs NOTHING"
  else
    _fail "install-linear-cli: an archive with TWO candidate binaries installs NOTHING" \
      "installed anyway: $LC_DIR_TWO/$LC_BIN"
  fi

  # === D4. NEGATIVE, archive-specific — NO candidate binary inside the archive.
  # A verified archive that does not contain the promised binary is the same
  # refusal from the other side: found 0, nothing to install, exit 1.
  LC_SRC_NONE="$LC_TMP/src-none"
  mkdir -p "$LC_SRC_NONE"
  printf 'not a binary\n' > "$LC_SRC_NONE/README.txt"
  LC_MIRROR_NONE="$LC_TMP/mirror-none"
  mkdir -p "$LC_MIRROR_NONE/$LC_VER"
  _lc_pack "$LC_SRC_NONE" "$LC_MIRROR_NONE/$LC_VER/$LC_ASSET"
  LC_SUMS_NONE="$LC_TMP/sums-none"
  printf '%s  %s/%s\n' "$(_lc_sha256 "$LC_MIRROR_NONE/$LC_VER/$LC_ASSET")" "$LC_VER" "$LC_ASSET" > "$LC_SUMS_NONE"
  LC_DIR_NONE="$LC_TMP/bin-none"
  _lc_run "$LC_VER" "$LC_SUMS_NONE" "$(_lc_fileurl "$LC_MIRROR_NONE")" "$LC_DIR_NONE"
  assert_eq "install-linear-cli: an archive with NO candidate binary is REFUSED" "1" "$LC_RC"
  assert_contains "install-linear-cli: the no-binary refusal says exactly one is expected" \
    "$LC_OUT" "expected exactly one $LC_BIN"
  assert_contains "install-linear-cli: the no-binary refusal reports the count found" "$LC_OUT" "found 0"
  if [ ! -e "$LC_DIR_NONE/$LC_BIN" ]; then
    _pass "install-linear-cli: an archive with NO candidate binary installs NOTHING"
  else
    _fail "install-linear-cli: an archive with NO candidate binary installs NOTHING" \
      "installed anyway: $LC_DIR_NONE/$LC_BIN"
  fi
fi

# === E. Unsupported platform — exercised on EVERY host by stubbing `uname`
# ahead of the script's PATH, so this path is never a dead branch. SunOS is a
# platform upstream will never ship for.
LC_STUB="$LC_TMP/stub"
mkdir -p "$LC_STUB"
cat > "$LC_STUB/uname" <<'LCUNAME'
#!/bin/sh
case "$1" in
  -s) printf 'SunOS\n' ;;
  -m) printf 'x86_64\n' ;;
  *)  printf 'SunOS\n' ;;
esac
LCUNAME
chmod +x "$LC_STUB/uname"

LC_DIR_UNSUP="$LC_TMP/bin-unsup"
LC_OUT="$(env \
  PATH="$LC_STUB:$PATH" \
  LINEAR_CLI_VERSION="$LC_VER" \
  LINEAR_CLI_CHECKSUM_FILE="$LC_SUMS_REAL" \
  LINEAR_CLI_BASE_URL="file://$LC_MIRROR" \
  LINEAR_CLI_INSTALL_DIR="$LC_DIR_UNSUP" \
  bash "$LC_SCRIPT" 2>&1)"
LC_RC=$?
assert_eq "install-linear-cli: an unsupported platform exits 3" "3" "$LC_RC"
assert_contains "install-linear-cli: the unsupported platform is named" "$LC_OUT" "unsupported platform: SunOS/x86_64"
assert_contains "install-linear-cli: the unsupported path offers the npm alternative" \
  "$LC_OUT" "npm install -g @schpet/linear-cli"
assert_contains "install-linear-cli: the unsupported path offers the Linear MCP fallback" \
  "$LC_OUT" "linear/linear-setup.md §3.3"
if [ ! -d "$LC_DIR_UNSUP" ]; then
  _pass "install-linear-cli: an unsupported platform installs NOTHING"
else
  _fail "install-linear-cli: an unsupported platform installs NOTHING" "created: $LC_DIR_UNSUP"
fi

# === E2. LINEAR_CLI_BASE_URL scheme allowlist. Only https:// and file:// are
# accepted; plain http:// is the transport this installer exists to stop
# trusting, so it is refused before anything is fetched. Platform-independent:
# the guard runs before platform detection.
LC_OUT="$(env \
  LINEAR_CLI_VERSION="$LC_VER" \
  LINEAR_CLI_CHECKSUM_FILE="$LC_SUMS_REAL" \
  LINEAR_CLI_BASE_URL="http://example.invalid/releases" \
  LINEAR_CLI_INSTALL_DIR="$LC_TMP/bin-scheme" \
  bash "$LC_SCRIPT" 2>&1)"
LC_RC=$?
assert_eq "install-linear-cli: a plain http:// base URL exits 2" "2" "$LC_RC"
assert_contains "install-linear-cli: the scheme refusal names the offending URL" \
  "$LC_OUT" "disallowed LINEAR_CLI_BASE_URL scheme: http://example.invalid/releases"
assert_contains "install-linear-cli: the scheme refusal states the allowlist" "$LC_OUT" "Only https:// and file:// are accepted"
# The allowed schemes must NOT be caught by the same guard — a guard that
# refuses everything would pass the assertion above while breaking every install.
# The absent tag guarantees the run dies at the pin lookup, never the network.
LC_OUT="$(env \
  LINEAR_CLI_VERSION="v0.0.0-absent" \
  LINEAR_CLI_CHECKSUM_FILE="$LC_SUMS_REAL" \
  LINEAR_CLI_BASE_URL="https://example.invalid/releases" \
  LINEAR_CLI_INSTALL_DIR="$LC_TMP/bin-scheme-ok" \
  bash "$LC_SCRIPT" 2>&1)"
LC_RC=$?
assert_not_contains "install-linear-cli: an https:// base URL passes the scheme guard" \
  "$LC_OUT" "disallowed LINEAR_CLI_BASE_URL scheme"

# === E3. LINEAR_CLI_VERSION syntax guard. The tag becomes a path segment in the
# download URL and the lookup key, so a traversal shape is refused outright
# rather than sanitized.
LC_OUT="$(env \
  LINEAR_CLI_VERSION="../v2.5.0" \
  LINEAR_CLI_CHECKSUM_FILE="$LC_SUMS_REAL" \
  LINEAR_CLI_BASE_URL="file://$LC_MIRROR" \
  LINEAR_CLI_INSTALL_DIR="$LC_TMP/bin-version-syntax" \
  bash "$LC_SCRIPT" 2>&1)"
LC_RC=$?
assert_eq "install-linear-cli: a traversal-shaped LINEAR_CLI_VERSION exits 2" "2" "$LC_RC"
assert_contains "install-linear-cli: the version-syntax refusal names the value" "$LC_OUT" "malformed LINEAR_CLI_VERSION: ../v2.5.0"
assert_contains "install-linear-cli: the version-syntax refusal states the allowed shape" \
  "$LC_OUT" "^v?[A-Za-z0-9._-]+$"

# === F. Usage error — an unknown flag is exit 2, not a silently ignored word.
LC_OUT="$(env \
  LINEAR_CLI_VERSION="$LC_VER" \
  LINEAR_CLI_CHECKSUM_FILE="$LC_SUMS_REAL" \
  LINEAR_CLI_BASE_URL="file://$LC_MIRROR" \
  LINEAR_CLI_INSTALL_DIR="$LC_TMP/bin-usage" \
  bash "$LC_SCRIPT" --force 2>&1)"
LC_RC=$?
assert_eq "install-linear-cli: an unknown flag exits 2" "2" "$LC_RC"
assert_contains "install-linear-cli: the usage error names the offending argument" "$LC_OUT" "unknown argument: --force"

# === G. The docs teach the pinned installer, not the upstream unpinned routes.
LC_SETUP_BODY="$(cat "$REPO_ROOT/linear/linear-setup.md" 2>/dev/null || printf '')"
assert_contains "install-linear-cli: linear-setup.md documents the pinned installer" \
  "$LC_SETUP_BODY" "bash scripts/install-linear-cli.sh"
assert_contains "install-linear-cli: linear-setup.md documents the pwsh form" \
  "$LC_SETUP_BODY" "scripts/install-linear-cli.ps1"
assert_contains "install-linear-cli: linear-setup.md names the checksum pin file" \
  "$LC_SETUP_BODY" "scripts/linear-cli-checksums.sha256"
assert_contains "install-linear-cli: linear-setup.md documents the re-vet procedure" \
  "$LC_SETUP_BODY" "Updating / re-vetting a new release"
assert_contains "install-linear-cli: linear-setup.md documents the rollback lever" \
  "$LC_SETUP_BODY" "LINEAR_CLI_VERSION="

LC_README_BODY="$(cat "$REPO_ROOT/README.md" 2>/dev/null || printf '')"
assert_contains "install-linear-cli: README points at the pinned installer" \
  "$LC_README_BODY" "scripts/install-linear-cli.sh"

# Inline cleanup — tests/run.sh sources this file, so an EXIT trap would fire for
# every subsequent test.
rm -rf "$LC_TMP"
