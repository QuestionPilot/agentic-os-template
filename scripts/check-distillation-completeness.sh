#!/usr/bin/env bash
# check-distillation-completeness.sh — pre-wipe / pre-migration guard that no
# feedback/decision memory note strands undistilled.
#
# The closeout capability promotes each `feedback_*` / `decision` memory note a
# session writes into its thematic vault `04-Lessons` note (a cache→durable
# promotion — see capabilities/closeout.md → "Distill this session's feedback
# into the durable Lessons layer"). This check is the backstop: before a machine
# wipe or a memory migration, it cross-checks every feedback/decision note in the
# harness-native store against the durable `04-Lessons` notes and FAILS if any is
# not yet distilled — i.e. raw-archived but absent from the hot Lessons layer, the
# exact strand the closeout step exists to prevent.
#
# It is deliberately NOT part of `make verify`. A mid-session store legitimately
# holds not-yet-distilled notes (this session's, distilled at this session's
# close), so a per-push gate would false-fail. Run it at the wipe / migration
# boundary the way check-clean.sh runs at the CI boundary.
#
# WHAT COUNTS AS DISTILLED. A feedback/decision note is distilled when its name
# appears anywhere in any `04-Lessons/*.md` note. The canonical home is a lesson's
# `## Source Notes` section (capabilities/closeout.md records provenance there),
# but the scan reads the whole lesson text so a name recorded in the body still
# counts — a stranding guard should not false-fail on a genuinely-distilled note
# whose provenance was written slightly differently. Names are matched with `_`
# and `-` treated as interchangeable, so the store's kebab-case auto-memory slugs
# (`feedback-foo-bar`) resolve against older snake-case Source-Notes entries
# (`feedback_foo_bar`) and vice-versa.
#
# WHICH NOTES ARE FEEDBACK/DECISION. A note in the memory dir is in scope when
# EITHER its filename stem starts with `feedback`/`decision` (kebab or snake) OR
# its frontmatter `type:` (top-level or nested under `metadata:`) is `feedback` or
# `decision`. The store uses kebab slugs with the type in frontmatter, so the
# frontmatter read is the robust signal and the filename prefix is the belt-and-
# suspenders fallback. `project_*` (state pointers — see the state-delta class)
# and `reference_*` (stable pointers) notes are intentionally out of scope.
#
# Usage:
#   check-distillation-completeness.sh --memory-dir <path> --lessons-dir <path>
#   check-distillation-completeness.sh   (derives memory-dir from CLAUDE_CONFIG_DIR
#                                         and lessons-dir from OBSIDIAN_VAULT_PATH)
#   check-distillation-completeness.sh --help
#
# Exit codes:
#   0 — every feedback/decision note is distilled (or none exist to check)
#   1 — one or more feedback/decision notes are not yet distilled
#   2 — usage error (missing dir, unresolvable path, bad args)
#
# This is a textual cross-reference check. It does not call out to Linear or the
# vault audit; it only compares note names against the Lessons corpus.

set -uo pipefail

usage() {
  sed -nE 's|^# ?||p' "$0" | awk '/^check-distillation-completeness\.sh/,/^It only compares/' | head -60
}

memory_dir=""
lessons_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --memory-dir)
      [ $# -ge 2 ] || { printf 'FAIL --memory-dir requires a value\n' >&2; exit 2; }
      memory_dir="$2"; shift 2 ;;
    --lessons-dir)
      [ $# -ge 2 ] || { printf 'FAIL --lessons-dir requires a value\n' >&2; exit 2; }
      lessons_dir="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'FAIL unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Resolve the memory dir — explicit flag, else derive from CLAUDE_CONFIG_DIR the
# same way check-memory-drift.sh does (any projects/*/memory subdir).
if [ -z "$memory_dir" ]; then
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    candidates=()
    for d in "$CLAUDE_CONFIG_DIR"/projects/*/memory; do
      [ -d "$d" ] && candidates+=("$d")
    done
    case "${#candidates[@]}" in
      0) printf 'FAIL no memory/ subdir under %s/projects/*/\n' "$CLAUDE_CONFIG_DIR" >&2; exit 2 ;;
      1) memory_dir="${candidates[0]}" ;;
      *) memory_dir="${candidates[0]}"
         printf 'NOTE multiple memory dirs found; using %s\n' "$memory_dir" >&2 ;;
    esac
  else
    printf 'FAIL no --memory-dir given and CLAUDE_CONFIG_DIR unset\n' >&2
    exit 2
  fi
fi

# Resolve the lessons dir — explicit flag, else derive from OBSIDIAN_VAULT_PATH.
if [ -z "$lessons_dir" ]; then
  if [ -n "${OBSIDIAN_VAULT_PATH:-}" ]; then
    lessons_dir="$OBSIDIAN_VAULT_PATH/04-Lessons"
  else
    printf 'FAIL no --lessons-dir given and OBSIDIAN_VAULT_PATH unset\n' >&2
    exit 2
  fi
fi

[ -d "$memory_dir" ]  || { printf 'FAIL memory dir does not exist: %s\n' "$memory_dir" >&2; exit 2; }
[ -d "$lessons_dir" ] || { printf 'FAIL lessons dir does not exist: %s\n' "$lessons_dir" >&2; exit 2; }

# Build the normalized Lessons haystack: concatenate every 04-Lessons/*.md, then
# lowercase and fold `_`→`-` so name lookups are separator-insensitive. `-exec cat
# {} +` is space-safe (find owns the paths) and needs no temp file to clean up.
lessons_text=$(find "$lessons_dir" -maxdepth 1 -type f -name '*.md' -exec cat {} + 2>/dev/null \
  | LC_ALL=C tr '[:upper:]_' '[:lower:]-')

checked=0
undistilled=0

# is_feedback_or_decision <file> — exit 0 if the note is in scope (filename prefix
# OR frontmatter type), else exit 1.
is_feedback_or_decision() {
  local f="$1" stem fm_type
  stem=$(basename "$f" .md)
  # Match the prose "stem starts with feedback/decision": the bare word
  # (`feedback.md`), or the word followed by a `-`/`_` separator
  # (`feedback-foo`). `feedbackish-*` is NOT a feedback note, so the bare
  # alternatives are exact, not prefixes.
  case "$stem" in
    feedback|decision|feedback[-_]*|decision[-_]*) return 0 ;;
  esac
  # First `type:` line inside the frontmatter (top-level or indented under
  # `metadata:`). saw_sep tracks the `---` fences; we read only the first block.
  # A leading UTF-8 BOM is stripped on line 1 so a BOM'd frontmatter-only note is
  # still recognized (mirrors check-memory-drift.sh; without it the `^---` test
  # fails and the note is silently treated as out-of-scope — a false-PASS in a
  # pre-wipe guard).
  fm_type=$(LC_ALL=C awk '
    NR==1 {
      if (substr($0,1,3) == "\357\273\277") $0 = substr($0,4)   # strip UTF-8 BOM
      if ($0 !~ /^---[[:space:]]*$/) exit
    }
    /^---[[:space:]]*$/ { saw_sep++; if (saw_sep==2) exit; next }
    saw_sep==1 && /^[[:space:]]*type:[[:space:]]*/ {
      v=$0; sub(/^[[:space:]]*type:[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v)
      print tolower(v); exit
    }
  ' "$f")
  case "$fm_type" in
    feedback|decision) return 0 ;;
  esac
  return 1
}

# Walk every note (NUL-delimited for space-safe paths; bash-3.2-safe while-read).
while IFS= read -r -d '' f; do
  base=$(basename "$f")
  [ "$base" = "MEMORY.md" ] && continue
  is_feedback_or_decision "$f" || continue

  checked=$((checked + 1))
  stem=$(basename "$f" .md)
  norm=$(printf '%s' "$stem" | LC_ALL=C tr '[:upper:]_' '[:lower:]-')

  # Match the name as a WHOLE TOKEN, not a raw substring: a slug-character on
  # either side (`[a-z0-9-]`) means we landed inside a longer name, which would
  # false-PASS a shorter note whose name prefixes a distilled longer one (e.g.
  # `feedback-cross-model-review` inside `feedback-cross-model-review-infra`). For
  # a pre-wipe guard a false-pass is the dangerous direction, so we require a
  # non-slug boundary (or line edge) on both sides. The name is regex-escaped
  # defensively — after normalization a slug is `[a-z0-9-]` only, so this is a
  # no-op in the normal case but neutralizes any stray metacharacter.
  norm_re=$(printf '%s' "$norm" | sed 's/[^a-z0-9-]/\\&/g')
  if printf '%s\n' "$lessons_text" | grep -qE "(^|[^a-z0-9-])${norm_re}([^a-z0-9-]|$)"; then
    : # found as a whole token in the Lessons corpus → distilled
  else
    printf 'FAIL undistilled: %s — not found in any 04-Lessons note; promote it (see capabilities/closeout.md → Distill this session'\''s feedback)\n' "$base" >&2
    undistilled=$((undistilled + 1))
  fi
done < <(find "$memory_dir" -maxdepth 1 -type f -name '*.md' -print0)

if [ "$undistilled" -eq 0 ]; then
  printf 'PASS all %s feedback/decision note(s) distilled into 04-Lessons (%s vs %s)\n' \
    "$checked" "$memory_dir" "$lessons_dir"
  exit 0
fi

printf 'FAIL %s of %s feedback/decision note(s) undistilled in %s\n' \
  "$undistilled" "$checked" "$memory_dir" >&2
exit 1
