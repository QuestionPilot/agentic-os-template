#!/usr/bin/env bash
# check-machine-paths.sh — pre-drain machine-path scanner for the closeout
# session-log drain. Fails CLOSED: a draft carrying a machine-specific absolute
# home path (`/Users/<name>/…`, `/home/<name>/…`, `C:\Users\<name>\…`) is
# rejected BEFORE the drain writes it to the vault, instead of surfacing on the
# NEXT vault audit's machine-path rule.
#
# WHY THIS EXISTS. The closeout drain composes a session-log body and writes it
# to `30-Archive/Sessions/`. It runs the vault audit BEFORE writing its own log,
# so the log's OWN body is not machine-path-scanned until the NEXT audit run —
# exactly how a drafted log carrying a `/Users/<name>/…` path can land in the
# cloud-synced vault and sit undetected until a manual audit. This check closes
# that window: it scans the drafted body at write time, the SAME way the vault
# audit's machine-path rule does, and blocks the write on any offending line.
# There is NO raw-evidence exemption — a durable session log must be path-clean,
# full stop, so the whole file is scanned line-by-line.
#
# MATCH RULE — mirrors the vault audit's `checkAgnostic`
# (`obsidian/vault-scaffolding/bin/memory-vault-audit.js`, its `machinePath`
# regex). That resolver lives in the operator's vault scaffolding; this is a
# pinned mirror kept honest by tests/machine-paths.test.sh. Two refinements
# over a bare substring match, carried across:
#   (1) Require a real username segment after the home root, so a lone "Users" or
#       "home" token in prose (or a regex) does not trip — the `[^/…]+` /
#       `[^\\…]+` tail demands at least one path character.
#   (2) Tell a filesystem path apart from a URL path. In a URL the path segment
#       is preceded by an alphanumeric host character (or a dot, e.g. `.com`); a
#       real absolute path instead begins at a boundary — line start, whitespace,
#       or a delimiter like a quote / paren / equals. So a home path is flagged
#       only when NOT immediately preceded by a URL host character (alnum or dot).
# The Windows arm likewise requires a real user-folder segment, not a bare
# drive-colon-backslash.
#
# JS source regex (single line):
#   /(?:^|[^A-Za-z0-9.])\/(?:Users|home)\/[^/\s]+|[A-Za-z]:\\Users\\[^\\\s]+/
# Translated to POSIX ERE (grep -E) below: `(?:…)` → `(…)`, `\s` → `[:space:]`
# inside the bracket expressions (POSIX has no `\s`), `\/` → `/`. The whitespace
# classes are NOT bit-identical across engines: JS `\s`, .NET `\s`, and POSIX
# `[[:space:]]` disagree on exotic Unicode whitespace (e.g. U+0085 NEL, U+FEFF).
# The contract here is ASCII-whitespace scope — real home paths are ASCII-shaped,
# so the divergence is an accepted trade-off, not a parity bug.
#
# Accepted trade-offs (as in checkAgnostic): matching is case-sensitive, only a
# host-bearing URL is distinguished — a root-relative or bracketed link path
# shares syntax with a genuine parenthesized path and stays conservatively
# flagged (pre-existing in the reference; not widened here) — and the whitespace
# class is ASCII-scoped as above.
#
# Usage:
#   check-machine-paths.sh --draft <path>
#   check-machine-paths.sh --help
#
# Exit codes:
#   0 — no machine-specific absolute path in the draft
#   1 — one or more offending lines (FAIL CLOSED — do not write the draft)
#   2 — usage error (missing/unreadable draft, bad args)
#
# The caller (the closeout drain) treats ANY non-zero exit as "do not write" —
# the same contract as the wikilink check and the injection scan it runs alongside.

set -uo pipefail

usage() {
  sed -nE 's|^# ?||p' "$0" | awk '/^check-machine-paths\.sh/,/^The caller/' | head -60
}

draft=""
while [ $# -gt 0 ]; do
  case "$1" in
    --draft)
      [ $# -ge 2 ] || { printf 'FAIL --draft requires a value\n' >&2; exit 2; }
      draft="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'FAIL unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Draft is required and must be a readable file.
[ -n "$draft" ] || { printf 'FAIL no --draft given\n' >&2; exit 2; }
[ -f "$draft" ] || { printf 'FAIL draft file does not exist: %s\n' "$draft" >&2; exit 2; }
[ -r "$draft" ] || { printf 'FAIL draft file not readable: %s\n' "$draft" >&2; exit 2; }

# The machine-path pattern — the JS `machinePath` regex in POSIX ERE. The Unix
# arm: a `/Users/` or `/home/` NOT preceded by a URL host char (alnum or dot),
# with a real username segment `[^/[:space:]]+`. The Windows arm: `<drive>:\Users\`
# with a real user segment `[^\\[:space:]]+`. The `\\` sequences are literal
# backslashes (each `\\` collapses to one literal `\` in the ERE), portable across
# BSD and GNU grep.
pattern='(^|[^A-Za-z0-9.])/(Users|home)/[^/[:space:]]+|[A-Za-z]:\\Users\\[^\\[:space:]]+'

# Single-pass scan: ONE grep -n over the whole file, then parse its `NN:` line
# numbers into the per-offender report. grep's exit status is tri-state — 0 = at
# least one offender, 1 = clean, >=2 = runtime error — and each state is handled
# explicitly, so a scan error is a LOUD exit 2, never a silent pass. (A per-line
# `printf | grep -q` loop would collapse all three states into matched/not-matched:
# a grep runtime error or pipeline artifact on an offending line would score it
# clean — failing OPEN — and it forks two processes per line.) grep -n also
# matches a final line with no trailing newline, so an editor-truncated draft is
# still fully scanned (pinned in tests/machine-paths.test.sh).
hits="$(grep -nE "$pattern" -- "$draft")"
rc=$?
if [ "$rc" -ge 2 ]; then
  printf 'FAIL scan error: grep exited %s scanning %s — cannot verify the draft, do NOT write (fail closed)\n' \
    "$rc" "$draft" >&2
  exit 2
fi

if [ "$rc" -eq 0 ]; then
  offenders=0
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    printf 'FAIL machine-specific absolute path (keep the session log agnostic): %s:%s\n' \
      "$draft" "${hit%%:*}" >&2
    offenders=$((offenders + 1))
  done <<< "$hits"
  printf 'FAIL %s offending line(s) with a machine-specific absolute path in %s — replace each with an agnostic reference (a repo-relative, home-relative, or vault-relative path) before the drain writes\n' \
    "$offenders" "$draft" >&2
  exit 1
fi

printf 'PASS no machine-specific absolute paths in %s\n' "$draft"
exit 0
