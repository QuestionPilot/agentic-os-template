#!/usr/bin/env bash
# check-project-note-budget.sh — per-note BODY budget gate for `type: project`
# memory notes. Fails CLOSED: a project-type note whose file size exceeds the
# budget blocks the closeout that would otherwise append yet another State Delta
# to it.
#
# WHY THIS EXISTS. A project-type note is the body a kickoff orient
# dereferences, every session. The self-audit already MEASURES the same budget
# (its memory-hygiene sub-check 2.6) — but that is a 2-point advisory warn an
# operator reads after the fact, and the note that keeps growing is precisely
# the one closeout writes to. Measuring at audit time and never at write time is
# how a store grows a 30 KB arc note nobody trimmed: the growth happens in
# closeout, the warning arrives somewhere else. This check runs INSIDE the
# closeout pre-write gate, so the session that would add to an already-oversize
# note is the session told to trim it.
#
# WHAT COUNTS AS A PROJECT NOTE — the frontmatter `type:`, not a filename glob.
# Scoped to the first `---`-fenced block, lowercased, one surrounding quote pair
# stripped, matched case-SENSITIVELY. WHICH `type:` wins is load-bearing: a
# frontmatter block can carry several `type:` keys under different parents
# (`source:` provenance blocks are the common case), so "the first `type:` at any
# indent" reads the WRONG one — a note whose `source:` names `type: project`
# above its real `metadata: type: reference` was classified project. The rules:
#   0. the block must CLOSE (a second `---`); an unclosed opening fence is not
#      frontmatter at all, so a body line `type: project` classifies nothing;
#   1. a `type:` nested as a DIRECT child of the top-level `metadata:` key wins
#      — direct meaning at the first indentation level seen inside that block,
#      so `metadata: source: type: …` belongs to `source:`, not to the note;
#   2. else a TOP-LEVEL `type:` (column 0);
#   3. a `type:` nested under any OTHER key is ignored entirely.
# `node_type:` is not matched (the key is compared whole) and `Type:` does not
# classify. Byte-for-byte the same detector scripts/self-audit.sh uses (its
# `mem_note_type`), so the write-time gate and the audit can never disagree about
# which notes are in scope. `MEMORY.md` is the index, never a note, and is always
# excluded.
#
# WHAT IS MEASURED. The file's byte size, against `<cap> * 1024`. The cap is the
# same knob the self-audit reads, resolved by the same precedence:
#
#   1. --warn-kb <n>                        (explicit caller intent)
#   2. PROJECT_NOTE_BODY_WARN_KB in repo-root local.env, read as DATA — never
#      sourced, so a hostile or malformed local.env cannot execute
#      ($AI_CONFIG_LOCAL_ENV overrides the file path, the fixture convention
#      shared with check-drift.sh / closeout-gate.sh)
#   3. $PROJECT_NOTE_BODY_WARN_KB in the ambient environment
#   4. 16
#
# A cap value that is not a positive integer, or is longer than 7 digits, falls
# back to the default SILENTLY — mirroring self-audit.sh. The digit bound is
# load-bearing, not cosmetic: `$(( KB * 1024 ))` is 64-bit signed arithmetic, so
# a value like 18014398509481984 wraps the product to 0 and every note on disk
# lands "over budget" — a knob typed to RAISE the threshold silently driving it
# to zero.
#
# SURFACE CONTRACT, matching scripts/closeout-gate.sh's:
#   - No --memory-dir given at all  -> named SKIP, exit 0. There is no
#     project-note surface to scan; that is a real, benign configuration (a
#     fresh public clone), not a broken gate.
#   - --memory-dir given but the directory does not exist, or exists and cannot
#     be enumerated (no read or no search bit) -> FAIL. A configured store that
#     is not there, or cannot be opened, is a misspelled / unsynced / permission-
#     broken path, and scanning nothing while reporting clean is the fail-open
#     case this closes. A NOTE that cannot be read fails the same way, checked
#     before the type filter: an unreadable file classifies as "no type" and
#     would otherwise drop out of the scan indistinguishable from a reference
#     note, when it may be the oversize project note this check exists to catch.
#
# `MEMORY.md` matching is case-SENSITIVE on both twins; whether a file NAMED
# `memory.MD` even reaches the scan is the host filesystem's business (a
# case-insensitive volume folds it), so that half is not asserted anywhere.
#
# Usage:
#   check-project-note-budget.sh [--memory-dir <dir>]... [--warn-kb <n>]
#   check-project-note-budget.sh --help
#
# --memory-dir is repeatable: an operator with several project stores gets one
# verdict over all of them, with each finding attributed to its own path.
#
# Exit codes:
#   0 — every scanned project-type note is within budget (a skip does not fail)
#   1 — at least one note is over budget, or a given memory dir or note could
#       not be read
#   2 — usage error (bad args)
#
# Tests: tests/project-note-budget.test.sh (+ the .ps1 twin), and the
# project-note-budget check in tests/closeout-gate.test.sh.

set -uo pipefail

# Byte-oriented, locale-independent scanning: the frontmatter awk, the size
# comparison and the enumeration order must not shift under a UTF-8 caller.
export LC_ALL=C

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -nE 's|^# ?||p' "$0" | awk '/^check-project-note-budget\.sh/,/^Tests:/'
}

# _pnb_localenv_get <path> <key> — read one KEY=VALUE from local.env as DATA
# (never sourced). Same parser as scripts/self-audit.sh::_sa_localenv_get and
# scripts/closeout-gate.sh::_cg_localenv_get: strips an optional `export `, one
# matching outer quote pair, backslash escapes; last assignment wins. No $VAR
# expansion.
_pnb_localenv_get() {
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

# _pnb_note_type <file> — the note's memory type from frontmatter. Identical to
# scripts/self-audit.sh::mem_note_type; see this file's header for the
# metadata-first nesting rule and why it is load-bearing.
_pnb_note_type() {
  awk '
    # type_value <line> — the value half of a `type:` line: the key stripped,
    # trailing whitespace gone, an inline YAML comment removed, one surrounding
    # quote pair unwrapped, lowercased.
    #
    # QUOTED values are unwrapped by finding the CLOSING quote rather than by
    # comparing the last character: `type: "project" # active arc` has a comment
    # after the pair (so a last-character compare sees `c`, not `"`, and gives
    # back the whole line), and a `#` INSIDE the quotes is literal, not a comment.
    # Finding the close quote settles both. UNQUOTED values instead lose
    # everything from a `#` that follows whitespace, per the YAML comment rule;
    # `a#b` with no space keeps its hash.
    function type_value(line,   v, q, i) {
      v = line
      sub(/^[[:space:]]*type:[[:space:]]*/, "", v)
      sub(/[[:space:]]*$/, "", v)
      q = substr(v, 1, 1)
      if (q == "\"" || q == "\047") {
        i = index(substr(v, 2), q)
        if (i > 0) return tolower(substr(v, 2, i - 1))
        # No closing quote — not a quoted scalar; fall through to the bare rules.
      }
      sub(/[[:space:]]+#.*$/, "", v)
      sub(/[[:space:]]*$/, "", v)
      return tolower(v)
    }
    # indent_of <line> — width of the leading whitespace run, in characters (a
    # tab counts as one). Only ever called on a line already known to start with
    # whitespace followed by a key.
    function indent_of(line,   w) {
      w = line
      sub(/[^[:space:]].*$/, "", w)
      return length(w)
    }
    NR==1 {
      if (substr($0,1,3) == "\357\273\277") $0 = substr($0,4)   # strip UTF-8 BOM
      if ($0 !~ /^---[[:space:]]*$/) exit
    }
    /^---[[:space:]]*$/ { saw_sep++; if (saw_sep==2) { closed=1; exit } next }
    saw_sep==1 {
      # A column-0 `<key>:` opens a top-level block. `type:` at column 0 IS the
      # top-level type; any other key becomes the block an indented `type:`
      # would belong to.
      if ($0 ~ /^[A-Za-z0-9_.-]+:/) {
        key = $0; sub(/:.*$/, "", key)
        if (key == "type") { if (top == "") top = type_value($0); cur = "" }
        else { cur = key; if (key == "metadata") meta_indent = -1 }
        next
      }
      # An INDENTED `type:` counts only as a DIRECT child of `metadata:` — the
      # first indentation level seen inside that block. A deeper `type:` belongs
      # to a sub-key (`metadata: source: type: …`) and is somebody else'"'"'s field.
      if (cur == "metadata" && $0 ~ /^[[:space:]]+[A-Za-z0-9_.-]+:/) {
        w = indent_of($0)
        if (meta_indent < 0) meta_indent = w
        if (w == meta_indent && $0 ~ /^[[:space:]]+type:[[:space:]]*/) {
          if (meta == "") meta = type_value($0)
        }
      }
    }
    # An UNCLOSED block is not frontmatter at all: without a second fence the
    # whole file is body, and a body line `type: project` must not classify the
    # note. Only a closed block yields a type.
    END { if (closed) { v = (meta != "") ? meta : top; if (v != "") print v } }
  ' "$1"
}

WARN_KB=""
MEM_DIRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --memory-dir)
      [ $# -ge 2 ] || { printf 'FAIL --memory-dir requires a value\n' >&2; exit 2; }
      # An EXPLICIT empty value is a usage error, never a fallback. Silently
      # dropping it would turn `--memory-dir "$SOME_UNSET_VAR"` into the named
      # SKIP — a caller that believed it pinned a store gets a clean run over
      # nothing, which is precisely the fail-open shape this check exists to close.
      [ -n "$2" ] || { printf 'FAIL --memory-dir requires a non-empty value\n' >&2; exit 2; }
      MEM_DIRS+=("$2"); shift 2 ;;
    --warn-kb)
      [ $# -ge 2 ] || { printf 'FAIL --warn-kb requires a value\n' >&2; exit 2; }
      WARN_KB="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'FAIL unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Cap precedence: flag > local.env (as DATA) > ambient env > default.
if [ -z "$WARN_KB" ]; then
  WARN_KB="$(_pnb_localenv_get "${AI_CONFIG_LOCAL_ENV:-$SELF_DIR/../local.env}" PROJECT_NOTE_BODY_WARN_KB)"
fi
if [ -z "$WARN_KB" ]; then
  WARN_KB="${PROJECT_NOTE_BODY_WARN_KB:-}"
fi
# An unusable knob degrades to the default silently (see the header).
case "$WARN_KB" in
  ''|*[!0-9]*) WARN_KB=16 ;;
  *)
    if [ "${#WARN_KB}" -gt 7 ]; then
      WARN_KB=16
    else
      # BASE-10 NORMALIZATION, before any arithmetic touches the value. A
      # leading zero makes bash read the digits as OCTAL: `08` is an arithmetic
      # ERROR that aborts the run before the denominator ever prints, and
      # `0000016` silently means 14 — while the PS twin's [int] parse reads both
      # as decimal, so the two shells disagreed on the same input. `10#` pins the
      # base, and the NORMALIZED value is what every message below echoes.
      WARN_KB=$(( 10#$WARN_KB ))
      [ "$WARN_KB" -gt 0 ] || WARN_KB=16
    fi
    ;;
esac
CAP_BYTES=$(( WARN_KB * 1024 ))

# No surface at all is an inapplicable check, not a silent pass: say so, with
# the denominator, so a zero-scan run can never be mistaken for a clean one.
if [ "${#MEM_DIRS[@]}" -eq 0 ]; then
  printf 'SKIP no --memory-dir given — no project-note surface to scan (scanned 0 project note(s) in 0 dir(s))\n'
  exit 0
fi

over=0
bad_dirs=0
unreadable=0
scanned=0
dirs_ok=0

for d in "${MEM_DIRS[@]}"; do
  if [ ! -d "$d" ]; then
    # A CONFIGURED store that is not there fails: scanning nothing and
    # reporting clean is exactly the fail-open hole this gate closes.
    printf 'FAIL memory dir not found: %s\n' "$d"
    bad_dirs=$(( bad_dirs + 1 ))
    continue
  fi
  # A store that EXISTS but cannot be enumerated is the same hole wearing a
  # different hat: `find` on an unsearchable directory yields nothing and exits
  # quietly, so the run reported `scanned 0` and PASSed over a store it never
  # opened. Reading a directory's entries needs both the read and the search
  # bit; either missing means the scan below would be a measurement of nothing.
  if [ ! -r "$d" ] || [ ! -x "$d" ]; then
    printf 'FAIL memory dir not readable: %s\n' "$d"
    bad_dirs=$(( bad_dirs + 1 ))
    continue
  fi
  dirs_ok=$(( dirs_ok + 1 ))
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "MEMORY.md" ] && continue
    # Readability is checked BEFORE the type filter, deliberately. An unreadable
    # note classifies as "no type" and would drop out of the scan silently —
    # indistinguishable from a reference note, when it may be the oversize
    # project note this check exists to catch. We cannot know, so we fail.
    if [ ! -r "$f" ]; then
      printf 'FAIL memory note not readable: %s\n' "$f"
      unreadable=$(( unreadable + 1 ))
      continue
    fi
    [ "$(_pnb_note_type "$f")" = "project" ] || continue
    scanned=$(( scanned + 1 ))
    b="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
    [ -n "$b" ] || continue
    if [ "$b" -gt "$CAP_BYTES" ]; then
      printf 'FAIL project note over budget: %s (%s B > %s KB) — trim per capabilities/closeout.md memory-hygiene rule 4\n' \
        "$f" "$b" "$WARN_KB"
      over=$(( over + 1 ))
    fi
  done < <(find "$d" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
done

# The denominator, always — a check that reports PASS without saying how many
# notes it actually measured is indistinguishable from one that measured none.
printf 'scanned %s project note(s) in %s dir(s) against a %s KB budget\n' \
  "$scanned" "$dirs_ok" "$WARN_KB"

if [ "$over" -gt 0 ] || [ "$bad_dirs" -gt 0 ] || [ "$unreadable" -gt 0 ]; then
  printf 'FAIL %s note(s) over the %s KB budget, %s memory dir(s) unusable, %s note(s) unreadable — trim, or raise PROJECT_NOTE_BODY_WARN_KB if the size is deliberate\n' \
    "$over" "$WARN_KB" "$bad_dirs" "$unreadable"
  exit 1
fi

printf 'PASS every project-type note is within the %s KB budget\n' "$WARN_KB"
exit 0
