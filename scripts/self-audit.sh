#!/usr/bin/env bash
# scripts/self-audit.sh — score the agentic OS on five pillars (0-100 total).
#
# Usage:
#   bash scripts/self-audit.sh [--json] [--save <path>]
#                              [--repo-root <path>] [--memory-dir <path>]
#                              [--vault-dir <path>] [--config-dir <path>]
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
#   --repo-root    parent dir of this script (i.e. the ai-config checkout)
#   --memory-dir   the first matching $CLAUDE_CONFIG_DIR/projects/*/memory/
#                  if --config-dir or $CLAUDE_CONFIG_DIR resolves; else skipped
#   --vault-dir    $OBSIDIAN_VAULT_PATH if set; else skipped
#   --config-dir   $CLAUDE_CONFIG_DIR if set; else skipped
#
# `lineark` (the Linear CLI per ai-config/linear/linear-setup.md) is optional;
# Linear-side checks degrade with a "skipped: lineark not configured" note.
#
# Output: markdown by default. `--json` emits a structured object for tests:
#   {date, total, pillars{...}, gaps[], skipped[]}
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
# --isolated turns off all operator-env fallbacks (env vars + lineark detection).
# Used by tests/self-audit.test.sh so fixtures only see what the test sets up.
ISOLATED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --json)        FORMAT="json"; shift ;;
    --save)        SAVE_PATH="${2:?--save needs a path}"; shift 2 ;;
    --repo-root)   REPO_ROOT="${2:?--repo-root needs a path}"; shift 2 ;;
    --memory-dir)  MEMORY_DIR="${2:?--memory-dir needs a path}"; shift 2 ;;
    --vault-dir)   VAULT_DIR="${2:?--vault-dir needs a path}"; shift 2 ;;
    --config-dir)  CONFIG_DIR="${2:?--config-dir needs a path}"; shift 2 ;;
    --isolated)    ISOLATED=1; shift ;;
    -h|--help)     grep -E '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) printf 'self-audit.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# _sa_select_memory_dir <config-dir> → the operator's PRIMARY memory dir, chosen
# DETERMINISTICALLY (<TEAM>-180 D1). Preference order:
#   1. explicit $CLAUDE_PRIMARY_MEMORY_DIR (from local.env / env), if it is a dir
#   2. the projects/*/memory dir that has a MEMORY.md index; when more than one
#      does, the one with the most project_*.md files (the operator's active surface)
#   3. failing any MEMORY.md, the candidate with the most *.md files
#   4. last resort: alphabetically-first (the prior behaviour) so a single-project
#      setup with no MEMORY.md still resolves to something
# The old `ls -d …/projects/*/memory | head -1` took the ALPHABETICALLY-first
# match, which on a multi-project setup is a near-empty stray dir (e.g.
# …-ai-agency/memory) instead of the operator's active 100+-entry surface — so
# the whole scorecard then scored the wrong directory. Ties resolve to the first
# match in glob (alphabetical) order, so the result is stable across runs.
_sa_select_memory_dir() {
  local cfg="$1" d count best="" best_count=-1
  if [ -n "${CLAUDE_PRIMARY_MEMORY_DIR:-}" ] && [ -d "${CLAUDE_PRIMARY_MEMORY_DIR}" ]; then
    printf '%s' "$CLAUDE_PRIMARY_MEMORY_DIR"
    return 0
  fi
  for d in "$cfg"/projects/*/memory; do
    [ -d "$d" ] || continue
    [ -f "$d/MEMORY.md" ] || continue
    count="$(find "$d" -maxdepth 1 -name 'project_*.md' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$count" -gt "$best_count" ]; then best_count="$count"; best="$d"; fi
  done
  if [ -n "$best" ]; then printf '%s' "$best"; return 0; fi
  best=""; best_count=-1
  for d in "$cfg"/projects/*/memory; do
    [ -d "$d" ] || continue
    count="$(find "$d" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$count" -gt "$best_count" ]; then best_count="$count"; best="$d"; fi
  done
  if [ -n "$best" ]; then printf '%s' "$best"; return 0; fi
  # shellcheck disable=SC2012
  ls -d "$cfg"/projects/*/memory 2>/dev/null | head -1 || true
}

# _sa_localenv_get <path> <key> — read ONE key's value from local.env WITHOUT
# sourcing the file (<TEAM>-180 F1; twin parity with scripts/self-audit.ps1
# Get-SaLocalEnvValue). The prior `set -a; . local.env` EXECUTED the whole file:
# a hostile or malformed local.env could run arbitrary code, or export a PATH=
# that poisons the lineark/jq/git `command -v` lookups below — the very
# PATH-capture window the PS twin was hardened against. Reading only the 3 config
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
  # — diverging from the hardened PS twin. We now read ONLY the 3 config keys as
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
    # CLAUDE_PRIMARY_MEMORY_DIR: export the local.env pin so _sa_select_memory_dir
    # (which reads $CLAUDE_PRIMARY_MEMORY_DIR) honours it AND it wins over an
    # ambient pin — preserving flag > local.env > ambient. Only this single config
    # key is ever exported (never PATH). Mirrors the PS twin.
    _le_v="$(_sa_localenv_get "$REPO_ROOT/local.env" CLAUDE_PRIMARY_MEMORY_DIR)"
    [ -n "$_le_v" ] && export CLAUDE_PRIMARY_MEMORY_DIR="$_le_v"
    unset _le_v
  fi
  if [ -z "$CONFIG_DIR" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    CONFIG_DIR="$CLAUDE_CONFIG_DIR"
  fi
  if [ -z "$VAULT_DIR" ] && [ -n "${OBSIDIAN_VAULT_PATH:-}" ]; then
    VAULT_DIR="$OBSIDIAN_VAULT_PATH"
  fi
  if [ -z "$MEMORY_DIR" ] && [ -n "$CONFIG_DIR" ] && [ -d "$CONFIG_DIR/projects" ]; then
    MEMORY_DIR="$(_sa_select_memory_dir "$CONFIG_DIR")"
    [ -n "$MEMORY_DIR" ] && [ ! -d "$MEMORY_DIR" ] && MEMORY_DIR=""
  fi
fi

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

# --- helpers ------------------------------------------------------------------
record_gap() {
  # record_gap <pillar-num> <leverage> <title> <detail> <fix>
  local p="$1" lev="$2" title="$3" detail="$4" fix="$5"
  # ASCII tab separator — safe; titles/details/fixes never contain raw tabs.
  GAPS+=("$(printf '%s\t%s\t%s\t%s\t%s' "$p" "$lev" "$title" "$detail" "$fix")")
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
  [ -n "$MEMORY_DIR" ] && [ -d "$MEMORY_DIR" ] && memory_avail=1
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

  # Sub-check 1.1: For each active Linear project, a matching project_*.md memory file.
  # Codex B-2: pass --format json explicitly. Today's lineark v3.0.2 emits JSON
  # by default, but pinning the flag protects against a future default change
  # that would otherwise produce human prose jq can't parse (silent false-clean).
  if [ "$lineark_avail" -eq 1 ] && [ "$memory_avail" -eq 1 ] && command -v jq >/dev/null 2>&1; then
    local projects_json
    projects_json="$(lineark projects list --format json 2>/dev/null || true)"
    if [ -n "$projects_json" ]; then
      local proj_names
      proj_names="$(printf '%s' "$projects_json" | jq -r '.[] | .name' 2>/dev/null || true)"
      while IFS= read -r pname; do
        [ -n "$pname" ] || continue
        # Heuristic: look for project name in any project_*.md body. lineark
        # slug != memory filename, so body-text match is more robust than
        # filename match.
        local matched=0
        if grep -lF "$pname" "$MEMORY_DIR"/project_*.md >/dev/null 2>&1; then
          matched=1
        fi
        if [ "$matched" -eq 0 ]; then
          deduct "$key" 4
          record_gap 1 8 \
            "No memory file for active Linear project" \
            "Active project \"$pname\" has no project_*.md in $MEMORY_DIR (active projects should land a memory file at kickoff)" \
            "Create $MEMORY_DIR/project_<slug>.md with type: project frontmatter linking to the Linear URL"
        fi
      done <<< "$proj_names"
    fi
  fi

  # Sub-check 1.2: For each active Linear project, a matching vault Handshake.
  # Same `--format json` defense as 1.1 (Codex B-2).
  if [ "$lineark_avail" -eq 1 ] && [ "$vault_avail" -eq 1 ] && command -v jq >/dev/null 2>&1; then
    local projects_json
    projects_json="$(lineark projects list --format json 2>/dev/null || true)"
    if [ -n "$projects_json" ]; then
      local proj_names
      proj_names="$(printf '%s' "$projects_json" | jq -r '.[] | .name' 2>/dev/null || true)"
      while IFS= read -r pname; do
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
      done <<< "$proj_names"
    fi
  fi

  # Sub-check 1.3: Walk MEMORY.md links — every relative .md target must exist.
  # Codex N-2: original regex required `.md)` literally, missing `.md#anchor)`
  # forms. Broaden to `[^)]+\.md(#[^)]*)?` then strip the #anchor before
  # existence-checking the file.
  if [ "$memory_avail" -eq 1 ] && [ -f "$MEMORY_DIR/MEMORY.md" ]; then
    local broken=0
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      case "$target" in http://*|https://*|mailto:*|/*) continue ;; esac
      # Strip #anchor — file existence is what we check, not the anchor target.
      target="${target%%#*}"
      [ -z "$target" ] && continue
      if [ ! -f "$MEMORY_DIR/$target" ]; then
        broken=$((broken+1))
      fi
    done < <(grep -oE '\]\([^)]+\.md(#[^)]*)?\)' "$MEMORY_DIR/MEMORY.md" | sed 's/^](//; s/)$//' || true)
    if [ "$broken" -gt 0 ]; then
      local pen=$(( broken * 2 ))
      [ "$pen" -gt 8 ] && pen=8
      deduct "$key" "$pen"
      record_gap 1 4 \
        "Broken MEMORY.md link(s)" \
        "MEMORY.md references $broken file(s) that do not exist in $MEMORY_DIR" \
        "Remove the broken index lines or restore the missing memory files"
    fi
  fi

  # Finalize note.
  local s; s="$(pillar_score "$key")"
  if [ "$s" -eq 20 ]; then
    pillar_set_note "$key" "clean"
  else
    pillar_set_note "$key" "$((20 - s)) pts deducted; see top gaps"
  fi
}

# --- Pillar 2: Memory hygiene ------------------------------------------------
score_memory_hygiene() {
  local key="memory-hygiene"
  if [ -z "$MEMORY_DIR" ] || [ ! -d "$MEMORY_DIR" ]; then
    skip_surface "memory dir not resolved — memory hygiene checks skipped"
    pillar_set_note "$key" "skipped (no memory dir)"
    return 0
  fi

  # Sub-check 2.1: For each memory file (excluding MEMORY.md itself), the index
  # should reference it by name. An "orphan" is a file MEMORY.md never names.
  local orphans=0
  if [ -f "$MEMORY_DIR/MEMORY.md" ]; then
    local index_content
    index_content="$(cat "$MEMORY_DIR/MEMORY.md")"
    while IFS= read -r -d '' mf; do
      [ -f "$mf" ] || continue
      local base; base="$(basename "$mf")"
      [ "$base" = "MEMORY.md" ] && continue
      # Fixed-string match avoids regex surprises in slugs with dashes.
      case "$index_content" in
        *"$base"*) ;;
        *) orphans=$((orphans+1)) ;;
      esac
    done < <(find "$MEMORY_DIR" -maxdepth 1 -name '*.md' -print0 2>/dev/null)
  else
    # MEMORY.md missing entirely is a 20pt hit — the index is the spine of
    # memory recall.
    deduct "$key" 20
    record_gap 2 10 \
      "MEMORY.md index missing" \
      "$MEMORY_DIR/MEMORY.md does not exist; every kickoff orient runs blind" \
      "Create MEMORY.md with one line per memory file per core/memory-model.md"
    pillar_set_note "$key" "MEMORY.md missing"
    return 0
  fi

  if [ "$orphans" -gt 0 ]; then
    local pen=$(( orphans * 2 ))
    [ "$pen" -gt 10 ] && pen=10
    deduct "$key" "$pen"
    record_gap 2 3 \
      "Orphan memory file(s)" \
      "$orphans memory file(s) have no MEMORY.md index entry" \
      "Run /consolidate-memory or hand-add a one-line pointer to MEMORY.md"
  fi

  # Sub-check 2.2: MEMORY.md total size vs recall cap.
  # The router truncates memory recall around ~24400 bytes; over-cap loses
  # tail entries silently. Threshold mirrors the harness warning observed in
  # the autoloaded MEMORY.md system reminder. The 24400 constant is the
  # documented MEMORY_INDEX_SIZE_CAP_BYTES in core/memory-model.md.
  local size_bytes
  size_bytes="$(wc -c < "$MEMORY_DIR/MEMORY.md" 2>/dev/null | tr -d ' ')"
  if [ -n "$size_bytes" ] && [ "$size_bytes" -gt 24400 ]; then
    deduct "$key" 4
    record_gap 2 5 \
      "MEMORY.md over recall cap" \
      "MEMORY.md is ${size_bytes} bytes (over the ~24400 recall cap)" \
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
  long_lines="$(LC_ALL=C awk '{ s=$0; cont=gsub(/[\200-\277]/,"",s); if ((length($0)-cont) > 300) n++ } END { print n+0 }' "$MEMORY_DIR/MEMORY.md" 2>/dev/null)"
  if [ -n "$long_lines" ] && [ "$long_lines" -gt 0 ]; then
    deduct "$key" 4
    record_gap 2 5 \
      "MEMORY.md entries over line-length cap" \
      "$long_lines index line(s) exceed the ~300-char per-entry cap" \
      "Trim each to a one-line headline; move detail into the named topic file"
  fi

  local s; s="$(pillar_score "$key")"
  if [ "$s" -eq 20 ]; then
    pillar_set_note "$key" "clean"
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
    done < <(find "$REPO_ROOT" -type d -name "$ap" 2>/dev/null)
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
  # capabilities/ must have a matching realization under both
  # harnesses/{claude,codex}/capabilities/.
  local native_caps=() cap kind name
  for cap in "$REPO_ROOT"/capabilities/*.md; do
    [ -f "$cap" ] || continue
    [ "$(basename "$cap" .md)" = "README" ] && continue
    kind="$(fm_get "$cap" kind)"
    [ "$kind" = "native" ] || continue
    native_caps+=("$(basename "$cap" .md)")
  done

  local missing_claude=() missing_codex=()
  if [ "${#native_caps[@]}" -gt 0 ]; then
    for name in "${native_caps[@]}"; do
      [ -f "$REPO_ROOT/harnesses/claude/capabilities/$name.md" ] || missing_claude+=("$name")
      [ -f "$REPO_ROOT/harnesses/codex/capabilities/$name.md" ]  || missing_codex+=("$name")
    done
  fi

  if [ "${#missing_claude[@]}" -gt 0 ]; then
    local pen=$(( ${#missing_claude[@]} * 8 ))
    [ "$pen" -gt 16 ] && pen=16
    deduct "$key" "$pen"
    record_gap 5 10 \
      "Spine asymmetry: missing Claude realization(s)" \
      "Native capability(s) without harnesses/claude/capabilities/<name>.md: ${missing_claude[*]}" \
      "Author the Claude realization file(s) and re-run: bash scripts/install.sh --harness claude"
  fi
  if [ "${#missing_codex[@]}" -gt 0 ]; then
    local pen=$(( ${#missing_codex[@]} * 8 ))
    [ "$pen" -gt 16 ] && pen=16
    deduct "$key" "$pen"
    record_gap 5 10 \
      "Spine asymmetry: missing Codex realization(s)" \
      "Native capability(s) without harnesses/codex/capabilities/<name>.md: ${missing_codex[*]}" \
      "Author the Codex realization file(s) and re-run: bash scripts/install.sh --harness codex"
  fi

  # Sub-check 5.2: Recent project memory entries should carry a State Deltas
  # section.
  if [ -n "$MEMORY_DIR" ] && [ -d "$MEMORY_DIR" ]; then
    local missing_sd=0 f
    while IFS= read -r -d '' f; do
      [ -f "$f" ] || continue
      if ! grep -qE '^## State Deltas' "$f"; then
        missing_sd=$((missing_sd+1))
      fi
    done < <(find "$MEMORY_DIR" -maxdepth 1 -name 'project_*.md' -mtime -7 -print0 2>/dev/null)
    if [ "$missing_sd" -gt 0 ]; then
      local pen=$(( missing_sd * 4 ))
      [ "$pen" -gt 8 ] && pen=8
      deduct "$key" "$pen"
      record_gap 5 4 \
        "Recent project memory lacks ## State Deltas" \
        "$missing_sd project memory file(s) modified in the last 7 days have no '## State Deltas' section" \
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
for i in 0 1 2 3 4; do
  TOTAL=$(( TOTAL + ${PILLAR_SCORES[$i]} ))
done

DATE="$(date -u +%Y-%m-%d)"

# --- output -------------------------------------------------------------------
emit_markdown() {
  printf '# /self-audit scorecard — %s\n\n' "$DATE"
  printf '**Total: %s/100**\n\n' "$TOTAL"
  printf '| Pillar | Score | Notes |\n'
  printf '| --- | --- | --- |\n'
  local i
  for i in 0 1 2 3 4; do
    printf '| %s | %s/20 | %s |\n' "${PILLAR_LABELS[$i]}" "${PILLAR_SCORES[$i]}" "${PILLAR_NOTES[$i]}"
  done

  printf '\n## Top gaps (leverage-weighted)\n\n'
  if [ "${#GAPS[@]}" -eq 0 ]; then
    printf '_(none)_\n'
  else
    local sorted
    sorted="$(printf '%s\n' "${GAPS[@]}" | sort -t $'\t' -k2,2 -nr | head -3)"
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

  local pillars_obj='{}' i
  for i in 0 1 2 3 4; do
    pillars_obj="$(printf '%s' "$pillars_obj" | jq \
      --arg key   "${PILLAR_KEYS[$i]}" \
      --arg label "${PILLAR_LABELS[$i]}" \
      --argjson score "${PILLAR_SCORES[$i]}" \
      --arg note  "${PILLAR_NOTES[$i]}" \
      '.[$key] = {label: $label, score: $score, notes: $note}')"
  done

  local gaps_arr='[]' g pillar lev title detail fix sorted
  if [ "${#GAPS[@]}" -gt 0 ]; then
    sorted="$(printf '%s\n' "${GAPS[@]}" | sort -t $'\t' -k2,2 -nr)"
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

  jq -n \
    --arg date "$DATE" \
    --argjson total "$TOTAL" \
    --argjson pillars "$pillars_obj" \
    --argjson gaps "$gaps_arr" \
    --argjson skipped "$skipped_arr" \
    '{date: $date, total: $total, pillars: $pillars, gaps: $gaps, skipped: $skipped}'
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
