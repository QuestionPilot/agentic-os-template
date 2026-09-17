#!/usr/bin/env bash
# scripts/operator-skill-parity-check.sh — CONTENT parity for the operator's own
# (unmanaged) skills across the framework's render homes.
#
# Why this exists: the build manifest tracks only the framework-managed spine
# skills, so scripts/check-drift.sh never looks at a skill the operator copied
# into several render homes by hand — and a presence check (the dir exists in
# every home) cannot see CONTENT. The gap is real and silent: an operator edits
# one home's copy of a skill, the other homes keep serving the stale body, and
# every existing gate stays green because nothing in the tree is being compared.
# This script closes it by diffing the content of every UNMANAGED skill in a
# canonical render home against each mirror render home.
#
# Contract: compare every unmanaged skill dir under the canonical skills root
# against the same-named dir in each configured mirror skills root. Hermes is
# different: its expected operator-skill subset comes from the Capability Map's
# machine-readable `Skill` / `Where` rows, so a skill the map intentionally
# omits is not treated as missing. A declared variant is compared to its named
# source pair, never merely excused by an allowlist.
# Capability Map tables need only `Skill` and `Where` columns. Rows may include
# or omit their final `|`, with standard or alignment-marked separator rows.
# Header and `Where` tokens are case-insensitive, while skill names keep their
# literal case. Individual diagnostic-line order is not contractual; labels,
# exit status, and reported comparison counts are.
#
# Output tokens (shared semantics with the PowerShell twin; whole-output byte
# order is not contractual):
#   SKIP    a configured mirror root is not present on this machine
#   MISSING a canonical skill has no counterpart in a mirror root
#   DRIFT   contents differ and the pair is NOT allowlisted
#   VARIANT contents differ and the pair IS allowlisted (deliberate)
#   PASS    nothing unexplained drifted, with an explicit denominator
#   FAIL    real drift, a missing canonical root, or nothing compared at all
#
# Configuration (env var first, then local.env read as DATA — never sourced):
#   SKILL_PARITY_CANONICAL  canonical skills root.
#                           Default: <CLAUDE_CONFIG_DIR>/skills.
#   SKILL_PARITY_MIRRORS    comma-separated mirror skills roots. Each entry is
#                           either `<label>=<path>` or a bare `<path>` (the label
#                           is then the parent dir name, minus a leading dot).
#                           Default: the configured codex / agents / cursor /
#                           hermes render homes, each + `/skills`; unset homes
#                           are simply not in the default list. Hermes uses the
#                           Capability Map subset and declared variant pairs.
#   SKILL_PARITY_ALLOWLIST  comma-separated `<label>/<skill>` entries for
#                           deliberate per-harness variants. Default: empty.
#                           Verify each entry by reading the diff, and re-verify
#                           when a listed skill is rewritten.
#   SKILL_PARITY_CAPABILITY_MAP
#                           Capability Map Markdown path. Default:
#                           <OBSIDIAN_VAULT_PATH>/90-Indexes/Capability Map.md.
#                           Required whenever a Hermes mirror is configured.
#   SKILL_PARITY_VARIANTS   comma-separated explicit
#                           `<target-label>/<skill>=<source-label>/<skill>`
#                           pairs. Targets are case-sensitive and unique. A
#                           variant must match its declared, distinct source.
#
# Managed (spine) skills are EXCLUDED automatically: they are per-harness
# renders, never copies, so comparing them would always report drift. The
# excluded set is derived from the canonical render's `.build-manifest.json`
# (every `skills/<name>/` the manifest generates), not hardcoded. With no
# manifest (or no jq) the script prints a NOTE and compares everything.
#
# Exit 0 = every mirror in sync or explained. Exit 1 = real drift, a missing
# canonical root, or a run that compared nothing.
set -uo pipefail
# Byte-oriented text tools only: sort/diff semantics must not shift with the
# caller's locale.
LC_ALL=C
export LC_ALL

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
localenv="${AI_CONFIG_LOCAL_ENV:-$repo_root/local.env}"

# jqr — jq -r with CRLF normalization. A Windows-built jq emits \r\n; a trailing
# \r embedded in a manifest-derived skill name silently fails every downstream
# string comparison. Values never legitimately contain \r here.
jqr() { jq -r "$@" | tr -d '\r'; }

# _sp_localenv_get <path> <key> — read one KEY=VALUE from local.env as DATA
# (never sourced; a hostile or malformed local.env cannot execute). Same parser
# as check-drift.sh::_cd_localenv_get: strips an optional `export `, one matching
# outer quote pair, backslash escapes; last assignment wins. No $VAR expansion.
_sp_localenv_get() {
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

# _sp_cfg <key> — env var first, then local.env.
_sp_cfg() {
  local key="$1" v
  v="${!key:-}"
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  _sp_localenv_get "$localenv" "$key"
}

# _sp_trim <string> — strip leading/trailing whitespace.
_sp_trim() {
  local t="$1"
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  printf '%s' "$t"
}

# Parallel arrays, NEVER a space-separated string: a render home path routinely
# contains a space, and a string split on IFS silently turns two roots into four
# bogus ones that all "skip" — the check then prints PASS having compared
# nothing. Fail loud, never open.
MIRROR_LABELS=()
MIRROR_PATHS=()

# _sp_add_mirrors <csv> — append `<label>=<path>` / bare-`<path>` entries.
# Comma is the only separator, so a path containing a comma cannot be expressed
# here (documented limitation; such a path lands as two unresolvable roots and
# is reported as a loud SKIP, never a silent pass).
_sp_add_mirrors() {
  local rest="$1" item label path
  while [ -n "$rest" ]; do
    case "$rest" in
      *,*) item="${rest%%,*}"; rest="${rest#*,}" ;;
      *)   item="$rest"; rest="" ;;
    esac
    item="$(_sp_trim "$item")"
    [ -n "$item" ] || continue
    case "$item" in
      *=*) label="${item%%=*}"; path="${item#*=}" ;;
      *)   path="$item"; label="$(basename "$(dirname "$item")")"; label="${label#.}" ;;
    esac
    MIRROR_LABELS+=("$(_sp_trim "$label")")
    MIRROR_PATHS+=("$(_sp_trim "$path")")
  done
}

# _sp_hermes_expected <map> — emit every map skill whose Where column includes
# `hermes` or `all`. This reuses the Capability Map schema that its own checker
# consumes; no second Hermes roster lives here.
_sp_hermes_expected() {
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*\|/ {
      row = $0
      sub(/^[[:space:]]*\|[[:space:]]*/, "", row)
      sub(/[[:space:]]*\|[[:space:]]*$/, "", row)
      n = split(row, c, "|")
      if (n < 2) { mode = 0; next }
      first = trim(c[1]); last = trim(c[n])
      if (tolower(first) == "skill" && tolower(last) == "where") { mode = 1; next }
      if (first ~ /^:?-+:?$/) next
      if (!mode) next
      if (match(first, /^`[^`]+`$/)) {
        name = substr(first, 2, length(first) - 2)
        split(last, where, ",")
        for (i in where) {
          token = tolower(trim(where[i]))
          if (token == "all" || token == "hermes") { print name; break }
        }
      }
      next
    }
    { mode = 0 }
  ' "$1" | LC_ALL=C sort -u
}

# --- canonical root --------------------------------------------------------
canonical="$(_sp_cfg SKILL_PARITY_CANONICAL)"
if [ -z "$canonical" ]; then
  claude_home="$(_sp_cfg CLAUDE_CONFIG_DIR)"
  [ -n "$claude_home" ] && canonical="$claude_home/skills"
fi
if [ -z "$canonical" ]; then
  printf 'FAIL no canonical skill root: set SKILL_PARITY_CANONICAL (or CLAUDE_CONFIG_DIR) in local.env\n' >&2
  exit 1
fi
if [ ! -d "$canonical" ]; then
  printf 'FAIL canonical skill root missing: %s\n' "$canonical" >&2
  exit 1
fi

# --- mirror roots ----------------------------------------------------------
mirrors_cfg="$(_sp_cfg SKILL_PARITY_MIRRORS)"
if [ -n "$mirrors_cfg" ]; then
  _sp_add_mirrors "$mirrors_cfg"
else
  # Default: the configured render homes other than Claude (the canonical),
  # including Hermes. Hermes's expected subset comes from the Capability Map.
  for sp_pair in "codex:CODEX_HOME" "agents:AGENTS_DIR" "cursor:CURSOR_CONFIG_DIR" "hermes:HERMES_HOME"; do
    sp_label="${sp_pair%%:*}"; sp_var="${sp_pair#*:}"
    sp_dir="$(_sp_cfg "$sp_var")"
    [ -n "$sp_dir" ] || continue
    MIRROR_LABELS+=("$sp_label")
    MIRROR_PATHS+=("$sp_dir/skills")
  done
fi
if [ "${#MIRROR_LABELS[@]}" -eq 0 ]; then
  printf 'FAIL no mirror skill root configured — the check would compare nothing\n' >&2
  exit 1
fi

# --- Hermes map-backed subset ----------------------------------------------
HERMES_EXPECTED=()
hermes_map=""
for sp_label in "${MIRROR_LABELS[@]}"; do
  [ "$sp_label" = "hermes" ] || continue
  hermes_map="$(_sp_cfg SKILL_PARITY_CAPABILITY_MAP)"
  if [ -z "$hermes_map" ]; then
    vault_dir="$(_sp_cfg OBSIDIAN_VAULT_PATH)"
    [ -n "$vault_dir" ] && hermes_map="$vault_dir/90-Indexes/Capability Map.md"
  fi
  if [ -z "$hermes_map" ] || [ ! -f "$hermes_map" ]; then
    printf 'FAIL Hermes Capability Map missing: set SKILL_PARITY_CAPABILITY_MAP (or OBSIDIAN_VAULT_PATH)\n' >&2
    exit 1
  fi
  while IFS= read -r sp_skill; do
    [ -n "$sp_skill" ] && HERMES_EXPECTED+=("$sp_skill")
  done < <(_sp_hermes_expected "$hermes_map")
  if [ "${#HERMES_EXPECTED[@]}" -eq 0 ]; then
    printf 'FAIL Hermes Capability Map has no expected skills: %s\n' "$hermes_map" >&2
    exit 1
  fi
  printf 'NOTE   Hermes expected subset: %d skill(s) from %s\n' "${#HERMES_EXPECTED[@]}" "$hermes_map"
  break
done

# --- allowlist -------------------------------------------------------------
# Normalized to a space-delimited string for the substring membership test.
# Entries are `<label>/<skill>`; neither component contains a space.
ALLOWLIST=""
allow_cfg="$(_sp_cfg SKILL_PARITY_ALLOWLIST)"
allow_rest="$allow_cfg"
while [ -n "$allow_rest" ]; do
  case "$allow_rest" in
    *,*) allow_item="${allow_rest%%,*}"; allow_rest="${allow_rest#*,}" ;;
    *)   allow_item="$allow_rest"; allow_rest="" ;;
  esac
  allow_item="$(_sp_trim "$allow_item")"
  [ -n "$allow_item" ] || continue
  ALLOWLIST="$ALLOWLIST $allow_item"
done

# --- explicit variant pairs -------------------------------------------------
# Parallel arrays retain the literal pair for output and source resolution.
VARIANT_TARGETS=()
VARIANT_SOURCES=()
variant_cfg="$(_sp_cfg SKILL_PARITY_VARIANTS)"
variant_rest="$variant_cfg"
while [ -n "$variant_rest" ]; do
  case "$variant_rest" in
    *,*) variant_item="${variant_rest%%,*}"; variant_rest="${variant_rest#*,}" ;;
    *)   variant_item="$variant_rest"; variant_rest="" ;;
  esac
  variant_item="$(_sp_trim "$variant_item")"
  [ -n "$variant_item" ] || continue
  case "$variant_item" in
    *=*) variant_target="$(_sp_trim "${variant_item%%=*}")"; variant_source="$(_sp_trim "${variant_item#*=}")" ;;
    *) printf 'FAIL invalid SKILL_PARITY_VARIANTS entry: %s\n' "$variant_item" >&2; exit 1 ;;
  esac
  if ! [[ "$variant_target" =~ ^[^/]+/[^/]+$ ]]; then
    printf 'FAIL invalid variant target: %s\n' "$variant_target" >&2
    exit 1
  fi
  if ! [[ "$variant_source" =~ ^[^/]+/[^/]+$ ]]; then
    printf 'FAIL invalid variant source: %s\n' "$variant_source" >&2
    exit 1
  fi
  if [ "$variant_target" = "$variant_source" ]; then
    printf 'FAIL variant source matches target: %s\n' "$variant_target" >&2
    exit 1
  fi
  variant_i=0
  while [ "$variant_i" -lt "${#VARIANT_TARGETS[@]}" ]; do
    if [ "${VARIANT_TARGETS[$variant_i]}" = "$variant_target" ]; then
      printf 'FAIL duplicate variant target: %s\n' "$variant_target" >&2
      exit 1
    fi
    variant_i=$((variant_i + 1))
  done
  VARIANT_TARGETS+=("$variant_target")
  VARIANT_SOURCES+=("$variant_source")
done

_sp_variant_source_dir() {
  local source="$1" source_label source_skill idx
  source_label="${source%%/*}"
  source_skill="${source#*/}"
  if [ "$source_label" = "canonical" ]; then
    printf '%s' "$canonical/$source_skill"
    return 0
  fi
  idx=0
  while [ "$idx" -lt "${#MIRROR_LABELS[@]}" ]; do
    if [ "${MIRROR_LABELS[$idx]}" = "$source_label" ]; then
      printf '%s' "${MIRROR_PATHS[$idx]}/$source_skill"
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

# _sp_physical_dir <path> — resolve a directory through symlinks before a
# variant comparison. `cd -P` works on the Bash versions supported by macOS.
_sp_physical_dir() {
  (cd -P "$1" 2>/dev/null && pwd -P)
}

# --- managed (spine) skills, derived from the canonical render's manifest ----
MANAGED=""
manifest="$(dirname "$canonical")/.build-manifest.json"
if [ ! -f "$manifest" ]; then
  printf 'NOTE   no build manifest at %s — comparing every skill dir\n' "$manifest"
elif ! command -v jq >/dev/null 2>&1; then
  printf 'NOTE   jq unavailable — cannot read the build manifest; comparing every skill dir\n'
else
  MANAGED="$(jqr '.generated | keys[] | select(startswith("skills/")) | split("/")[1]' \
    "$manifest" 2>/dev/null | sort -u | tr '\n' ' ')"
fi

# --- compare ---------------------------------------------------------------
rc=0
checked=0
roots_compared=0
i=0
while [ "$i" -lt "${#MIRROR_LABELS[@]}" ]; do
  label="${MIRROR_LABELS[$i]}"
  root="${MIRROR_PATHS[$i]}"
  i=$((i + 1))
  if [ ! -d "$root" ]; then
    printf 'SKIP   %-8s root not present (%s)\n' "$label" "$root"
    if [ "$label" = "hermes" ]; then
      printf 'FAIL Hermes skill root missing: %s\n' "$root" >&2
      rc=1
    fi
    continue
  fi
  roots_compared=$((roots_compared + 1))
  # Bash 3.2 with nounset treats an empty array expansion as unbound. Seed the
  # list, then skip the sentinel, so an empty canonical root reaches the normal
  # `no unmanaged skills` result instead of aborting before it.
  if [ "$label" = "hermes" ]; then
    compare_skills=("${HERMES_EXPECTED[@]}")
  else
    compare_skills=("")
    for d in "$canonical"/*/; do
      [ -d "$d" ] || continue
      compare_skills+=("$(basename "$d")")
    done
  fi
  for skill in "${compare_skills[@]}"; do
    [ -n "$skill" ] || continue
    case " $MANAGED " in *" $skill "*) continue ;; esac
    checked=$((checked + 1))
    d="$canonical/$skill"
    if [ ! -d "$d" ]; then
      printf 'MISSING canonical %s\n' "$skill"
      rc=1
      continue
    fi
    if [ ! -d "$root/$skill" ]; then
      printf 'MISSING %-8s %s\n' "$label" "$skill"
      rc=1
      continue
    fi
    variant_source=""
    variant_i=0
    while [ "$variant_i" -lt "${#VARIANT_TARGETS[@]}" ]; do
      if [ "${VARIANT_TARGETS[$variant_i]}" = "$label/$skill" ]; then
        variant_source="${VARIANT_SOURCES[$variant_i]}"
        break
      fi
      variant_i=$((variant_i + 1))
    done
    if [ -n "$variant_source" ]; then
      variant_dir="$(_sp_variant_source_dir "$variant_source")" || variant_dir=""
      if [ -z "$variant_dir" ] || [ ! -d "$variant_dir" ]; then
        printf 'FAIL variant source missing: %s\n' "$variant_source" >&2
        rc=1
        continue
      fi
      variant_physical="$(_sp_physical_dir "$variant_dir")" || variant_physical=""
      target_physical="$(_sp_physical_dir "$root/$skill")" || target_physical=""
      if [ -z "$variant_physical" ] || [ -z "$target_physical" ] || \
          [ "$variant_physical" = "$target_physical" ]; then
        printf 'FAIL variant source aliases target: %s = %s\n' "$label/$skill" "$variant_source" >&2
        rc=1
        continue
      fi
      if diff -r -q --exclude='.DS_Store' --exclude='__pycache__' \
          "$variant_dir" "$root/$skill" >/dev/null 2>&1; then
        printf 'VARIANT %-8s %s (matched %s)\n' "$label" "$skill" "$variant_source"
      else
        printf 'DRIFT   %-8s %s (expected %s)\n' "$label" "$skill" "$variant_source"
        rc=1
      fi
      continue
    fi
    if diff -r -q --exclude='.DS_Store' --exclude='__pycache__' \
        "$d" "$root/$skill" >/dev/null 2>&1; then
      continue
    fi
    case " $ALLOWLIST " in
      *" $label/$skill "*) printf 'VARIANT %-8s %s (allowlisted)\n' "$label" "$skill" ;;
      *) printf 'DRIFT   %-8s %s\n' "$label" "$skill"; rc=1 ;;
    esac
  done
done

if [ "$roots_compared" -eq 0 ]; then
  printf 'FAIL no mirror root was present — the check compared nothing\n' >&2
  exit 1
fi
if [ "$checked" -eq 0 ]; then
  printf 'SKIP   no unmanaged skills to compare\n'
  exit "$rc"
fi

if [ "$rc" -eq 0 ]; then
  printf 'PASS operator-skill parity: %d comparison(s) across %d of %d mirror root(s), no unexplained drift\n' \
    "$checked" "$roots_compared" "${#MIRROR_LABELS[@]}"
else
  printf 'FAIL operator-skill parity drift — sync from %s deliberately, or allowlist a real variant\n' "$canonical" >&2
fi
exit "$rc"
