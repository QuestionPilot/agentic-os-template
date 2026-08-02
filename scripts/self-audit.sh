#!/usr/bin/env bash
# scripts/self-audit.sh — score the agentic OS on five pillars (0-100 total).
#
# Usage:
#   bash scripts/self-audit.sh [--json] [--save <path>]
#                              [--repo-root <path>] [--memory-dir <path>]
#                              [--vault-dir <path>] [--config-dir <path>]
#                              [--injection-warn-kb <n>]
#
# Read-only diagnostic. Never gates: exits 0 unless a USAGE error.
#
# Pillars (5 × 20pt = 100pt):
#   1. Cross-layer handoffs (Linear/memory/vault linkage)
#   2. Memory hygiene (MEMORY.md index, orphans, size, headline-vs-Linear)
#   3. Folder hygiene (empty stubs, anti-pattern dirs, lifecycle successors)
#   4. Verification coverage (capability ↔ recipe linkage, manifest freshness)
#   5. Closeout / spine discipline (spine symmetry, recent state-deltas)
#
# Default inputs:
#   --repo-root    parent dir of this script (i.e. the agentic-os-template checkout)
#   --memory-dir   ALL $CLAUDE_CONFIG_DIR/projects/*/memory/ dirs if --config-dir
#                  or $CLAUDE_CONFIG_DIR resolves (every store is scanned and gaps
#                  are attributed per store — <TEAM>-366; set
#                  CLAUDE_PRIMARY_MEMORY_DIR to pin scoring to a single store);
#                  else skipped. The explicit flag always means exactly one store.
#   --vault-dir    $OBSIDIAN_VAULT_PATH if set; else skipped
#   --config-dir   $CLAUDE_CONFIG_DIR if set; else skipped
#   --codex-memory-dir  the codex-native memory registry, default
#                  $CODEX_HOME/memories when CODEX_HOME resolves (flag >
#                  local.env > ambient env). AUDIT-COVERED read-only surface
#                  (<TEAM>-394), never canonical: scored only for index
#                  presence + the MEMORY.md recall caps; else skipped.
#   --injection-warn-kb  soft kickoff-injection budget in KB for sub-check 2.4
#                  (default 32; flag > local.env INJECTION_SURFACE_WARN_KB >
#                  ambient env > default — <TEAM>-364)
#
# `lineark` (the Linear CLI per linear/linear-setup.md) is optional;
# Linear-side checks degrade with a "skipped: lineark not configured" note.
#
# Output: markdown by default. `--json` emits a structured object for tests:
#   {date, total, pillars{...}, injection_surface, gaps[], skipped[], codex_registry_bytes}
#
# Tests: tests/self-audit.test.sh exercises every pillar with fixtures.
#
# Bash compatibility: avoids `declare -A` (associative arrays) so this runs
# under macOS bash 3.2 like every other script in this repo. Pillar state
# lives in parallel indexed arrays accessed via pillar_idx/pillar_score/etc.
set -uo pipefail

# --- argv ---------------------------------------------------------------------
FORMAT="markdown"
SAVE_PATH=""
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEMORY_DIR=""
VAULT_DIR=""
CONFIG_DIR=""
# Codex-native memory registry (<TEAM>-394): $CODEX_HOME/memories — an
# AUDIT-COVERED read-only surface, never canonical. Empty here = not set by
# flag; the local.env / ambient-env CODEX_HOME fallbacks apply below.
CODEX_MEMORY_DIR=""
# Soft injection-surface budget in KB (<TEAM>-364). Empty here = not set by
# flag; the local.env / ambient-env fallbacks and the default apply below,
# after the config-resolution block (mirroring CONFIG_DIR / VAULT_DIR).
INJECTION_WARN_KB=""
# --isolated turns off all operator-env fallbacks (env vars + lineark detection).
# Used by tests/self-audit.test.sh so fixtures only see what the test sets up.
ISOLATED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --json)        FORMAT="json"; shift ;;
    --save)        SAVE_PATH="${2:?--save needs a path}"; shift 2 ;;
    --repo-root)   REPO_ROOT="${2:?--repo-root needs a path}"; shift 2 ;;
    --memory-dir)  MEMORY_DIR="${2:?--memory-dir needs a path}"; shift 2 ;;
    --codex-memory-dir) CODEX_MEMORY_DIR="${2:?--codex-memory-dir needs a path}"; shift 2 ;;
    --vault-dir)   VAULT_DIR="${2:?--vault-dir needs a path}"; shift 2 ;;
    --config-dir)  CONFIG_DIR="${2:?--config-dir needs a path}"; shift 2 ;;
    --injection-warn-kb) INJECTION_WARN_KB="${2:?--injection-warn-kb needs a value}"; shift 2 ;;
    --isolated)    ISOLATED=1; shift ;;
    -h|--help)     grep -E '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) printf 'self-audit.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# mem_note_type <file> — echo the note's memory type from frontmatter: the first
# `type:` line inside the first `---`-fenced block, top-level or nested under
# `metadata:`. Lowercased; empty if absent (`node_type:` is NOT matched — the
# regex anchors `type:` to the start after optional indent). Mirrors
# check-distillation-completeness.sh + check-memory-drift.sh so every scanner
# agrees on what a "project" note is — the store keeps the type in frontmatter,
# not the filename (<TEAM>-353).
mem_note_type() {
  LC_ALL=C awk '
    NR==1 {
      if (substr($0,1,3) == "\357\273\277") $0 = substr($0,4)   # strip UTF-8 BOM
      if ($0 !~ /^---[[:space:]]*$/) exit
    }
    /^---[[:space:]]*$/ { saw_sep++; if (saw_sep==2) exit; next }
    saw_sep==1 && /^[[:space:]]*type:[[:space:]]*/ {
      v=$0; sub(/^[[:space:]]*type:[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v)
      # Strip one surrounding quote pair so `type: "project"` / `type: '\''project'\''`
      # classify as project, not "project" (else a valid quoted note goes invisible).
      if (length(v) >= 2 && ((substr(v,1,1)=="\"" && substr(v,length(v),1)=="\"") || (substr(v,1,1)=="\047" && substr(v,length(v),1)=="\047"))) v=substr(v,2,length(v)-2)
      print tolower(v); exit
    }
  ' "$1"
}

# Memory-dir scan set (<TEAM>-366). The old _sa_select_memory_dir picker chose the
# ONE projects/*/memory dir with the most project-typed notes and scored only it
# — the same candidates[0] blind-spot class fixed in check-memory-drift +
# check-distillation-completeness (<TEAM>-360): every non-selected store went
# silently unscanned, and the picker could FLIP stores when note counts shifted,
# emitting pillar demands against the wrong store. All discovered stores are now
# scanned, with each gap attributed to the store it fired in. Precedence:
# explicit --memory-dir flag (exactly one store) > $CLAUDE_PRIMARY_MEMORY_DIR
# pin (exactly one store — the pin has always meant single-store scoring) >
# every $CONFIG_DIR/projects/*/memory dir. Populated in the resolution block
# below; only existing dirs enter the set, so pillar code can expand
# "${MEMORY_DIRS[@]}" whenever the count is non-zero (bash 3.2 set -u).
MEMORY_DIRS=()

# _sa_localenv_get <path> <key> — read ONE key's value from local.env WITHOUT
# sourcing the file (<TEAM>-180 F1; twin parity with scripts/self-audit.ps1
# Get-SaLocalEnvValue). The prior `set -a; . local.env` EXECUTED the whole file:
# a hostile or malformed local.env could run arbitrary code, or export a PATH=
# that poisons the lineark/jq/git `command -v` lookups below — the very
# PATH-capture window the PS twin was hardened against. Reading only the 4 config
# keys as DATA (never PATH) closes that and makes the two twins behave
# identically. Mirrors bash sourcing semantics for a key: a later assignment of
# the same key wins; one matching surrounding quote pair is stripped; an unquoted
# backslash-escape collapses (\<c> -> <c>) for parity with lib/local-env.ps1.
_sa_localenv_get() {
  local path="$1" key="$2" line t v f l inner result=""
  [ -f "$path" ] || { printf '%s' ""; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    # trim leading + trailing whitespace
    t="${line#"${line%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    [ -z "$t" ] && continue
    case "$t" in '#'*) continue ;; esac
    # strip an optional leading `export ` (one or more spaces/tabs)
    case "$t" in
      export[[:space:]]*) t="${t#export}"; t="${t#"${t%%[![:space:]]*}"}" ;;
    esac
    # must be KEY=...
    case "$t" in
      "$key="*) v="${t#"$key="}" ;;
      *) continue ;;
    esac
    # one matching quote pair → strip; else collapse \<c> -> <c> on the raw value
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
    result="$v"  # last assignment wins
  done < "$path"
  printf '%s' "$result"
}

# Resolve config + memory defaults if the caller did not override, unless
# --isolated explicitly opted out of all operator-env fallbacks (for tests).
if [ "$ISOLATED" -eq 0 ]; then
  # <TEAM>-180 D2/F1: read operator config from local.env WITHOUT sourcing it, so a
  # no-flag run is REPRODUCIBLE across shells (the contract documented in
  # capabilities/self-audit.md). Without this the script read $CLAUDE_CONFIG_DIR /
  # $OBSIDIAN_VAULT_PATH from the environment only, so a shell that had not
  # exported them silently skipped the vault layer and scored differently than one
  # that had (observed: 60/100 vs 80/100 for the same repo state). F1 (Codex
  # pre-merge review): the earlier `set -a; . local.env` EXECUTED the whole file —
  # arbitrary code + a hostile PATH= could poison the lineark/jq/git lookups below
  # — diverging from the hardened PS twin. We now read ONLY the 4 config keys as
  # DATA via _sa_localenv_get (never PATH). local.env wins over ambient env;
  # explicit CLI flags still win over local.env (they set CONFIG_DIR / VAULT_DIR
  # before this runs). --isolated skips it so fixtures only see what the test sets.
  if [ -f "$REPO_ROOT/local.env" ]; then
    if [ -z "$CONFIG_DIR" ]; then
      _le_v="$(_sa_localenv_get "$REPO_ROOT/local.env" CLAUDE_CONFIG_DIR)"
      [ -n "$_le_v" ] && CONFIG_DIR="$_le_v"
    fi
    if [ -z "$VAULT_DIR" ]; then
      _le_v="$(_sa_localenv_get "$REPO_ROOT/local.env" OBSIDIAN_VAULT_PATH)"
      [ -n "$_le_v" ] && VAULT_DIR="$_le_v"
    fi
    # CLAUDE_PRIMARY_MEMORY_DIR: export the local.env pin so the memory-dir
    # resolution below honours it AND it wins over an ambient pin — preserving
    # flag > local.env > ambient. Only this single config key is ever exported
    # (never PATH). Mirrors the PS twin.
    _le_v="$(_sa_localenv_get "$REPO_ROOT/local.env" CLAUDE_PRIMARY_MEMORY_DIR)"
    [ -n "$_le_v" ] && export CLAUDE_PRIMARY_MEMORY_DIR="$_le_v"
    # INJECTION_SURFACE_WARN_KB (<TEAM>-364): same precedence as the paths —
    # flag (already set above) > local.env > ambient env > default.
    if [ -z "$INJECTION_WARN_KB" ]; then
      _le_v="$(_sa_localenv_get "$REPO_ROOT/local.env" INJECTION_SURFACE_WARN_KB)"
      [ -n "$_le_v" ] && INJECTION_WARN_KB="$_le_v"
    fi
    # CODEX_HOME (<TEAM>-394): the codex-native memory registry lives at
    # $CODEX_HOME/memories. Same precedence as the other paths — flag (already
    # set above) > local.env > ambient env. Never joins MEMORY_DIRS: its
    # registry shape (index + summary/raw sidecars + rollout_summaries/) would
    # false-trip the note-store orphan/index checks; it gets its own pillar-2
    # surface instead.
    if [ -z "$CODEX_MEMORY_DIR" ]; then
      _le_v="$(_sa_localenv_get "$REPO_ROOT/local.env" CODEX_HOME)"
      [ -n "$_le_v" ] && [ -d "$_le_v/memories" ] && CODEX_MEMORY_DIR="$_le_v/memories"
    fi
    unset _le_v
  fi
  if [ -z "$CONFIG_DIR" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    CONFIG_DIR="$CLAUDE_CONFIG_DIR"
  fi
  if [ -z "$VAULT_DIR" ] && [ -n "${OBSIDIAN_VAULT_PATH:-}" ]; then
    VAULT_DIR="$OBSIDIAN_VAULT_PATH"
  fi
  if [ -z "$INJECTION_WARN_KB" ] && [ -n "${INJECTION_SURFACE_WARN_KB:-}" ]; then
    INJECTION_WARN_KB="$INJECTION_SURFACE_WARN_KB"
  fi
  if [ -z "$CODEX_MEMORY_DIR" ] && [ -n "${CODEX_HOME:-}" ] && [ -d "$CODEX_HOME/memories" ]; then
    CODEX_MEMORY_DIR="$CODEX_HOME/memories"
  fi
  if [ -z "$MEMORY_DIR" ] && [ -n "$CONFIG_DIR" ] && [ -d "$CONFIG_DIR/projects" ]; then
    # <TEAM>-366: no flag → a $CLAUDE_PRIMARY_MEMORY_DIR pin scopes the scan to
    # that one store; otherwise EVERY projects/*/memory dir is scanned (the old
    # picker scored only the "largest" store and left the rest invisible).
    if [ -n "${CLAUDE_PRIMARY_MEMORY_DIR:-}" ] && [ -d "${CLAUDE_PRIMARY_MEMORY_DIR}" ]; then
      MEMORY_DIRS=("$CLAUDE_PRIMARY_MEMORY_DIR")
    else
      for _md_d in "$CONFIG_DIR"/projects/*/memory; do
        [ -d "$_md_d" ] && MEMORY_DIRS+=("$_md_d")
      done
      unset _md_d
    fi
  fi
fi

# Explicit --memory-dir wins over everything and means exactly ONE store
# (mirrors check-memory-drift.sh). A non-existent flag value resolves to an
# empty scan set, so the memory surface reports skipped — same as before.
if [ -n "$MEMORY_DIR" ]; then
  if [ -d "$MEMORY_DIR" ]; then MEMORY_DIRS=("$MEMORY_DIR"); else MEMORY_DIRS=(); fi
fi

# Codex registry mirrors that contract: a non-existent path (flag or resolved)
# empties the surface — reported skipped, never an error (<TEAM>-394).
if [ -n "$CODEX_MEMORY_DIR" ] && [ ! -d "$CODEX_MEMORY_DIR" ]; then
  CODEX_MEMORY_DIR=""
fi

# Validate the resolved injection budget: positive integer KB, else fall back
# to the 32 KB default SILENTLY. The measurement is advisory — a soft warn,
# never a gate (a design panel explicitly rejected a hard cap — <TEAM>-364) —
# so a garbage knob value must degrade to the default, not break the audit.
case "$INJECTION_WARN_KB" in
  ''|*[!0-9]*) INJECTION_WARN_KB=32 ;;
  *) [ "$INJECTION_WARN_KB" -gt 0 ] 2>/dev/null || INJECTION_WARN_KB=32 ;;
esac

# --- pillar state -- parallel indexed arrays, bash 3.2 compatible -------------
PILLAR_KEYS=(
  "cross-layer-handoffs"
  "memory-hygiene"
  "folder-hygiene"
  "verification-coverage"
  "closeout-spine-discipline"
)
PILLAR_LABELS=(
  "1. Cross-layer handoffs"
  "2. Memory hygiene"
  "3. Folder hygiene"
  "4. Verification coverage"
  "5. Closeout / spine discipline"
)
# Two parallel arrays seed-aligned with PILLAR_KEYS. Mutated via the
# pillar_set_* helpers below; never indexed by key directly elsewhere.
PILLAR_SCORES=(20 20 20 20 20)
PILLAR_NOTES=("clean" "clean" "clean" "clean" "clean")
# 1 = the pillar could not run a single real check (its surface — Linear/memory/
# vault — was absent). Such a pillar is floored to 0 and rendered UNSCORED, never
# left at the seeded 20: core/verification.md requires that a check which cannot
# run must fail, never pass. Without this, a fresh clone with no operator surfaces
# summed to a false ~100/100 "in good shape".
PILLAR_UNSCORED=(0 0 0 0 0)

# pillar_idx <key>  → index (0..4) on stdout; return 1 on unknown key.
pillar_idx() {
  local key="$1" i
  for i in 0 1 2 3 4; do
    if [ "${PILLAR_KEYS[$i]}" = "$key" ]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

pillar_score() {
  local idx; idx="$(pillar_idx "$1")" || { printf '0'; return 1; }
  printf '%s' "${PILLAR_SCORES[$idx]}"
}

pillar_set_score() {
  local idx; idx="$(pillar_idx "$1")" || return 1
  PILLAR_SCORES[$idx]="$2"
}

pillar_note() {
  local idx; idx="$(pillar_idx "$1")" || { printf '%s' ""; return 1; }
  printf '%s' "${PILLAR_NOTES[$idx]}"
}

pillar_set_note() {
  local idx; idx="$(pillar_idx "$1")" || return 1
  PILLAR_NOTES[$idx]="$2"
}

# --- accumulators -------------------------------------------------------------
SKIPPED=()                # one line per skipped surface
GAPS=()                   # one record per gap: PILLAR<TAB>LEVERAGE<TAB>TITLE<TAB>DETAIL<TAB>FIX

# Injection-surface measurement state (<TEAM>-364), filled by sub-check 2.4 in
# score_memory_hygiene and read by both emitters. Parallel indexed arrays
# (bash 3.2 — no associative arrays), one slot per RESOLVED component;
# INJ_SKIPPED lists the component names that could not resolve. INJ_MEASURED=0
# means no component resolved at all → the emitters report not-measured
# (JSON: injection_surface = null) instead of a misleading 0-byte total.
INJ_MEASURED=0
INJ_TOTAL_BYTES=0
INJ_WARNED=0
INJ_COMP_NAMES=()
INJ_COMP_PATHS=()
INJ_COMP_BYTES=()
INJ_SKIPPED=()

# Codex-native registry reporting state (<TEAM>-468), filled by sub-check 2.5.
# Purely INFORMATIONAL — never scored, never a gap. -1 means "not measured"
# (no registry resolved, or it holds no MEMORY.md); the emitters report the
# byte size only when it is >= 0.
CODEX_REGISTRY_BYTES=-1
CODEX_REGISTRY_PATH=""

# --- helpers ------------------------------------------------------------------
record_gap() {
  # record_gap <pillar-num> <leverage> <title> <detail> <fix>
  local p="$1" lev="$2" title="$3" detail="$4" fix="$5"
  # ASCII tab separator — safe; titles/details/fixes never contain raw tabs.
  GAPS+=("$(printf '%s\t%s\t%s\t%s\t%s' "$p" "$lev" "$title" "$detail" "$fix")")
}

sorted_gaps() {
  # GAPS ordered by leverage descending, ties in insertion order — the
  # tie-break the PS twin's Get-SortedGaps keys on too. A bare `sort -nr`
  # falls back to a REVERSED whole-line comparison on equal leverage
  # (descending pillar/text), diverging from PowerShell's stable sort; the
  # decorate/sort/undecorate index makes the tie-break explicit instead of
  # implementation-defined. awk over `nl` so minimal userlands (busybox/
  # alpine) need nothing beyond the awk the script already requires.
  # Fields after the index prefix: 1=index, 2=pillar, 3=leverage.
  printf '%s\n' "${GAPS[@]}" | awk '{ printf "%d\t%s\n", NR, $0 }' \
    | sort -t "$(printf '\t')" -k3,3nr -k1,1n | cut -f2-
}

deduct() {
  # deduct <pillar-key> <amount>  — clamped at 0; never below.
  local key="$1" amt="$2" cur
  cur="$(pillar_score "$key")"
  local new=$(( cur - amt ))
  [ "$new" -lt 0 ] && new=0
  pillar_set_score "$key" "$new"
}

skip_surface() {
  SKIPPED+=("$1")
}

mark_unscored() {
  # mark_unscored <pillar-key> <reason> — floor a pillar that ran zero real
  # checks to 0 and flag it UNSCORED, so the aggregate never counts an unmeasured
  # surface as a clean 20 (core/verification.md: a cannot-run check must fail, not pass).
  local idx; idx="$(pillar_idx "$1")" || return 1
  PILLAR_SCORES[$idx]=0
  PILLAR_UNSCORED[$idx]=1
  pillar_set_note "$1" "UNSCORED — $2"
}

# fm_get <file> <key>  → first matching value, trimmed leading + trailing.
# Codex N-1: original implementation only trimmed leading whitespace, so a key
# written as `kind: native ` with a trailing space would fail downstream equality
# checks (e.g. `[ "$kind" = "native" ]`).
fm_get() {
  local f="$1" k="$2"
  [ -f "$f" ] || return 0
  awk -v key="$k" '
    NR==1 { if ($0!="---") exit; next }
    /^---[[:space:]]*$/ { exit }
    $0 ~ "^"key":" {
      sub("^"key":[[:space:]]*", "")
      sub("[[:space:]]+$", "")
      print; exit
    }
  ' "$f"
}

# --- Pillar 1: Cross-layer handoffs ------------------------------------------
score_cross_layer_handoffs() {
  local key="cross-layer-handoffs"
  local lineark_avail=0 memory_avail=0 vault_avail=0
  # In --isolated mode (tests) skip lineark detection too — the operator's
  # real Linear surface must not leak into fixture scoring.
  if [ "$ISOLATED" -eq 0 ]; then
    command -v lineark >/dev/null 2>&1 && lineark_avail=1
  fi
  [ "${#MEMORY_DIRS[@]}" -gt 0 ] && memory_avail=1
  [ -n "$VAULT_DIR" ] && [ -d "$VAULT_DIR" ] && vault_avail=1

  if [ "$lineark_avail" -eq 0 ]; then
    skip_surface "lineark not installed — Linear-side cross-layer checks skipped"
  fi
  if [ "$memory_avail" -eq 0 ]; then
    skip_surface "memory dir not resolved — memory-side cross-layer checks skipped"
  fi
  if [ "$vault_avail" -eq 0 ]; then
    skip_surface "vault dir not configured — vault-side cross-layer checks skipped"
  fi

  # Codex S-4: emit a skip note ONCE if jq is missing — without it, Linear
  # sub-checks silently bypass and Pillar 1 scores false-clean. Single notice
  # for both 1.1 and 1.2.
  local need_jq_warned=0
  if [ "$lineark_avail" -eq 1 ] && ! command -v jq >/dev/null 2>&1; then
    skip_surface "jq not installed — Linear-side cross-layer checks skipped"
    need_jq_warned=1
  fi

  # Track whether ANY sub-check actually measured something. A pillar that
  # measured nothing (no reachable surface) is UNSCORED at finalize, not a free 20.
  local ran=0

  # Active-project list — Linear projects with >=1 OPEN issue, computed once and
  # shared by sub-checks 1.1 (memory) + 1.2 (vault). A project with zero open
  # issues (all Done/Canceled — lineark hides those by default) is closed-out and
  # must NOT demand a memory/vault handshake (<TEAM>-353): self-audit used to flag
  # EVERY `lineark projects list` entry, so closed Agentic-OS sub-projects (Launch
  # Gate, Pre-Ship Review Fixes, …) kept deducting forever. If a per-project
  # issues query errors we KEEP the project (conservative — a transient lineark
  # error must not hide a real handshake gap). Codex B-2: pin `--format json`.
  local active_projects=()
  if [ "$lineark_avail" -eq 1 ] && command -v jq >/dev/null 2>&1; then
    local _pj _pid _pname _ij _oc
    _pj="$(lineark projects list --format json 2>/dev/null || true)"
    if [ -n "$_pj" ]; then
      while IFS="$(printf '\t')" read -r _pid _pname; do
        [ -n "$_pname" ] || continue
        if [ -n "$_pid" ]; then
          _ij="$(lineark issues list --project "$_pid" --format json 2>/dev/null || true)"
          if [ -n "$_ij" ]; then
            _oc="$(printf '%s' "$_ij" | jq 'length' 2>/dev/null || printf -- '-1')"
            [ "$_oc" = "0" ] && continue
          fi
        fi
        active_projects+=("$_pname")
      done <<< "$(printf '%s' "$_pj" | jq -r '.[] | [.id, .name] | @tsv' 2>/dev/null || true)"
    fi
  fi

  # Project-type memory notes (frontmatter type: project, not a filename glob —
  # <TEAM>-353), collected once for the 1.1 name-match. Space-safe (NUL find).
  # <TEAM>-366: collected across ALL scanned stores — a project note in ANY store
  # satisfies the handshake (the old single-store scan demanded the note in
  # whichever store the picker happened to select).
  local proj_note_files=()
  if [ "$memory_avail" -eq 1 ]; then
    local _mf
    while IFS= read -r -d '' _mf; do
      [ "$(basename "$_mf")" = "MEMORY.md" ] && continue
      [ "$(mem_note_type "$_mf")" = "project" ] && proj_note_files+=("$_mf")
    done < <(find "${MEMORY_DIRS[@]}" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)
  fi

  # Sub-check 1.1: For each ACTIVE Linear project (>=1 open issue), a matching
  # project-type memory note (frontmatter type: project — <TEAM>-353). lineark slug
  # != memory filename, so match the project NAME in note bodies, not filenames.
  if [ "$lineark_avail" -eq 1 ] && [ "$memory_avail" -eq 1 ] && command -v jq >/dev/null 2>&1; then
    ran=1
    if [ "${#active_projects[@]}" -gt 0 ]; then
      local pname
      for pname in "${active_projects[@]}"; do
        [ -n "$pname" ] || continue
        local matched=0
        if [ "${#proj_note_files[@]}" -gt 0 ] && grep -lF "$pname" "${proj_note_files[@]}" >/dev/null 2>&1; then
          matched=1
        fi
        if [ "$matched" -eq 0 ]; then
          deduct "$key" 4
          record_gap 1 8 \
            "No memory note for active Linear project" \
            "Active project \"$pname\" has no project-type memory note in any scanned memory store (${MEMORY_DIRS[*]}) — active projects should land a memory note at kickoff" \
            "Create a note in the project's memory store with 'type: project' frontmatter naming the project + its Linear URL"
        fi
      done
    fi
  fi

  # Sub-check 1.2: For each ACTIVE Linear project (>=1 open issue), a matching
  # vault Handshake. Shares the active_projects list from 1.1 (zero-open-issue
  # projects already filtered out — <TEAM>-353).
  if [ "$lineark_avail" -eq 1 ] && [ "$vault_avail" -eq 1 ] && command -v jq >/dev/null 2>&1; then
    ran=1
    if [ "${#active_projects[@]}" -gt 0 ]; then
      local pname
      for pname in "${active_projects[@]}"; do
        [ -n "$pname" ] || continue
        local matched=0
        if [ -d "$VAULT_DIR/01-Projects" ]; then
          if grep -rlF "$pname" "$VAULT_DIR/01-Projects" >/dev/null 2>&1; then
            matched=1
          fi
        fi
        if [ "$matched" -eq 0 ]; then
          deduct "$key" 4
          record_gap 1 6 \
            "No vault handshake for active Linear project" \
            "Active project \"$pname\" has no Handshake note in $VAULT_DIR/01-Projects/" \
            "Create $VAULT_DIR/01-Projects/<slug>.md with linear: frontmatter pointing to the Linear URL"
        fi
      done
    fi
  fi

  # Sub-check 1.3: Walk MEMORY.md links — every relative .md target must exist.
  # Codex N-2: original regex required `.md)` literally, missing `.md#anchor)`
  # forms. Broaden to `[^)]+\.md(#[^)]*)?` then strip the #anchor before
  # existence-checking the file. <TEAM>-366: per store — each store's own index
  # is walked, and a broken-link gap names the store it fired in.
  if [ "$memory_avail" -eq 1 ]; then
    local md_dir
    for md_dir in "${MEMORY_DIRS[@]}"; do
      [ -f "$md_dir/MEMORY.md" ] || continue
      ran=1
      local broken=0
      while IFS= read -r target; do
        [ -n "$target" ] || continue
        case "$target" in http://*|https://*|mailto:*|/*) continue ;; esac
        # Strip #anchor — file existence is what we check, not the anchor target.
        target="${target%%#*}"
        [ -z "$target" ] && continue
        if [ ! -f "$md_dir/$target" ]; then
          broken=$((broken+1))
        fi
      done < <(grep -oE '\]\([^)]+\.md(#[^)]*)?\)' "$md_dir/MEMORY.md" | sed 's/^](//; s/)$//' || true)
      if [ "$broken" -gt 0 ]; then
        local pen=$(( broken * 2 ))
        [ "$pen" -gt 8 ] && pen=8
        deduct "$key" "$pen"
        record_gap 1 4 \
          "Broken MEMORY.md link(s)" \
          "MEMORY.md references $broken file(s) that do not exist in $md_dir" \
          "Remove the broken index lines or restore the missing memory files"
      fi
    done
  fi

  # Finalize note. A pillar that ran zero sub-checks (no reachable cross-layer
  # surface) is UNSCORED — not a free 20.
  if [ "$ran" -eq 0 ]; then
    mark_unscored "$key" "no cross-layer surface reachable (lineark/memory/vault)"
    return
  fi
  local s; s="$(pillar_score "$key")"
  if [ "$s" -eq 20 ]; then
    pillar_set_note "$key" "clean"
  else
    pillar_set_note "$key" "$((20 - s)) pts deducted; see top gaps"
  fi
}

# --- Pillar 2: Memory hygiene ------------------------------------------------
# Informational codex-registry measurement (<TEAM>-468). Deliberately OUTSIDE
# the pillar's scored path: a codex-only install (zero claude stores) hits the
# UNSCORED early-return below, but the registry's byte size must still be
# reported — codex_registry_bytes is null ONLY when no registry resolved or it
# holds no MEMORY.md (the documented contract; panel finding). Sets globals
# only; never deducts, never records a gap.
measure_codex_registry() {
  [ -n "$CODEX_MEMORY_DIR" ] && [ -f "$CODEX_MEMORY_DIR/MEMORY.md" ] || return 0
  local cx_size
  cx_size="$(wc -c < "$CODEX_MEMORY_DIR/MEMORY.md" 2>/dev/null | tr -d ' ')"
  if [ -n "$cx_size" ]; then
    CODEX_REGISTRY_BYTES="$cx_size"
    CODEX_REGISTRY_PATH="$CODEX_MEMORY_DIR/MEMORY.md"
  fi
}

score_memory_hygiene() {
  local key="memory-hygiene"
  measure_codex_registry
  if [ "${#MEMORY_DIRS[@]}" -eq 0 ]; then
    skip_surface "memory dir not resolved — memory hygiene checks skipped"
    mark_unscored "$key" "no memory dir"
    return 0
  fi

  # <TEAM>-366: every discovered store is scored, not one selected store — the
  # sub-checks below run PER STORE and each gap names the store it fired in.
  # A hygiene failure in a small secondary store is a real failure (its notes
  # are just as invisible at orient); the old picker never saw it.
  local md_dir missing_index=0
  for md_dir in "${MEMORY_DIRS[@]}"; do

    if [ ! -f "$md_dir/MEMORY.md" ]; then
      # MEMORY.md missing entirely is a 20pt hit — the index is the spine of
      # memory recall; a store without one runs blind at every kickoff orient.
      deduct "$key" 20
      record_gap 2 10 \
        "MEMORY.md index missing" \
        "$md_dir/MEMORY.md does not exist; every kickoff orient runs blind" \
        "Create MEMORY.md with one line per memory file per core/memory-model.md"
      missing_index=1
      continue
    fi

    # Sub-check 2.1: For each memory file (excluding MEMORY.md itself), the
    # store's index should reference it by name. An "orphan" is a file this
    # store's MEMORY.md never names.
    local orphans=0 index_content
    index_content="$(cat "$md_dir/MEMORY.md")"
    while IFS= read -r -d '' mf; do
      [ -f "$mf" ] || continue
      local base; base="$(basename "$mf")"
      [ "$base" = "MEMORY.md" ] && continue
      # Fixed-string match avoids regex surprises in slugs with dashes.
      case "$index_content" in
        *"$base"*) ;;
        *) orphans=$((orphans+1)) ;;
      esac
    done < <(find "$md_dir" -maxdepth 1 -name '*.md' -print0 2>/dev/null)

    if [ "$orphans" -gt 0 ]; then
      local pen=$(( orphans * 2 ))
      [ "$pen" -gt 10 ] && pen=10
      deduct "$key" "$pen"
      record_gap 2 3 \
        "Orphan memory file(s)" \
        "$orphans memory file(s) in $md_dir have no MEMORY.md index entry" \
        "Run /consolidate-memory or hand-add a one-line pointer to MEMORY.md"
    fi

    # Sub-check 2.2: MEMORY.md total size vs recall cap.
    # The router truncates memory recall around ~24400 bytes; over-cap loses
    # tail entries silently. Threshold mirrors the harness warning observed in
    # the autoloaded MEMORY.md system reminder. The 24400 constant is the
    # documented MEMORY_INDEX_SIZE_CAP_BYTES in core/memory-model.md.
    local size_bytes
    size_bytes="$(wc -c < "$md_dir/MEMORY.md" 2>/dev/null | tr -d ' ')"
    if [ -n "$size_bytes" ] && [ "$size_bytes" -gt 24400 ]; then
      deduct "$key" 4
      record_gap 2 5 \
        "MEMORY.md over recall cap" \
        "$md_dir/MEMORY.md is ${size_bytes} bytes (over the ~24400 recall cap)" \
        "Shorten the longest one-line index entries; move detail into the named topic files"
    fi

    # Sub-check 2.3: per-entry line-length cap. Index entries are one-line
    # headlines; a line over ~300 chars is detail that belongs in the named topic
    # file. Over-long entries inflate the index toward the size cap above and
    # degrade scannability. Threshold is MEMORY_INDEX_LINE_CAP_CHARS in
    # core/memory-model.md. The cap is in CHARS and the PS twin counts characters
    # via .Length, so we count CHARACTERS here too: byte length minus UTF-8
    # continuation bytes (0x80–0xBF) yields the Unicode codepoint count
    # locale-independently (BSD awk's `length` is byte-only regardless of locale).
    # LC_ALL=C keeps both length + gsub deterministic across BSD/GNU awk (set
    # explicitly so gawk's gsub does not no-op under empty LANG —
    # see [[reference_awk_portability]]). Matches PS .Length for all BMP chars.
    #
    local long_lines
    long_lines="$(LC_ALL=C awk '{ s=$0; cont=gsub(/[\200-\277]/,"",s); if ((length($0)-cont) > 300) n++ } END { print n+0 }' "$md_dir/MEMORY.md" 2>/dev/null)"
    if [ -n "$long_lines" ] && [ "$long_lines" -gt 0 ]; then
      deduct "$key" 4
      record_gap 2 5 \
        "MEMORY.md entries over line-length cap" \
        "$long_lines index line(s) in $md_dir/MEMORY.md exceed the ~300-char per-entry cap" \
        "Trim each to a one-line headline; move detail into the named topic file"
    fi
  done

  # Sub-check 2.5 (<TEAM>-394, rescoped <TEAM>-468): the codex-native memory
  # registry — an AUDIT-COVERED read-only surface, never canonical.
  # $CODEX_HOME/memories is a registry (MEMORY.md index + summary/raw sidecars +
  # rollout_summaries/), not a note-per-fact store, so the orphan/index-integrity
  # checks above do NOT apply — a codex sidecar unnamed by its index is normal,
  # not a gap.
  #
  # <TEAM>-468: the 2.2/2.3 recall caps (MEMORY_INDEX_SIZE_CAP_BYTES = 24400,
  # MEMORY_INDEX_LINE_CAP_CHARS = 300) do NOT transfer here either. Those are
  # CLAUDE-SIDE recall semantics documented in core/memory-model.md. Primary-source
  # review of openai/codex at tag rust-v0.144.1 found NO byte-size cap and NO
  # read-side truncation on memories/MEMORY.md anywhere in the memories crates
  # (codex-rs/memories/read/, codex-rs/memories/write/, codex-rs/ext/memories/);
  # the only size limits are write-side consolidation inputs (rollout contents
  # truncated to 70% of model context in memories/write/src/prompts.rs; a 4 MB
  # workspace-diff MAX_BYTES in memories/write/src/lib.rs), and consolidation
  # eligibility is rate-limit/idle gated (memories/write/src/guard.rs), not size
  # gated. Empirically codex's own consolidator rewrites the registry well past
  # both framework caps. So the registry format is the consolidator's to own:
  # what remains scored here is index PRESENCE (a codex kickoff with no index
  # runs blind), and the registry's byte size is reported INFORMATIONALLY —
  # no deduction, no gap entry.
  #
  # Resolution is flag > local.env CODEX_HOME > ambient env; when none resolve
  # (claude-only install) the surface is skipped and scoring is unchanged. KNOWN
  # COUPLING (panel C6, accepted): the empty-registry DEDUCTION rides the memory
  # pillar, so a codex-ONLY setup with zero claude stores hits the pillar's
  # UNSCORED early-return before it — audit-covered means "covered wherever the
  # pillar scores", matching the sub-check-2.4 precedent, not a standalone codex
  # audit. The informational MEASUREMENT does not ride the pillar: it runs in
  # measure_codex_registry() before the early return (panel <TEAM>-468 finding),
  # so codex_registry_bytes is populated whenever a registry with a MEMORY.md
  # resolved — null keeps exactly its two documented meanings.
  if [ -n "$CODEX_MEMORY_DIR" ] && [ -d "$CODEX_MEMORY_DIR" ] && [ ! -f "$CODEX_MEMORY_DIR/MEMORY.md" ]; then
    deduct "$key" 6
    record_gap 2 5 \
      "Codex memory registry has no MEMORY.md index" \
      "$CODEX_MEMORY_DIR exists but holds no MEMORY.md — codex kickoffs run blind on native memory" \
      "Let codex rebuild its native index, or remove the empty registry dir"
  fi

  # Sub-check 2.4 (<TEAM>-364): per-session injection-surface size. These four
  # components are injected into EVERY kickoff orient — the memory index (worst
  # case: the LARGEST MEMORY.md across the framework's own per-note stores),
  # the rendered harness CLAUDE.md, the vault entrypoint
  # START.md, and the operator-identity note START.md names — so oversize here
  # is a per-session context tax no other check measures. SOFT threshold only:
  # a design panel explicitly rejected a hard cap (a large surface can be a
  # deliberate operator choice), so crossing INJECTION_SURFACE_WARN_KB (default
  # 32) warns once and never errors. A component that cannot resolve is SKIPPED
  # by name, never an error; the measurement rides the memory surface (the
  # index is the dominant injected component), so when zero stores resolved the
  # pillar returned UNSCORED above and the surface reports not-measured.
  #
  # <TEAM>-468: the codex-native registry is EXCLUDED from this scan. It is
  # consolidator-owned and unactionable by the operator — a soft warn driven by
  # it is pure alarm fatigue with no fix to offer. Claude-side stores still
  # compete for largest-store; the registry's size stays visible via the
  # informational line sub-check 2.5 records.
  local inj_largest_path="" inj_largest_bytes=-1 inj_b
  local inj_scan_dirs=("${MEMORY_DIRS[@]}")
  for md_dir in "${inj_scan_dirs[@]}"; do
    [ -f "$md_dir/MEMORY.md" ] || continue
    inj_b="$(wc -c < "$md_dir/MEMORY.md" 2>/dev/null | tr -d ' ')"
    [ -n "$inj_b" ] || continue
    # Strictly-greater keeps the FIRST store on a size tie — MEMORY_DIRS order
    # is already the twins' deterministic store order, so the reported path
    # (which store is worst-case) matches across machines and twins.
    if [ "$inj_b" -gt "$inj_largest_bytes" ]; then
      inj_largest_bytes="$inj_b"
      inj_largest_path="$md_dir/MEMORY.md"
    fi
  done
  if [ -n "$inj_largest_path" ]; then
    INJ_COMP_NAMES+=("MEMORY.md (largest store)")
    INJ_COMP_PATHS+=("$inj_largest_path")
    INJ_COMP_BYTES+=("$inj_largest_bytes")
  else
    INJ_SKIPPED+=("MEMORY.md (largest store)")
  fi

  if [ -n "$CONFIG_DIR" ] && [ -f "$CONFIG_DIR/CLAUDE.md" ]; then
    inj_b="$(wc -c < "$CONFIG_DIR/CLAUDE.md" 2>/dev/null | tr -d ' ')"
    INJ_COMP_NAMES+=("CLAUDE.md (rendered)")
    INJ_COMP_PATHS+=("$CONFIG_DIR/CLAUDE.md")
    INJ_COMP_BYTES+=("${inj_b:-0}")
  else
    INJ_SKIPPED+=("CLAUDE.md (rendered)")
  fi

  local inj_start_ok=0
  if [ -n "$VAULT_DIR" ] && [ -f "$VAULT_DIR/START.md" ]; then
    inj_start_ok=1
    inj_b="$(wc -c < "$VAULT_DIR/START.md" 2>/dev/null | tr -d ' ')"
    INJ_COMP_NAMES+=("START.md (vault)")
    INJ_COMP_PATHS+=("$VAULT_DIR/START.md")
    INJ_COMP_BYTES+=("${inj_b:-0}")
  else
    INJ_SKIPPED+=("START.md (vault)")
  fi

  # Operator-identity note — mechanical resolution rule: the FIRST [[wikilink]]
  # target in START.md BEFORE the first line starting `## Read Order` (the
  # vault contract has the entrypoint name the identity note ahead of its read
  # order, so anything linked earlier IS the identity pointer). A `|alias` and
  # a `#heading` suffix are stripped before resolving $VAULT_DIR/<target>.md.
  # No such link, or no file at the target → skipped, never an error.
  local inj_identity=""
  if [ "$inj_start_ok" -eq 1 ]; then
    inj_identity="$(awk '
      /^## Read Order/ { exit }
      match($0, /\[\[[^]]+\]\]/) {
        t = substr($0, RSTART+2, RLENGTH-4)
        sub(/\|.*$/, "", t)
        sub(/#.*$/, "", t)
        print t
        exit
      }
    ' "$VAULT_DIR/START.md" 2>/dev/null)"
  fi
  if [ -n "$inj_identity" ] && [ -f "$VAULT_DIR/$inj_identity.md" ]; then
    inj_b="$(wc -c < "$VAULT_DIR/$inj_identity.md" 2>/dev/null | tr -d ' ')"
    INJ_COMP_NAMES+=("identity note")
    INJ_COMP_PATHS+=("$VAULT_DIR/$inj_identity.md")
    INJ_COMP_BYTES+=("${inj_b:-0}")
  else
    INJ_SKIPPED+=("identity note")
  fi

  if [ "${#INJ_COMP_NAMES[@]}" -gt 0 ]; then
    INJ_MEASURED=1
    local inj_i inj_total=0 inj_list=""
    for inj_i in "${!INJ_COMP_NAMES[@]}"; do
      inj_total=$(( inj_total + ${INJ_COMP_BYTES[$inj_i]} ))
      [ -n "$inj_list" ] && inj_list="$inj_list, "
      inj_list="${inj_list}${INJ_COMP_NAMES[$inj_i]}=${INJ_COMP_BYTES[$inj_i]}"
    done
    INJ_TOTAL_BYTES="$inj_total"
    if [ "$inj_total" -gt $(( INJECTION_WARN_KB * 1024 )) ]; then
      INJ_WARNED=1
      # A single whole-surface aggregate, not a per-store scan — so this warn
      # fires at most ONCE per run regardless of how many stores were scanned.
      deduct "$key" 2
      record_gap 2 4 \
        "Injection surface over soft threshold" \
        "$inj_total bytes across ${#INJ_COMP_NAMES[@]} component(s) exceeds the soft $INJECTION_WARN_KB KB kickoff-injection budget (components: $inj_list)" \
        "Trim MEMORY.md entries / the CLAUDE.md sources / the identity note — or raise INJECTION_SURFACE_WARN_KB if the size is deliberate"
    fi
  fi

  local s; s="$(pillar_score "$key")"
  if [ "$s" -eq 20 ]; then
    pillar_set_note "$key" "clean"
  elif [ "$missing_index" -eq 1 ]; then
    pillar_set_note "$key" "MEMORY.md missing"
  else
    pillar_set_note "$key" "$((20 - s)) pts deducted; see top gaps"
  fi
}

# --- Pillar 3: Folder hygiene -------------------------------------------------
score_folder_hygiene() {
  local key="folder-hygiene"

  # Codex S-3: scope folder-hygiene scans to framework-tracked surfaces. Git
  # doesn't track empty dirs, so empty-dir scans are inherently "untracked
  # filesystem". The right semantics here: ignore anything `.gitignore` excludes
  # (operator-managed scratch, worktrees, build artifacts) — only flag dirs
  # whose existence is the framework's concern.
  local has_git=0
  if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    has_git=1
  fi

  # _sa_path_gitignored <relative-path> → 0 if .gitignore excludes it, else 1.
  _sa_path_gitignored() {
    [ "$has_git" -eq 1 ] || return 1
    git -C "$REPO_ROOT" check-ignore -q "$1" 2>/dev/null
  }

  # Sub-check 3.1: Empty directories under the repo (excluding .git, harness
  # worktrees, .install-build.* sentinels, and anything .gitignore excludes).
  # An empty dir is dead weight in the FRAMEWORK; operator-local scratch dirs
  # in .gitignore are out of scope.
  local empty_dirs=() rel
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$d" in
      "$REPO_ROOT"/.git|"$REPO_ROOT"/.git/*) continue ;;
      "$REPO_ROOT"/.claude/worktrees|"$REPO_ROOT"/.claude/worktrees/*) continue ;;
      "$REPO_ROOT"/.codex/worktrees|"$REPO_ROOT"/.codex/worktrees/*) continue ;;
      "$REPO_ROOT"/.agents/worktrees|"$REPO_ROOT"/.agents/worktrees/*) continue ;;
      "$REPO_ROOT"/.install-build.*) continue ;;
    esac
    rel="${d#"$REPO_ROOT"/}"
    # Skip dirs the repo's .gitignore excludes (operator scratch, build dirs).
    _sa_path_gitignored "$rel" && continue
    empty_dirs+=("$d")
  done < <(find "$REPO_ROOT" -type d -empty -not -path "$REPO_ROOT/.git*" 2>/dev/null)

  if [ "${#empty_dirs[@]}" -gt 0 ]; then
    local pen=$(( ${#empty_dirs[@]} * 2 ))
    [ "$pen" -gt 8 ] && pen=8
    deduct "$key" "$pen"
    record_gap 3 2 \
      "Empty directory(s) in repo" \
      "Found ${#empty_dirs[@]} empty dir(s) (e.g. ${empty_dirs[0]#"$REPO_ROOT"/})" \
      "Remove the empty dir, or add a README explaining why it's reserved"
  fi

  # Sub-check 3.2: Anti-pattern dir names — same .gitignore-respecting scope.
  # find emits filesystem enumeration order, so pipe through LC_ALL=C sort:
  # when several dirs match the same anti-pattern name, the per-dir gaps must
  # RECORD in byte order — the cross-twin collation convention (the PS twin
  # ordinal-sorts the same enumeration; ordinal == C byte order for the ASCII
  # names this repo uses), keeping .gaps identical across machines and twins.
  local antipatterns="tmp misc notes scratch junk"
  local ap d
  for ap in $antipatterns; do
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$d" in
        "$REPO_ROOT"/.git/*) continue ;;
        "$REPO_ROOT"/node_modules/*) continue ;;
        "$REPO_ROOT"/tests/fixtures/*) continue ;;
      esac
      rel="${d#"$REPO_ROOT"/}"
      _sa_path_gitignored "$rel" && continue
      deduct "$key" 4
      record_gap 3 5 \
        "Anti-pattern directory name" \
        "$d uses a name (\"$ap\") that signals undisciplined accretion" \
        "Rename to something meaningful (e.g. \"runtime/\", \"sandbox/\") or remove if dead"
    done < <(find "$REPO_ROOT" -type d -name "$ap" 2>/dev/null | LC_ALL=C sort)
  done

  # Sub-check 3.3: lifecycle: superseded artifacts cite their successor.
  if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    local supers=0 sunset_no_why=0 rel f lc
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      case "$rel" in
        docs/plans/*.md|docs/specs/*.md|docs/*/plans/*.md|docs/*/specs/*.md|\
        capabilities/*.md|harnesses/*/capabilities/*.md) ;;
        *) continue ;;
      esac
      f="$REPO_ROOT/$rel"
      [ -f "$f" ] || continue
      lc="$(fm_get "$f" lifecycle)"
      if [ "$lc" = "superseded" ]; then
        if ! grep -qE '\[\[[^]]+\]\]|\]\([^)]+\.md\)' "$f"; then
          supers=$((supers+1))
        fi
      elif [ "$lc" = "sunset" ]; then
        local body_words
        body_words="$(awk 'NR==1{if($0!="---")exit; next} /^---[[:space:]]*$/{flag=1; next} flag' "$f" \
                       | tr -s ' \t\n' ' ' | wc -w | tr -d ' ')"
        if [ -n "$body_words" ] && [ "$body_words" -lt 20 ]; then
          sunset_no_why=$((sunset_no_why+1))
        fi
      fi
    done < <(git -C "$REPO_ROOT" ls-files)

    if [ "$supers" -gt 0 ]; then
      local pen=$(( supers * 2 ))
      [ "$pen" -gt 6 ] && pen=6
      deduct "$key" "$pen"
      record_gap 3 3 \
        "Superseded artifact missing successor link" \
        "$supers superseded file(s) have no [[wiki-link]] or markdown-link successor reference in body" \
        "Add a 'Superseded by: [[name]]' or markdown link to each affected file's body"
    fi
    if [ "$sunset_no_why" -gt 0 ]; then
      local pen=$(( sunset_no_why * 2 ))
      [ "$pen" -gt 4 ] && pen=4
      deduct "$key" "$pen"
      record_gap 3 3 \
        "Sunset artifact without explanation" \
        "$sunset_no_why sunset file(s) have <20 words of body explaining why" \
        "Add a brief 'Why sunset' note (~2-3 sentences) per affected file"
    fi
  fi

  # Sub-check 3.4: a sync-hosted vault must never contain a live `.git`. The
  # durable vault lives on a sync service (Google Drive / iCloud / Dropbox —
  # OBSIDIAN_VAULT_PATH) that races file writes; a live `.git` there corrupts the
  # object store (and Drive sprays .DS_Store into tracked dirs). Vault history, if
  # wanted, belongs in a clone OUTSIDE the synced tree. Gated on VAULT_DIR being
  # set, so a machine with no configured vault (e.g. CI) is unaffected. `-e`
  # catches both a `.git` dir (real repo) and a `.git` gitlink file (worktree /
  # submodule). See obsidian/vault-guide.md. Mirrors self-audit.ps1.
  if [ -n "$VAULT_DIR" ] && [ -e "$VAULT_DIR/.git" ]; then
    deduct "$key" 6
    record_gap 3 8 \
      "Live .git inside the sync-hosted vault" \
      "$VAULT_DIR/.git exists — a sync service races writes to the git object store (corruption footgun) and sprays .DS_Store into tracked dirs" \
      "Remove the in-vault .git; if you want vault history, keep a clone OUTSIDE the synced path (see obsidian/vault-guide.md)"
  fi

  local s; s="$(pillar_score "$key")"
  if [ "$s" -eq 20 ]; then
    pillar_set_note "$key" "clean"
  else
    pillar_set_note "$key" "$((20 - s)) pts deducted; see top gaps"
  fi
}

# --- Pillar 4: Verification coverage -----------------------------------------
score_verification_coverage() {
  local key="verification-coverage"

  # Sub-check 4.1: For each capability declaring verification: <gate> (not
  # "none"), verify the recipe file exists. validate.sh hard-fails on this so
  # it's normally redundant — but a partial worktree state could surface it
  # here before validate.sh runs.
  local broken_refs=0 cap v
  for cap in "$REPO_ROOT"/capabilities/*.md; do
    [ -f "$cap" ] || continue
    [ "$(basename "$cap" .md)" = "README" ] && continue
    v="$(fm_get "$cap" verification)"
    if [ -z "$v" ] || [ "$v" = "none" ]; then
      continue
    fi
    if [ ! -f "$REPO_ROOT/verification/$v.md" ]; then
      broken_refs=$((broken_refs+1))
    fi
  done
  if [ "$broken_refs" -gt 0 ]; then
    local pen=$(( broken_refs * 4 ))
    [ "$pen" -gt 12 ] && pen=12
    deduct "$key" "$pen"
    record_gap 4 8 \
      "Capability references a missing verification recipe" \
      "$broken_refs capability/(ies) declare verification: pointing at a non-existent verification/*.md" \
      "Either add the missing recipe or change the capability's verification: value to 'none' or an existing recipe"
  fi

  # Sub-check 4.2: For each verification/*.md (excl README), at least one routing
  # surface must reference it. Orphans are dead weight.
  #
  # <TEAM>-180 D3: a recipe is "referenced" if its name appears as a whole token in
  # ANY routing surface — a capability's `verification:` frontmatter, the
  # session-agent R3 gate list, a playbook, or a core routing doc — not only as a
  # `verification:` frontmatter field. The prior frontmatter-only grep
  # false-flagged the recipes routed BY NAME from capabilities/session-agent.md R3
  # + playbooks/core (~78% false positives: 8 of 10 recipes flagged when only a
  # genuinely-dangling recipe should). The token boundary ([^A-Za-z0-9-]) stops a
  # basename matching inside a longer word (recipe "data" must not match
  # "database"). The recipe's own verification/<base>.md is out of scope — we scan
  # routing dirs only — so a recipe that is named NOWHERE outside verification/
  # still flags (the check keeps its teeth).
  # NOTE: this is a HEURISTIC by-name check (Codex <TEAM>-180 review). A whole-token
  # occurrence anywhere in the routing dirs counts as a reference, so a recipe
  # named only in incidental prose would not flag. That is the accepted trade-off:
  # a stricter shape (requiring `verification:` frontmatter or backticked names)
  # would re-flag the recipes routed as BARE names in harnesses/*/SKILLS.template.md
  # and core/routing.md — i.e. re-introduce the ~78% false positives this fix
  # removes. The D3-teeth test pins that a recipe named NOWHERE still flags.
  local orphan_recipes=0 recipe base refs base_re k ch
  for recipe in "$REPO_ROOT"/verification/*.md; do
    [ -f "$recipe" ] || continue
    base="$(basename "$recipe" .md)"
    [ "$base" = "README" ] && continue
    # Escape ERE metacharacters in the basename so a future recipe name with a
    # '.' (or other metachar) behaves identically to the PS twin's
    # [regex]::Escape (Codex <TEAM>-180 review: parity). Kebab-case names pass
    # through unchanged.
    base_re=""; k=0
    while [ "$k" -lt "${#base}" ]; do
      ch="${base:$k:1}"
      case "$ch" in
        [A-Za-z0-9_-]) base_re="$base_re$ch" ;;
        *)             base_re="$base_re\\$ch" ;;
      esac
      k=$((k+1))
    done
    # Capture matching filenames, not grep's EXIT CODE: grep returns non-zero
    # when one of the scanned dirs is absent (a fixture may have no playbooks/ or
    # core/), which would otherwise mis-flag every recipe as orphan. `|| true`
    # plus the `-n` test sidesteps both that and the script's `set -o pipefail`.
    refs="$(grep -rEl "(^|[^A-Za-z0-9-])${base_re}([^A-Za-z0-9-]|$)" \
              "$REPO_ROOT/capabilities" "$REPO_ROOT/playbooks" \
              "$REPO_ROOT/core" "$REPO_ROOT/harnesses" 2>/dev/null || true)"
    [ -n "$refs" ] && continue
    orphan_recipes=$((orphan_recipes+1))
  done
  if [ "$orphan_recipes" -gt 0 ]; then
    local pen=$(( orphan_recipes * 4 ))
    [ "$pen" -gt 8 ] && pen=8
    deduct "$key" "$pen"
    record_gap 4 3 \
      "Orphan verification recipe(s)" \
      "$orphan_recipes recipe(s) in verification/ have no capability declaring them as a gate" \
      "Either wire a capability's verification: to the recipe, or delete the orphan recipe"
  fi

  # Sub-check 4.3: install.sh manifest freshness via check-drift.sh.
  if [ -n "$CONFIG_DIR" ] && [ -f "$CONFIG_DIR/.build-manifest.json" ] && command -v jq >/dev/null 2>&1; then
    if [ -x "$REPO_ROOT/scripts/check-drift.sh" ]; then
      if ! bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$CONFIG_DIR" >/dev/null 2>&1; then
        deduct "$key" 4
        record_gap 4 6 \
          "Build manifest drift" \
          "$CONFIG_DIR/.build-manifest.json source hashes do not match current repo source" \
          "Run: bash scripts/install.sh --harness claude --harness codex (and trust hooks in codex)"
      fi
    fi
  fi

  local s; s="$(pillar_score "$key")"
  if [ "$s" -eq 20 ]; then
    pillar_set_note "$key" "clean"
  else
    pillar_set_note "$key" "$((20 - s)) pts deducted; see top gaps"
  fi
}

# --- Pillar 5: Closeout / spine discipline ------------------------------------
score_closeout_spine_discipline() {
  local key="closeout-spine-discipline"

  # Sub-check 5.1: Spine symmetry. Every kind: native capability in
  # capabilities/ must have a matching realization under EACH harness it declares
  # in its `harnesses:` frontmatter list. Deriving the harness set from
  # frontmatter — instead of a hardcoded claude+codex pair — keeps the check
  # honest as harnesses become first-class: a missing
  # harnesses/<h>/capabilities/<name>.md (e.g. a dropped hermes realization)
  # now deducts exactly like a missing Claude/Codex one, so a thinned-out
  # realization can no longer pass BOTH `make verify` AND /self-audit unnoticed.
  # Enumerate capabilities in LC_ALL=C byte order, not glob order: glob
  # expansion collates by the ambient locale, so the downstream gap RECORDING
  # order (harness-union first-seen order + each gap's missing_for list) could
  # differ across machines/locales and from the PS twin. C collation is the
  # cross-twin convention (the PS twin ordinal-sorts the same enumeration;
  # ordinal == C byte order for the ASCII names this repo uses).
  local native_caps=() native_hlists=() cap kind name
  while IFS= read -r cap; do
    [ -f "$cap" ] || continue
    [ "$(basename "$cap" .md)" = "README" ] && continue
    kind="$(fm_get "$cap" kind)"
    [ "$kind" = "native" ] || continue
    native_caps+=("$(basename "$cap" .md)")
    # `harnesses: [claude, codex, hermes]` -> space-separated `claude codex hermes`.
    # Lowercased so a capitalized frontmatter value (e.g. `[Claude]`) resolves to
    # the lowercase harnesses/<h>/ dir on case-sensitive filesystems — parity with
    # bootstrap's harness-name fold + the PS twin's .ToLower().
    native_hlists+=("$(fm_get "$cap" harnesses | tr -d '[]' | tr ',' ' ' | tr '[:upper:]' '[:lower:]')")
  done < <(find "$REPO_ROOT/capabilities" -maxdepth 1 -name '*.md' 2>/dev/null | LC_ALL=C sort)

  # Union of declared harnesses, first-seen order. bash 3.2 has no associative
  # arrays, so track membership in a space-padded string.
  local all_harnesses="" h i
  for i in "${!native_caps[@]}"; do
    for h in ${native_hlists[$i]}; do
      case " $all_harnesses " in *" $h "*) ;; *) all_harnesses="$all_harnesses $h" ;; esac
    done
  done

  # Per harness: native caps that DECLARE it but lack the realization file.
  for h in $all_harnesses; do
    # Collect missing names in an ARRAY (not a space-joined string): a name with
    # a space/glob would otherwise be miscounted by `wc -w` (and glob-expand under
    # word-splitting). `${#arr[@]}` is the exact count, matching the PS twin's
    # .Count so per-pillar score parity holds. (An empty array is safe under
    # bash 3.2 set -u here: `${#arr[@]}` and `+=` never trip the empty-array
    # value-expansion error; `${arr[*]}` below is reached only when non-empty.)
    local missing_for=() cnt pen hname
    for i in "${!native_caps[@]}"; do
      case " ${native_hlists[$i]} " in *" $h "*) ;; *) continue ;; esac
      name="${native_caps[$i]}"
      [ -f "$REPO_ROOT/harnesses/$h/capabilities/$name.md" ] || missing_for+=("$name")
    done
    [ "${#missing_for[@]}" -gt 0 ] || continue
    cnt="${#missing_for[@]}"
    pen=$(( cnt * 8 ))
    [ "$pen" -gt 16 ] && pen=16
    deduct "$key" "$pen"
    # Title-case the harness for the gap title (Claude/Codex/Hermes), matching
    # the prior message style.
    hname="$(printf '%s' "$h" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
    record_gap 5 10 \
      "Spine asymmetry: missing $hname realization(s)" \
      "Native capability(s) without harnesses/$h/capabilities/<name>.md: ${missing_for[*]}" \
      "Author the $hname realization file(s) and re-run: bash scripts/install.sh --harness $h"
  done

  # Sub-check 5.2: Recent project memory entries should carry a State Deltas
  # section. <TEAM>-366: scans ALL stores (multi-root find); the gap's example
  # path attributes the store the first offender lives in.
  if [ "${#MEMORY_DIRS[@]}" -gt 0 ]; then
    local missing_sd=0 missing_sd_example="" f m
    # Epoch-based 7-day cutoff (integer seconds), NOT `find -mtime -7`: GNU find
    # truncates the age to whole days while BSD/macOS find rounds it UP, so the
    # same flag spans a 6- vs 7-day window across platforms — and neither matches
    # the PS twin's exact-instant compare. Computing `now - 7*86400` and comparing
    # each file's mtime epoch makes bash and PS agree to the second. Portable
    # mtime: GNU `stat -c %Y` else BSD `stat -f %m`.
    local _now_epoch _cutoff_epoch
    _now_epoch=$(date +%s)
    _cutoff_epoch=$(( _now_epoch - 7 * 86400 ))
    while IFS= read -r -d '' f; do
      [ -f "$f" ] || continue
      [ "$(basename "$f")" = "MEMORY.md" ] && continue
      # Project-type detection by frontmatter, not a project_*.md glob (<TEAM>-353).
      [ "$(mem_note_type "$f")" = "project" ] || continue
      m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
      [ -n "$m" ] || continue
      [ "$m" -ge "$_cutoff_epoch" ] || continue
      if ! grep -qE '^## State Deltas' "$f"; then
        missing_sd=$((missing_sd+1))
        [ -z "$missing_sd_example" ] && missing_sd_example="$f"
      fi
    done < <(find "${MEMORY_DIRS[@]}" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)
    if [ "$missing_sd" -gt 0 ]; then
      local pen=$(( missing_sd * 4 ))
      [ "$pen" -gt 8 ] && pen=8
      deduct "$key" "$pen"
      record_gap 5 4 \
        "Recent project memory lacks ## State Deltas" \
        "$missing_sd project memory file(s) modified in the last 7 days have no '## State Deltas' section (e.g. $missing_sd_example)" \
        "Add the section per capabilities/closeout.md output shape, even if the contents are '_none_'"
    fi
  fi

  local s; s="$(pillar_score "$key")"
  if [ "$s" -eq 20 ]; then
    pillar_set_note "$key" "clean"
  else
    pillar_set_note "$key" "$((20 - s)) pts deducted; see top gaps"
  fi
}

# --- run all five pillars -----------------------------------------------------
score_cross_layer_handoffs
score_memory_hygiene
score_folder_hygiene
score_verification_coverage
score_closeout_spine_discipline

# --- aggregate ---------------------------------------------------------------
TOTAL=0
UNSCORED_COUNT=0
for i in 0 1 2 3 4; do
  TOTAL=$(( TOTAL + ${PILLAR_SCORES[$i]} ))
  [ "${PILLAR_UNSCORED[$i]}" -eq 1 ] && UNSCORED_COUNT=$(( UNSCORED_COUNT + 1 ))
done

DATE="$(date -u +%Y-%m-%d)"

# --- output -------------------------------------------------------------------
emit_markdown() {
  printf '# /self-audit scorecard — %s\n\n' "$DATE"
  printf '**Total: %s/100**\n\n' "$TOTAL"
  if [ "$UNSCORED_COUNT" -gt 0 ]; then
    printf '> **%s of 5 pillars UNSCORED** — surface not configured (Linear/memory/vault); a check that cannot run scores 0, never a free 20. Do not read this total as health until the surface is wired, then re-audit.\n\n' "$UNSCORED_COUNT"
  fi
  printf '| Pillar | Score | Notes |\n'
  printf '| --- | --- | --- |\n'
  local i
  for i in 0 1 2 3 4; do
    if [ "${PILLAR_UNSCORED[$i]}" -eq 1 ]; then
      printf '| %s | UNSCORED | %s |\n' "${PILLAR_LABELS[$i]}" "${PILLAR_NOTES[$i]}"
    else
      printf '| %s | %s/20 | %s |\n' "${PILLAR_LABELS[$i]}" "${PILLAR_SCORES[$i]}" "${PILLAR_NOTES[$i]}"
    fi
  done

  printf '\n## Injection surface\n\n'
  if [ "$INJ_MEASURED" -eq 0 ]; then
    printf '_(not measured — no injection-surface component resolved)_\n'
  else
    local j
    for j in "${!INJ_COMP_NAMES[@]}"; do
      printf -- '- %s: %s bytes (%s)\n' \
        "${INJ_COMP_NAMES[$j]}" "${INJ_COMP_BYTES[$j]}" "${INJ_COMP_PATHS[$j]}"
    done
    if [ "${#INJ_SKIPPED[@]}" -gt 0 ]; then
      local sk_list="" sk
      for sk in "${INJ_SKIPPED[@]}"; do
        [ -n "$sk_list" ] && sk_list="$sk_list, "
        sk_list="$sk_list$sk"
      done
      printf -- '- skipped: %s\n' "$sk_list"
    fi
    local verdict="OK"
    [ "$INJ_WARNED" -eq 1 ] && verdict="OVER"
    printf 'Total: %s bytes — soft threshold %s KB (%s)\n' \
      "$INJ_TOTAL_BYTES" "$INJECTION_WARN_KB" "$verdict"
  fi
  # <TEAM>-468: codex registry size, informational only — outside the surface
  # total, never scored, never a gap (see sub-check 2.5).
  if [ "$CODEX_REGISTRY_BYTES" -ge 0 ]; then
    printf -- '- codex memory registry (informational, not scored): %s bytes (%s)\n' \
      "$CODEX_REGISTRY_BYTES" "$CODEX_REGISTRY_PATH"
  fi

  printf '\n## Top gaps (leverage-weighted)\n\n'
  if [ "${#GAPS[@]}" -eq 0 ]; then
    printf '_(none)_\n'
  else
    local sorted
    sorted="$(sorted_gaps | head -3)"
    local n=1 pillar lev title detail fix
    while IFS=$'\t' read -r pillar lev title detail fix; do
      [ -n "$pillar" ] || continue
      printf '%s. [Pillar %s] %s (leverage %s)\n' "$n" "$pillar" "$title" "$lev"
      printf '   - Detail: %s\n' "$detail"
      printf '   - Fix: %s\n' "$fix"
      n=$((n+1))
    done <<< "$sorted"
  fi

  printf '\n## Skipped surfaces\n\n'
  if [ "${#SKIPPED[@]}" -eq 0 ]; then
    printf '_(none — all surfaces configured)_\n'
  else
    local s
    for s in "${SKIPPED[@]}"; do
      # `--` terminates printf option parsing — without it, bash interprets the
      # leading `-` in the format as an option flag and errors out.
      printf -- '- %s\n' "$s"
    done
  fi
}

emit_json() {
  command -v jq >/dev/null 2>&1 || { printf '{"error":"jq required for --json"}\n'; return 1; }

  local pillars_obj='{}' i unscored_bool
  for i in 0 1 2 3 4; do
    unscored_bool=false
    [ "${PILLAR_UNSCORED[$i]}" -eq 1 ] && unscored_bool=true
    pillars_obj="$(printf '%s' "$pillars_obj" | jq \
      --arg key   "${PILLAR_KEYS[$i]}" \
      --arg label "${PILLAR_LABELS[$i]}" \
      --argjson score "${PILLAR_SCORES[$i]}" \
      --argjson unscored "$unscored_bool" \
      --arg note  "${PILLAR_NOTES[$i]}" \
      '.[$key] = {label: $label, score: $score, unscored: $unscored, notes: $note}')"
  done

  local gaps_arr='[]' g pillar lev title detail fix sorted
  if [ "${#GAPS[@]}" -gt 0 ]; then
    sorted="$(sorted_gaps)"
    while IFS=$'\t' read -r pillar lev title detail fix; do
      [ -n "$pillar" ] || continue
      gaps_arr="$(printf '%s' "$gaps_arr" | jq \
        --argjson pillar "$pillar" --argjson lev "$lev" \
        --arg title "$title" --arg detail "$detail" --arg fix "$fix" \
        '. += [{pillar: $pillar, leverage: $lev, title: $title, detail: $detail, fix: $fix}]')"
    done <<< "$sorted"
  fi

  local skipped_arr='[]' s
  if [ "${#SKIPPED[@]}" -gt 0 ]; then
    for s in "${SKIPPED[@]}"; do
      skipped_arr="$(printf '%s' "$skipped_arr" | jq --arg s "$s" '. += [$s]')"
    done
  fi

  # injection_surface (<TEAM>-364): null when nothing resolved (not-measured is
  # a distinct state from a 0-byte surface), else a fixed-key-order object so
  # the twins emit identical shapes.
  local inj_json='null'
  if [ "$INJ_MEASURED" -eq 1 ]; then
    local inj_comps='[]' inj_j
    for inj_j in "${!INJ_COMP_NAMES[@]}"; do
      inj_comps="$(printf '%s' "$inj_comps" | jq \
        --arg name "${INJ_COMP_NAMES[$inj_j]}" \
        --arg path "${INJ_COMP_PATHS[$inj_j]}" \
        --argjson bytes "${INJ_COMP_BYTES[$inj_j]}" \
        '. += [{name: $name, path: $path, bytes: $bytes}]')"
    done
    local inj_skipped='[]' inj_s
    if [ "${#INJ_SKIPPED[@]}" -gt 0 ]; then
      for inj_s in "${INJ_SKIPPED[@]}"; do
        inj_skipped="$(printf '%s' "$inj_skipped" | jq --arg s "$inj_s" '. += [$s]')"
      done
    fi
    local inj_warned=false
    [ "$INJ_WARNED" -eq 1 ] && inj_warned=true
    inj_json="$(jq -n \
      --argjson total "$INJ_TOTAL_BYTES" \
      --argjson tk "$INJECTION_WARN_KB" \
      --argjson warned "$inj_warned" \
      --argjson components "$inj_comps" \
      --argjson skipped "$inj_skipped" \
      '{total_bytes: $total, threshold_kb: $tk, warned: $warned, components: $components, skipped: $skipped}')"
  fi

  # codex_registry_bytes (<TEAM>-468): ADDITIVE optional field — the codex-native
  # registry's index size, reported informationally (never scored, never a gap).
  # null when no registry resolved or it holds no MEMORY.md. APPENDED LAST so
  # every pre-existing field keeps its name, shape, AND position (panel finding:
  # inserting mid-object shifted gaps/skipped for positional consumers).
  local cx_json='null'
  [ "$CODEX_REGISTRY_BYTES" -ge 0 ] && cx_json="$CODEX_REGISTRY_BYTES"

  jq -n \
    --arg date "$DATE" \
    --argjson total "$TOTAL" \
    --argjson unscored_count "$UNSCORED_COUNT" \
    --argjson pillars "$pillars_obj" \
    --argjson injection_surface "$inj_json" \
    --argjson gaps "$gaps_arr" \
    --argjson skipped "$skipped_arr" \
    --argjson codex_registry_bytes "$cx_json" \
    '{date: $date, total: $total, unscored_count: $unscored_count, pillars: $pillars, injection_surface: $injection_surface, gaps: $gaps, skipped: $skipped, codex_registry_bytes: $codex_registry_bytes}'
}

OUTPUT=""
if [ "$FORMAT" = "json" ]; then
  OUTPUT="$(emit_json)"
else
  OUTPUT="$(emit_markdown)"
fi

printf '%s\n' "$OUTPUT"

if [ -n "$SAVE_PATH" ]; then
  case "$SAVE_PATH" in
    /*) save_full="$SAVE_PATH" ;;
    *)  save_full="$REPO_ROOT/$SAVE_PATH" ;;
  esac
  mkdir -p "$(dirname "$save_full")"
  printf '%s\n' "$OUTPUT" > "$save_full"
  printf '\nSaved scorecard to %s\n' "$save_full" >&2
fi

exit 0
