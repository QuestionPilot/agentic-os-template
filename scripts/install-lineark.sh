#!/usr/bin/env bash
# scripts/install-lineark.sh — pinned, checksum-verified installer for the
# OPTIONAL `lineark` CLI (the framework's default active-work tracker surface;
# see linear/linear-setup.md §3.2).
#
# WHY THIS EXISTS. Upstream documents a `curl … | sh` install, and the framework
# used to reproduce that instruction verbatim. That pattern hands whatever the
# host serves at request time straight to a shell: there is no pinned version, no
# integrity check, and no reviewable artifact — a compromised host, a hijacked
# CDN, or a hostile upstream commit executes with the operator's permissions
# before anyone can read what arrived. This script replaces it with the ordinary
# supply-chain shape:
#
#   1. PIN a release tag (never "whatever main serves right now").
#   2. Download the release ASSET to a throwaway dir — never into a shell.
#   3. VERIFY its sha256 against an operator-reviewed pin file BEFORE the file is
#      made executable or moved anywhere near PATH, and RE-VERIFY it in place
#      after the move, before it is ever executed.
#   4. SMOKE the installed binary and require it to report EXACTLY the pinned
#      version.
#
# Upstream publishes tagged releases with raw binaries and NO checksum manifest,
# so the framework maintains its own: scripts/lineark-checksums.sha256, keyed
# `<tag>/<asset>`. A tag with no entry is an UNVETTED release and this script
# refuses to install it — that refusal is the whole point of the pin file, so it
# is loud and has no override flag. Vetting a new release is a documented
# procedure (linear/linear-setup.md §3.2, "Updating / re-vetting a new release").
#
# ACCEPTED RESIDUAL RISK. The ambient PATH and environment are TRUSTED INPUT here
# — the same trust boundary the README documents for every framework script, so a
# poisoned PATH can substitute `curl`, `mktemp` or the sha256 tool, and invoking
# this script through an attacker-placed symlink relocates the default checksum
# file along with it (the trust-root warning below only fires when the overrides
# are set explicitly, so it does not cover the symlink case).
#
# Nothing here is required to run the framework. `lineark` is optional; the spine
# capabilities degrade to a one-line warning when no tracker surface is present.
#
# Usage:
#   bash scripts/install-lineark.sh
#   bash scripts/install-lineark.sh --help
#
# Environment overrides (all optional):
#   LINEARK_VERSION        release tag to install. Default: the pin below. Must
#                          match ^v?[A-Za-z0-9._-]+$ — no slashes, no whitespace,
#                          so it can never escape its own key in the pin file.
#                          Also the rollback lever — an older tag still listed in
#                          the checksum file installs unchanged.
#   LINEARK_CHECKSUM_FILE  path to the pin file. Default: the sibling
#                          scripts/lineark-checksums.sha256.
#   LINEARK_BASE_URL       release-download base. Default: the upstream GitHub
#                          releases base. Only https:// and file:// are accepted
#                          (the hermetic tests point this at a file:// mirror so
#                          they never touch the network).
#   LINEARK_INSTALL_DIR    install destination. Default: $HOME/.local/bin.
#
# Setting LINEARK_CHECKSUM_FILE or LINEARK_BASE_URL moves the TRUST ROOT off the
# repo's reviewed defaults, so each one prints a WARNING naming the override
# before anything is downloaded. Installing any tag other than the default pin
# prints a note — a silent downgrade to an older, withdrawn release is exactly
# what that line is there to make visible.
#
# Exit codes:
#   0 — installed and the version smoke matched the pinned tag EXACTLY
#   1 — install refused or failed (unvetted tag, conflicting pin entries,
#       checksum mismatch, download failure, smoke mismatch). NOTHING executable
#       is left behind.
#   2 — usage or configuration error (unknown argument, malformed
#       LINEARK_VERSION, disallowed LINEARK_BASE_URL scheme)
#   3 — unsupported platform (upstream ships no binary for it)
#
# Tests: tests/install-lineark.test.sh (+ the .ps1 twin).

set -euo pipefail

# The pinned default lives here and ONLY here.
LINEARK_DEFAULT_VERSION="v3.1.0"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_CHECKSUM_FILE="$SELF_DIR/lineark-checksums.sha256"
DEFAULT_BASE_URL="https://github.com/flipbit03/lineark/releases/download"

VERSION="${LINEARK_VERSION:-$LINEARK_DEFAULT_VERSION}"
CHECKSUM_FILE="${LINEARK_CHECKSUM_FILE:-$DEFAULT_CHECKSUM_FILE}"
BASE_URL="${LINEARK_BASE_URL:-$DEFAULT_BASE_URL}"
INSTALL_DIR="${LINEARK_INSTALL_DIR:-$HOME/.local/bin}"

REVET_POINTER='linear/linear-setup.md §3.2 ("Updating / re-vetting a new release")'
MCP_POINTER='linear/linear-setup.md §3.3 (Linear MCP)'

usage() {
  sed -nE 's|^# ?||p' "$0" | sed -n '/^scripts\/install-lineark\.sh/,/^Tests:/p'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) printf 'FAIL unknown argument: %s (this installer takes no flags — configure it with the LINEARK_* environment variables; --help lists them)\n' "$1" >&2; exit 2 ;;
  esac
done

# --- 0. Input guards and trust-root transparency -----------------------------
# The tag becomes a path segment in the download URL and the lookup key. Anything
# with a slash or whitespace could point the fetch at an unrelated path or split
# the key, so the shape is constrained before it is used anywhere.
case "$VERSION" in
  *[!A-Za-z0-9._-]*|'')
    printf 'FAIL malformed LINEARK_VERSION: %s\n' "$VERSION" >&2
    printf 'A release tag must match ^v?[A-Za-z0-9._-]+$ — no slashes, no whitespace.\n' >&2
    exit 2
    ;;
esac

case "$BASE_URL" in
  https://*|file://*) ;;
  *)
    printf 'FAIL disallowed LINEARK_BASE_URL scheme: %s\n' "$BASE_URL" >&2
    printf 'Only https:// and file:// are accepted. Plain http:// is refused outright — an unencrypted fetch is exactly the transport this installer exists to stop trusting.\n' >&2
    exit 2
    ;;
esac

# A non-default checksum file or base URL means the operator (or something in the
# environment) has moved the trust root off the repo's reviewed defaults. That is
# supported — the hermetic tests depend on it — but it is never silent.
if [ "$CHECKSUM_FILE" != "$DEFAULT_CHECKSUM_FILE" ]; then
  printf 'WARNING non-default trust root: LINEARK_CHECKSUM_FILE=%s\n' "$CHECKSUM_FILE" >&2
fi
if [ "$BASE_URL" != "$DEFAULT_BASE_URL" ]; then
  printf 'WARNING non-default trust root: LINEARK_BASE_URL=%s\n' "$BASE_URL" >&2
fi
if [ "$VERSION" != "$LINEARK_DEFAULT_VERSION" ]; then
  printf 'note: installing non-default tag %s (current default: %s)\n' "$VERSION" "$LINEARK_DEFAULT_VERSION"
fi

# --- 1. Platform -> upstream asset name -------------------------------------
# Mirrors the asset set upstream actually publishes. Anything else is a hard
# stop with the two documented alternatives, not a best-effort guess.
os="$(uname -s)"
arch="$(uname -m)"
asset=""
case "$os" in
  Linux)
    case "$arch" in
      x86_64|amd64)   asset="lineark_linux_x86_64" ;;
      aarch64|arm64)  asset="lineark_linux_aarch64" ;;
    esac
    ;;
  Darwin)
    case "$arch" in
      arm64|aarch64)  asset="lineark_macos_aarch64" ;;
    esac
    ;;
esac

if [ -z "$asset" ]; then
  printf 'FAIL unsupported platform: %s/%s — upstream publishes no prebuilt lineark binary for it.\n' "$os" "$arch" >&2
  printf 'Alternatives:\n' >&2
  printf '  - build from source:  cargo install lineark\n' >&2
  printf '  - use the other tracker surface instead: %s\n' "$MCP_POINTER" >&2
  exit 3
fi

key="$VERSION/$asset"

# --- 2. Expected checksum from the operator-reviewed pin file ----------------
[ -f "$CHECKSUM_FILE" ] || {
  printf 'FAIL checksum pin file not found: %s\n' "$CHECKSUM_FILE" >&2
  printf 'Without it no release can be verified. Restore it from the repo, or point LINEARK_CHECKSUM_FILE at a reviewed copy. See %s.\n' "$REVET_POINTER" >&2
  exit 1
}

# _lineark_sha256 <file> — echo the file's lowercase sha256, or empty when no
# hashing tool exists. macOS ships `shasum`, most Linux distros ship
# `sha256sum`; neither is universal, so probe rather than assume.
_lineark_sha256() {
  local h=""
  if command -v sha256sum >/dev/null 2>&1; then
    h="$(sha256sum "$1" | cut -d' ' -f1)"
  elif command -v shasum >/dev/null 2>&1; then
    h="$(shasum -a 256 "$1" | cut -d' ' -f1)"
  else
    return 1
  fi
  printf '%s' "$h" | tr '[:upper:]' '[:lower:]'
}

# _lineark_pin_matches <key> — echo one `<line-number><TAB><sha>` record per pin
# entry whose key matches, in file order. Explicit line parsing (no grep) so a
# legitimate miss is an empty result rather than a non-zero status that errexit
# would turn into a silent death mid-pipeline.
#
# Normalization is load-bearing for TWIN PARITY: a pin file saved with CRLF line
# endings, or an entry with trailing spaces, must resolve identically here and in
# the PowerShell twin. Without the strip, bash refused a CRLF pin file as an
# "unvetted release" while PS accepted it — the two twins disagreeing about which
# releases are vetted is worse than either behavior alone.
_lineark_pin_matches() {
  local want="$1" line sha rest n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$(( n + 1 ))
    line="${line%$'\r'}"
    # Leading whitespace: strip before the comment test so an indented comment
    # is still a comment.
    while [ "${line# }" != "$line" ] || [ "${line#$'\t'}" != "$line" ]; do
      line="${line# }"; line="${line#$'\t'}"
    done
    case "$line" in ''|'#'*) continue ;; esac
    sha="${line%%[[:space:]]*}"
    rest="${line#"$sha"}"
    # Separator run between the sha and the key (upstream sha256 files use two
    # spaces; accept any run of spaces/tabs).
    while [ "${rest# }" != "$rest" ] || [ "${rest#$'\t'}" != "$rest" ]; do
      rest="${rest# }"; rest="${rest#$'\t'}"
    done
    # Trailing whitespace on the key.
    while [ "${rest% }" != "$rest" ] || [ "${rest%$'\t'}" != "$rest" ]; do
      rest="${rest% }"; rest="${rest%$'\t'}"
    done
    [ "$rest" = "$want" ] || continue
    printf '%s\t%s\n' "$n" "$sha"
  done < "$CHECKSUM_FILE"
}

matches="$(_lineark_pin_matches "$key" || true)"

if [ -z "$matches" ]; then
  printf 'FAIL unvetted release: no checksum entry for %s in %s\n' "$key" "$CHECKSUM_FILE" >&2
  printf 'An unvetted release is never installed. To adopt this tag, follow the re-vet procedure in %s: review the upstream release, download the assets, compute their sha256 locally, append the entries, then re-run.\n' "$REVET_POINTER" >&2
  exit 1
fi

# CONFLICTING PINS. Two entries for one key with DIFFERENT hashes means the pin
# file cannot say what the vetted artifact is, and "first match wins" would let
# an appended line silently decide. Identical duplicates are harmless (a merge
# artifact), so only differing shas refuse. LC_ALL=C keeps sort byte-oriented.
distinct="$(printf '%s\n' "$matches" | cut -f2 | LC_ALL=C sort -u | LC_ALL=C wc -l | tr -d '[:space:]')"
if [ "$distinct" -gt 1 ]; then
  conflict_lines="$(printf '%s\n' "$matches" | cut -f1 | tr '\n' ' ' | sed 's/ *$//')"
  printf 'FAIL conflicting pin entries for %s in %s\n' "$key" "$CHECKSUM_FILE" >&2
  printf '  %s entries with %s different sha256 values, at line(s): %s\n' \
    "$(printf '%s\n' "$matches" | LC_ALL=C wc -l | tr -d '[:space:]')" "$distinct" "$conflict_lines" >&2
  printf 'The pin file cannot say which artifact is vetted. Resolve the conflict by hand — see %s — then re-run. Nothing was installed.\n' "$REVET_POINTER" >&2
  exit 1
fi

expected="$(printf '%s\n' "$matches" | head -n 1 | cut -f2 | tr '[:upper:]' '[:lower:]')"

# --- 3. Download to a throwaway dir (never into a shell) ---------------------
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

url="$BASE_URL/$VERSION/$asset"
artifact="$work/$asset"

printf 'lineark: installing %s (%s)\n' "$VERSION" "$asset"
printf 'lineark: fetching %s\n' "$url"
if ! curl -fsSL "$url" -o "$artifact"; then
  printf 'FAIL download failed: %s\n' "$url" >&2
  printf 'Check network access and that the tag exists upstream. Nothing was installed.\n' >&2
  exit 1
fi

# --- 4. Verify BEFORE chmod / move ------------------------------------------
if ! actual="$(_lineark_sha256 "$artifact")"; then
  printf 'FAIL no sha256 tool found (looked for sha256sum, shasum). Cannot verify the download — refusing to install.\n' >&2
  exit 1
fi

if [ "$expected" != "$actual" ]; then
  rm -f "$artifact"
  printf 'FAIL checksum mismatch for %s\n' "$key" >&2
  printf '  expected: %s\n' "$expected" >&2
  printf '  actual:   %s\n' "$actual" >&2
  printf 'The downloaded artifact was deleted and NOTHING was installed. Either the release was re-cut upstream (re-vet it per %s) or the download is not what the pin file describes — treat the second case as hostile until proven otherwise.\n' "$REVET_POINTER" >&2
  exit 1
fi

printf 'lineark: sha256 verified (%s)\n' "$actual"

# --- 5. Install --------------------------------------------------------------
dest="$INSTALL_DIR/lineark"
mkdir -p "$INSTALL_DIR"
chmod +x "$artifact"
mv "$artifact" "$dest"
printf 'lineark: installed %s\n' "$dest"

# --- 6. RE-VERIFY IN PLACE, before the binary is ever executed ---------------
# The hash in §4 was computed on the file in the temp dir. Between that read and
# the `--version` call in §7 the bytes at $dest are a DIFFERENT object as far as
# the security argument goes: `mv` across filesystems is a copy that re-reads the
# source, the destination directory may be writable by someone else, and $dest
# may already have existed. Re-hashing what is actually about to be executed
# closes that verify -> move -> execute window; skipping it means the thing
# verified and the thing run are only assumed to be the same file.
if ! dest_actual="$(_lineark_sha256 "$dest")"; then
  rm -f "$dest"
  printf 'FAIL no sha256 tool available to re-verify the installed file — removed %s rather than execute an unverified binary.\n' "$dest" >&2
  exit 1
fi

if [ "$expected" != "$dest_actual" ]; then
  rm -f "$dest"
  printf 'FAIL post-install checksum mismatch for %s\n' "$dest" >&2
  printf '  expected: %s\n' "$expected" >&2
  printf '  actual:   %s\n' "$dest_actual" >&2
  printf 'The installed file does not match what was verified before the move — it was removed and NOT executed. Treat the install directory as untrusted until you know why.\n' >&2
  exit 1
fi

printf 'lineark: post-install sha256 re-verified in place\n'

# --- 7. Version smoke --------------------------------------------------------
# The checksum proves the bytes match the pin; this proves the pin describes the
# release it claims to. EXACT equality, not a substring: `lineark 13.1.0` contains
# "3.1.0", so a substring test would wave through a completely different release.
# A mismatch means the pin file and the tag disagree, so the binary is removed
# again rather than left on PATH masquerading as the tag.

# _lineark_version_token <text> — echo the first whitespace-separated token that
# starts with a digit ("lineark 3.1.0" -> "3.1.0"), or empty. Globbing is
# disabled around the split so a token like `*` cannot expand against the cwd.
_lineark_version_token() {
  local tok result="" had_noglob=0
  case "$-" in *f*) had_noglob=1 ;; esac
  set -f
  # shellcheck disable=SC2086
  set -- $1
  for tok in "$@"; do
    tok="${tok%$'\r'}"
    case "$tok" in
      [0-9]*) result="$tok"; break ;;
    esac
  done
  [ "$had_noglob" -eq 1 ] || set +f
  printf '%s' "$result"
}

want="${VERSION#v}"
version_out="$("$dest" --version 2>&1 || true)"
printf 'lineark: %s\n' "$version_out"
version_token="$(_lineark_version_token "$version_out")"

if [ "$version_token" != "$want" ]; then
  rm -f "$dest"
  printf 'FAIL version smoke failed: installed binary does not report the pinned version %s\n' "$want" >&2
  printf '  --version said: %s\n' "$version_out" >&2
  printf '  parsed version: %s (exact match against %s required)\n' "${version_token:-<none>}" "$want" >&2
  printf 'The binary was removed. The checksum entry for %s likely describes a different release — re-vet per %s.\n' "$key" "$REVET_POINTER" >&2
  exit 1
fi

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    printf 'lineark: %s is not on PATH. Add it, e.g.:\n' "$INSTALL_DIR" >&2
    printf '  export PATH="%s:$PATH"\n' "$INSTALL_DIR" >&2
    ;;
esac

printf 'PASS lineark %s installed and verified\n' "$VERSION"
printf 'Next: provide the API token (linear/linear-setup.md §3.2) and run `lineark whoami`.\n'
exit 0
