#!/usr/bin/env bash
# scripts/check-freshness.sh — install-vs-source freshness signal.
#
# check-drift answers "has an installed GENERATED file been hand-edited since
# install?" — tamper detection, comparing the installed tree against the
# install's OWN build-time manifest. It deliberately never reads the repo.
#
# This script answers the ORTHOGONAL question: "has a SOURCE file changed in the
# repo since this install was rendered?" — i.e. is the operator's installed
# config built from STALE sources and in need of an `install.sh` re-render? A
# hook/capability fix can merge to main and then sit silently un-activated on the
# operator's machine because install.sh was never re-run; check-drift passes the
# whole time (no tamper). This is the missing freshness signal.
#
# Mechanism: the manifest's `.sources{}` map records a SHA256 of every source
# file AT INSTALL TIME. We re-hash each of those source files in the current repo
# and compare. Any mismatch — or a source file that has since been removed /
# renamed — means the install is stale.
#
# This is a SOFT signal, never a gate. A stale install is a normal state after
# pulling main; the fix (re-run install.sh) is the operator's call. It is
# deliberately NOT wired into `make verify`: CI has no install, and a dev machine
# that simply hasn't re-installed is not a repo defect. The SessionStart
# framework-surface hook runs it and surfaces a one-line nudge.
#
# Usage:
#   check-freshness.sh --manifest <install-dir> [--repo <repo-root>] [--list]
#
#   --manifest <dir>  directory containing .build-manifest.json — the install,
#                     e.g. $CLAUDE_CONFIG_DIR or $CODEX_HOME. REQUIRED.
#   --repo <dir>      the agentic-os-template source checkout to hash against. Defaults to
#                     this script's own repo root (scripts/..), which is the
#                     checkout the install was rendered from.
#   --list            machine mode: print ONLY the stale source paths, one per
#                     line (nothing when fresh). Default mode prints a
#                     human-readable PASS / STALE / SKIP summary.
#
# Exit codes (BOTH modes):
#   0  fresh  — every manifest source matches the repo
#   1  stale  — at least one source changed / was removed since install
#   2  skip   — could not determine (no manifest / no jq / no sha tool / repo or
#               sources map missing). Callers treat exit 2 as "say nothing".
#
# Fail-SOFT by design: "can't tell" is a distinct exit code (2) from "fresh" (0),
# so a fail-open surfacing hook can stay silent on either without conflating them.
set -uo pipefail

MODE_LIST=0
MANIFEST_DIR=""
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    # Guard the value BEFORE `shift 2`: bash leaves $# unchanged when asked to
    # shift more than $# (and there is no `set -e` here), so a value-less
    # `--manifest` / `--repo` would otherwise re-loop on the same flag forever.
    # Missing value → fail-soft exit 2 (indeterminate), never a spin.
    --manifest) [ $# -ge 2 ] || { printf 'check-freshness: --manifest needs a value\n' >&2; exit 2; }
                MANIFEST_DIR="$2"; shift 2 ;;
    --repo)     [ $# -ge 2 ] || { printf 'check-freshness: --repo needs a value\n' >&2; exit 2; }
                REPO="$2"; shift 2 ;;
    --list)     MODE_LIST=1; shift ;;
    *) printf 'check-freshness: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# skip <reason> — emit the reason (human mode only) and exit 2 (indeterminate).
skip() {
  [ "$MODE_LIST" -eq 1 ] || printf 'SKIP %s\n' "$1" >&2
  exit 2
}

# Source repo: explicit --repo wins; else derive from this script's location.
# scripts/check-freshness.sh → scripts/.. = the agentic-os-template checkout root.
if [ -n "$REPO" ]; then
  repo_root="$REPO"
else
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || repo_root=""
fi

[ -n "$MANIFEST_DIR" ] || skip "no --manifest <install-dir> given"
manifest="$MANIFEST_DIR/.build-manifest.json"
[ -f "$manifest" ] || skip "no .build-manifest.json in $MANIFEST_DIR"
command -v jq >/dev/null 2>&1 || skip "jq unavailable; cannot read manifest"
[ -n "$repo_root" ] && [ -d "$repo_root" ] || skip "source repo not found: ${repo_root:-<unresolved>}"
jq -e '.sources | type == "object"' "$manifest" >/dev/null 2>&1 || skip "manifest has no sources map"

# jqr — jq -r with CRLF normalization (parity with check-drift.sh): a
# Windows-built jq emits \r\n, and a trailing \r inside a hash silently fails
# every comparison below.
jqr() { jq -r "$@" | tr -d '\r'; }

# sha256 helper — resolve the available tool once (parity with check-drift.sh).
# Hash via stdin: a backslash-containing filename flips GNU coreutils into
# escaped-filename mode, corrupting the extracted hash.
if command -v sha256sum >/dev/null 2>&1; then
  _sha() { sha256sum < "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  _sha() { shasum -a 256 < "$1" | cut -d' ' -f1; }
else
  skip "no sha256 tool found (sha256sum / shasum)"
fi

# Compare each recorded source hash against the current repo file. Built in the
# CURRENT shell via process substitution (NOT a pipe, which would subshell the
# array and lose it). A removed/renamed source counts as stale — the install was
# rendered from a tree that no longer matches the repo.
#
# Newline-delimited `rel<TAB>want` (same shape as check-drift.sh's manifest
# loop): the framework manifest is generated from in-repo source PATHS, which
# never contain embedded tabs/newlines, so the IFS split is unambiguous. A
# hand-crafted manifest with control-char keys could mis-split (a cosmetic
# count/listing artifact, never JSON corruption — the hook re-escapes via jq);
# that is the same accepted tradeoff check-drift documents, not a new exposure.
stale=()
while IFS=$'\t' read -r rel want; do
  [ -n "$rel" ] || continue
  src="$repo_root/$rel"
  if [ ! -f "$src" ]; then
    stale+=("$rel")
    continue
  fi
  got="$(_sha "$src")"
  if [ "$got" != "$want" ]; then
    stale+=("$rel")
  fi
done < <(jqr '.sources | to_entries[] | "\(.key)\t\(.value)"' "$manifest")

n=${#stale[@]}
if [ "$n" -eq 0 ]; then
  if [ "$MODE_LIST" -eq 0 ]; then
    total="$(jqr '.sources | length' "$manifest")"
    printf 'PASS install is current (%s source files match)\n' "$total"
  fi
  exit 0
fi

if [ "$MODE_LIST" -eq 1 ]; then
  printf '%s\n' "${stale[@]}"
else
  total="$(jqr '.sources | length' "$manifest")"
  printf 'STALE %s of %s source file(s) changed since install — re-run scripts/install.sh:\n' "$n" "$total"
  printf '  %s\n' "${stale[@]}"
fi
exit 1
