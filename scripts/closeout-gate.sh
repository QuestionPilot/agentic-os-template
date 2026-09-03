#!/usr/bin/env bash
# closeout-gate.sh — ONE fail-closed wrapper for the deterministic pre-write
# checks a closeout composes by hand before it writes a drafted durable artifact
# (a session log, a distilled lesson note) into the vault.
#
# WHY THIS EXISTS. capabilities/closeout.md states the pre-write contract in
# prose — the injection scan, the wikilink check, the machine-path scan, and the
# project-note budget must ALL pass (fail closed). Composing four separate
# commands by hand at write time is where one silently gets dropped: a
# skipped gate looks identical to a passed one in a transcript, and the miss only
# surfaces on the NEXT vault audit — after the artifact already landed. This
# wrapper makes the SET the unit: one invocation, one verdict, and a MISSING
# gate script is a FAILURE, not a skip.
#
# The checks it runs, in the order closeout.md §6 lists them:
#
#   injection-scan  scripts/check-memory-drift.sh --injection-scan <draft>
#                   Bare line-leading prompt-injection directives copied verbatim
#                   from untrusted tool/web output into a trusted section.
#   wikilinks       scripts/check-wikilinks.sh --draft <draft> [--vault <vault>]
#                   Every [[wikilink]] resolves the way the vault audit resolves
#                   it. Needs a vault: with NONE CONFIGURED at all this is a
#                   NAMED SKIP (an inapplicable surface, not a missing gate). A
#                   vault that IS configured but whose directory does not exist
#                   is a FAILURE — see the contract below.
#                   Vault resolution precedence: --vault flag, then
#                   $OBSIDIAN_VAULT_PATH, then OBSIDIAN_VAULT_PATH read from
#                   repo-root local.env as DATA (never sourced) — the same
#                   last-resort chain check-drift.sh --auto uses for render
#                   homes. Agent shells do not inherit local.env, so without the
#                   file fallback the check silently SKIPped every closeout on a
#                   machine whose vault IS configured.
#   machine-paths   scripts/check-machine-paths.sh --draft <draft>
#                   No machine-specific absolute home path in the durable file.
#   project-note-budget
#                   scripts/check-project-note-budget.sh --memory-dir <dir>
#                   No `type: project` memory note over the per-note body budget
#                   (PROJECT_NOTE_BODY_WARN_KB, default 16 KB). Closeout is where
#                   project notes GROW, so it is where the budget must bite — the
#                   self-audit's after-the-fact warn arrives a session too late.
#                   Needs a memory store, and follows the SAME surface contract as
#                   the wikilink check: NONE configured is a NAMED SKIP, a
#                   CONFIGURED-but-missing dir is a FAILURE. Resolution precedence:
#                   --memory-dir flag, then $CLAUDE_PRIMARY_MEMORY_DIR, then
#                   CLAUDE_PRIMARY_MEMORY_DIR read from repo-root local.env as DATA.
#
# FAIL-CLOSED CONTRACT, stated precisely because the two non-pass outcomes are
# easy to conflate:
#   - A check that RUNS and reports a finding  -> FAIL (exit 1).
#   - A check whose SCRIPT IS ABSENT           -> FAIL (exit 1). A gate that
#     cannot run has proven nothing; treating it as a skip is the fail-open hole
#     this wrapper exists to close.
#   - A check whose TARGET SURFACE IS ABSENT   -> SKIP, named, exit unaffected.
#     Two checks have such a surface — the wikilink check (the vault) and the
#     project-note budget (the memory store) — and each skip is narrow: NOTHING
#     configured at all (no flag, the env var unset/empty, AND no key in
#     repo-root local.env). That is a real, benign configuration (a fresh public
#     clone), not a broken gate.
#   - A check whose surface IS CONFIGURED but BROKEN -> FAIL (exit 1), naming
#     the path. A configured vault directory that does not exist is a misspelled
#     or unsynced destination, not "no vault": the durable write it gates would
#     land somewhere the operator never inspected, so it must block.
#
# PRECEDENCE, and it is load-bearing, in this order:
#   1. SCRIPT EXISTENCE. Evaluating anything else first would let a check that
#      HAS an inapplicable surface report SKIP while its gate script is missing
#      — an unrunnable gate laundered into a benign skip, and the gate could
#      then PASS. Missing script wins over surface state, always.
#   2. SURFACE BROKEN (a configured vault or memory dir that does not exist) -> FAIL.
#   3. SURFACE ABSENT (nothing configured) -> SKIP.
#
# Usage:
#   closeout-gate.sh --draft <path> [--vault <path>] [--memory-dir <path>]
#   closeout-gate.sh --list [--vault <path>] [--memory-dir <path>]
#                                                (show what would run; runs nothing)
#   closeout-gate.sh --help
#
# --vault defaults to $OBSIDIAN_VAULT_PATH, then to OBSIDIAN_VAULT_PATH from
# repo-root local.env; --memory-dir defaults to $CLAUDE_PRIMARY_MEMORY_DIR, then
# to CLAUDE_PRIMARY_MEMORY_DIR from the same file ($AI_CONFIG_LOCAL_ENV overrides
# the file path — the same fixture convention as check-drift.sh / install.sh).
# Nothing else is configurable: the check set IS the contract, so it is not
# caller-selectable.
#
# Exit codes:
#   0 — every applicable check passed (skips do not fail the gate)
#   1 — at least one check failed, or a configured check's script is missing
#   2 — usage error (missing/unreadable draft, bad args)
#
# Test override: $CLOSEOUT_GATE_SCRIPTS_DIR points the wrapper at a fixture
# scripts/ dir (same convention as $SELF_AUDIT_CURRENTNESS_BIN in self-audit.sh),
# so tests can exercise the failing-check and missing-script paths hermetically.
#
# Tests: tests/closeout-gate.test.sh (+ the .ps1 twin).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${CLOSEOUT_GATE_SCRIPTS_DIR:-$SELF_DIR}"

usage() {
  sed -nE 's|^# ?||p' "$0" | awk '/^closeout-gate\.sh/,/^Tests:/'
}

# _cg_localenv_get <path> <key> — read one KEY=VALUE from local.env as DATA
# (never sourced; a hostile or malformed local.env cannot execute). Same parser
# as scripts/check-drift.sh::_cd_localenv_get: strips an optional `export `, one
# matching outer quote pair, backslash escapes (the vault value carries spaces
# on real machines, in both the quoted and backslash-escaped spellings); last
# assignment wins. No $VAR expansion.
_cg_localenv_get() {
  local path="$1" key="$2" line t v f l inner result=""
  [ -f "$path" ] || { printf '%s' ""; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    t="${line#"${line%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    [ -z "$t" ] && continue
    case "$t" in '#'*) continue ;; esac
    case "$t" in
      export[[:space:]]*) t="${t#export}"; t="${t#"${t%%[![:space:]]*}"}" ;;
    esac
    case "$t" in
      "$key="*) v="${t#"$key="}" ;;
      *) continue ;;
    esac
    if [ "${#v}" -ge 2 ]; then
      f="${v:0:1}"; l="${v:$(( ${#v} - 1 )):1}"
      if { [ "$f" = '"' ] && [ "$l" = '"' ]; } || { [ "$f" = "'" ] && [ "$l" = "'" ]; }; then
        inner=$(( ${#v} - 2 )); v="${v:1:$inner}"
      else
        case "$v" in
          *'\'*) v="$(printf '%s' "$v" | sed -E 's/\\(.)/\1/g')" ;;
        esac
      fi
    fi
    result="$v"
  done < "$path"
  printf '%s' "$result"
}

draft=""
vault="${OBSIDIAN_VAULT_PATH:-}"
memdir="${CLAUDE_PRIMARY_MEMORY_DIR:-}"
list_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    --draft)
      [ $# -ge 2 ] || { printf 'FAIL --draft requires a value\n' >&2; exit 2; }
      draft="$2"; shift 2 ;;
    --vault)
      [ $# -ge 2 ] || { printf 'FAIL --vault requires a value\n' >&2; exit 2; }
      vault="$2"; shift 2 ;;
    --memory-dir)
      [ $# -ge 2 ] || { printf 'FAIL --memory-dir requires a value\n' >&2; exit 2; }
      # An EXPLICIT empty value is a USAGE ERROR, never a fallback. Accepting it
      # would send `--memory-dir "$SOME_UNSET_VAR"` down the env/local.env chain
      # and, on a machine with nothing configured, out as the named SKIP: a
      # caller that believed it pinned a store watches the budget check pass over
      # nothing. Fail loudly instead of resolving something the caller did not ask for.
      [ -n "$2" ] || { printf 'FAIL --memory-dir requires a non-empty value\n' >&2; exit 2; }
      memdir="$2"; shift 2 ;;
    --list) list_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'FAIL unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Last-resort vault resolution: OBSIDIAN_VAULT_PATH from repo-root local.env,
# read as data (see _cg_localenv_get). Agent shells do not inherit local.env,
# so on a configured machine the env var is typically unset — without this the
# wikilink check SKIPped every closeout while the operator believed it ran.
# $AI_CONFIG_LOCAL_ENV points tests at a synthetic local.env (same convention
# as check-drift.sh --auto / install.sh); the flag and the env var still win.
if [ -z "$vault" ]; then
  vault="$(_cg_localenv_get "${AI_CONFIG_LOCAL_ENV:-$SELF_DIR/../local.env}" OBSIDIAN_VAULT_PATH)"
fi
# Same last-resort chain for the project-note budget's memory store: the pin an
# operator records once in local.env is invisible to an agent shell, so without
# this the budget check SKIPped on exactly the machines that have a store.
if [ -z "$memdir" ]; then
  memdir="$(_cg_localenv_get "${AI_CONFIG_LOCAL_ENV:-$SELF_DIR/../local.env}" CLAUDE_PRIMARY_MEMORY_DIR)"
fi

# The check set, in the order closeout.md lists them. One record per line:
#   <name>|<script-basename>|<mode-flag>|<target-label>
# The mode flag's value is the draft for the draft-scanners and the memory dir
# for the project-note budget; the wikilink check appends --vault when one
# resolved. The target label is what --list prints, so the preflight names the
# right subject per check. Keeping this as ONE declaration means --list and the
# runner can never disagree about what the gate is.
CHECKS='injection-scan|check-memory-drift.sh|--injection-scan|<draft>
wikilinks|check-wikilinks.sh|--draft|<draft>
machine-paths|check-machine-paths.sh|--draft|<draft>
project-note-budget|check-project-note-budget.sh|--memory-dir|<memory dir>'

# _gate_skip_reason <name> — echo a named reason when the check's TARGET SURFACE
# is absent (an inapplicable check), else empty. Absence of the SCRIPT, and a
# CONFIGURED-but-broken surface, are different, failing cases.
_gate_skip_reason() {
  case "$1" in
    wikilinks)
      if [ -z "$vault" ]; then
        printf 'no vault configured (--vault / $OBSIDIAN_VAULT_PATH / local.env OBSIDIAN_VAULT_PATH all unset) — no wikilink target surface to resolve against'
      fi
      ;;
    project-note-budget)
      if [ -z "$memdir" ]; then
        printf 'no memory dir configured (--memory-dir / $CLAUDE_PRIMARY_MEMORY_DIR / local.env CLAUDE_PRIMARY_MEMORY_DIR all unset) — no project-note surface to scan'
      fi
      ;;
  esac
}

# _gate_surface_fail_reason <name> — echo a named reason when the check's TARGET
# SURFACE is CONFIGURED but broken. This is a FAILURE, not a skip: a misspelled
# or unsynced vault path must block the durable write, not wave it through.
_gate_surface_fail_reason() {
  case "$1" in
    wikilinks)
      if [ -n "$vault" ] && [ ! -d "$vault" ]; then
        printf 'configured vault does not exist: %s' "$vault"
      fi
      ;;
    project-note-budget)
      if [ -n "$memdir" ] && [ ! -d "$memdir" ]; then
        printf 'configured memory dir does not exist: %s' "$memdir"
      fi
      ;;
  esac
}

if [ "$list_only" -eq 1 ]; then
  printf 'closeout-gate: pre-write checks (fail closed; a missing gate script FAILS, an inapplicable surface SKIPs)\n'
  while IFS='|' read -r name script mode target; do
    [ -n "$name" ] || continue
    # Script existence FIRST, broken surface SECOND, absent surface THIRD — see
    # the PRECEDENCE note in the header.
    reason="$(_gate_skip_reason "$name")"
    bad_surface="$(_gate_surface_fail_reason "$name")"
    if [ ! -f "$SCRIPTS_DIR/$script" ]; then
      printf -- '- %-14s FAIL  gate script missing: %s\n' "$name" "$SCRIPTS_DIR/$script"
    elif [ -n "$bad_surface" ]; then
      printf -- '- %-14s FAIL  %s\n' "$name" "$bad_surface"
    elif [ -n "$reason" ]; then
      printf -- '- %-14s SKIP  %s %s %s — %s\n' "$name" "$script" "$mode" "$target" "$reason"
    else
      printf -- '- %-14s RUN   %s %s %s\n' "$name" "$script" "$mode" "$target"
    fi
  done <<EOF
$CHECKS
EOF
  exit 0
fi

[ -n "$draft" ] || { printf 'FAIL no --draft given (use --list to see the check set)\n' >&2; exit 2; }
[ -f "$draft" ] || { printf 'FAIL draft not found or not a regular file: %s\n' "$draft" >&2; exit 2; }
[ -r "$draft" ] || { printf 'FAIL draft is not readable: %s\n' "$draft" >&2; exit 2; }

passed=0
skipped=0
failed=0
failed_names=""

while IFS='|' read -r name script mode target; do
  [ -n "$name" ] || continue

  # SCRIPT EXISTENCE FIRST, surface applicability second (header PRECEDENCE
  # note). Reversing these lets a missing wikilink gate hide behind "no vault
  # configured" and the whole gate still PASS — fail-open.
  path="$SCRIPTS_DIR/$script"
  if [ ! -f "$path" ]; then
    # FAIL CLOSED: an absent gate has proven nothing.
    printf 'FAIL %-14s gate script missing: %s\n' "$name" "$path"
    failed=$(( failed + 1 ))
    failed_names="$failed_names${failed_names:+, }$name"
    continue
  fi

  # A CONFIGURED but broken surface fails: the durable write this gates would
  # land at a path the operator never inspected.
  bad_surface="$(_gate_surface_fail_reason "$name")"
  if [ -n "$bad_surface" ]; then
    printf 'FAIL %-14s %s\n' "$name" "$bad_surface"
    failed=$(( failed + 1 ))
    failed_names="$failed_names${failed_names:+, }$name"
    continue
  fi

  reason="$(_gate_skip_reason "$name")"
  if [ -n "$reason" ]; then
    printf 'SKIP %-14s %s\n' "$name" "$reason"
    skipped=$(( skipped + 1 ))
    continue
  fi

  # The project-note budget scans the memory STORE, not the draft — its mode
  # flag's value is the resolved memory dir. Every other check takes the draft.
  if [ "$name" = "project-note-budget" ]; then
    set -- "$path" "$mode" "$memdir"
  else
    set -- "$path" "$mode" "$draft"
    [ "$name" = "wikilinks" ] && set -- "$@" --vault "$vault"
  fi
  out="$(bash "$@" 2>&1)"; rc=$?

  if [ "$rc" -eq 0 ]; then
    printf 'PASS %-14s %s %s\n' "$name" "$script" "$mode"
    passed=$(( passed + 1 ))
  else
    printf 'FAIL %-14s %s %s exited %s\n' "$name" "$script" "$mode" "$rc"
    # Echo the check's own output indented, so the operator can act without
    # re-running the underlying command by hand — the manual composition this
    # wrapper replaces.
    printf '%s\n' "$out" | sed 's/^/     | /'
    failed=$(( failed + 1 ))
    failed_names="$failed_names${failed_names:+, }$name"
  fi
done <<EOF
$CHECKS
EOF

if [ "$failed" -gt 0 ]; then
  printf 'GATE FAIL — %s check(s) failed (%s); %s passed, %s skipped. Do NOT write %s — remediate and re-run.\n' \
    "$failed" "$failed_names" "$passed" "$skipped" "$draft"
  exit 1
fi

printf 'GATE PASS — %s check(s) passed, %s skipped. Safe to write %s.\n' \
  "$passed" "$skipped" "$draft"
exit 0
