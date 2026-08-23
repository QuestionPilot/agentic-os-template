#!/usr/bin/env bash
# vault-search.sh — the vault's deterministic full-text retrieval baseline.
#
# WHY THIS EXISTS. Broad questions ("what do we know about X?") need a surface
# that is honest about what the vault actually contains. The obvious answer is
# to build an index — a knowledge graph, an embedding store, a cached summary —
# but an index is a SECOND COPY of the corpus, and a second copy drifts from the
# first. A stale semantic surface answers a question confidently with month-old
# evidence and gives no signal that anything is missing; that false clean is
# worse than no answer at all.
#
# This deliberately is not another index. It reads the notes themselves, so it
# is current by construction: no build step, no cache, no cutoff date, nothing
# to refresh. Over a vault of a few hundred notes a full scan costs tens of
# milliseconds, which is cheaper than the freshness check an index would need.
# At this corpus size, "just read it" beats "index it" on every axis that
# matters here.
#
# WHAT IT IS NOT. This is lexical search — it finds the words you type. It does
# not find a note that discusses the same idea in different words. Where a
# concept could be phrased several ways, search each phrasing, or start from the
# curated indexes (90-Indexes/, 04-Lessons/_index, 03-Decisions/_index) which
# are maintained precisely so concepts have one canonical entry point. Saying
# this plainly is the point: a retrieval surface that oversells its recall is
# how a stale index does damage.
#
# Usage:
#   bin/vault-search.sh <query> [options]
#
#   --scope durable|archive|all   where to look (default: durable)
#                                 durable = the layers that hold decided
#                                   knowledge: 00-System, 01-Projects,
#                                   02-Areas, 03-Decisions, 04-Lessons,
#                                   10-Wiki, 90-Indexes, plus START/README
#                                 archive = 30-Archive (session logs: what was
#                                   DONE, not what is TRUE — see the note below)
#                                 all     = durable + archive + the remaining
#                                   layers (20-Raw evidence, 40-Observability,
#                                   50-Outputs, 80-Templates, 95-Views)
#   --max N                       max notes to report (default: 12)
#   --lines N                     max matching lines per note (default: 3)
#   --context N                   lines of context around each match (default: 0)
#   --regex                       treat the query as a regex (default: literal text)
#   --case-sensitive              match case exactly (default: case-insensitive)
#   --paths-only                  print just the note paths, one per line
#
# CASE HANDLING. Matching is case-INSENSITIVE by default, deliberately not
# ripgrep's `--smart-case`. Smart-case flips to case-sensitive as soon as the
# query contains a capital, so searching `Fresh Start` can return nothing while
# `fresh start` returns the note — and a session that types a proper noun the
# natural way gets a confident, silent zero. A retrieval surface whose recall
# depends on the caller's shift key is exactly the false clean this baseline
# exists to remove. Pass --case-sensitive when case is genuinely the signal (an
# env var, a constant, a class name).
#
# Exit codes:
#   0  matches found and printed
#   1  no matches (a real, reportable answer — not an error)
#   2  usage error, or the vault root could not be resolved (fail loud: a
#      silent empty result is indistinguishable from a genuinely empty search,
#      which is the failure mode this whole surface exists to prevent)
#
# Determinism: LC_ALL=C is pinned for every sort and every byte-oriented text
# tool. Under a UTF-8 locale, BSD tools switch bracket expressions to character
# semantics and silently change what matches. Same tree + same query in, same
# bytes out.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# WINDOWS PATH SHAPE. Under Git Bash / MSYS, `pwd` reports the POSIX-mapped form
# (/g/My Drive/Vault) while ripgrep — a native Win32 binary — echoes the paths it
# was handed back in native form (G:/My Drive/Vault) with BACKSLASH separators
# inside. The two never string-match, so every "strip the vault root" below
# silently no-ops and the script emits ABSOLUTE paths where its contract promises
# vault-relative ones. That failure is invisible on macOS/Linux, where the two
# forms coincide, and it is not loud on Windows either: callers just get a path
# that never equals the relative one they compare against — it made
# bin/retrieval-evals.sh fail every positive fixture while all of them were in
# fact retrieving the correct note first. Capture the native form too, and
# normalize separators — but ONLY when a native form exists, so a POSIX filename
# that legitimately contains a backslash is left alone.
VAULT_ROOT_NATIVE=""
if VAULT_ROOT_NATIVE="$(cd "$SCRIPT_DIR/.." && pwd -W 2>/dev/null)"; then
  [ "$VAULT_ROOT_NATIVE" = "$VAULT_ROOT" ] && VAULT_ROOT_NATIVE=""
else
  VAULT_ROOT_NATIVE=""
fi
# `pwd -W` is not contractually slash-shaped; normalize the ROOT once so the
# prefix strip in vault_relpath cannot silently no-op against the already
# slash-normalized path (panel finding).
VAULT_ROOT_NATIVE="${VAULT_ROOT_NATIVE//\\//}"

# Normalize one path to the vault-relative, forward-slash form this script's
# stdout contract promises. Both root spellings are tried because which one
# ripgrep echoes depends on how the search dirs were spelled going in.
vault_relpath() {
  _vr_p="$1"
  [ -n "$VAULT_ROOT_NATIVE" ] && _vr_p="${_vr_p//\\//}"
  _vr_p="${_vr_p#"$VAULT_ROOT"/}"
  [ -n "$VAULT_ROOT_NATIVE" ] && _vr_p="${_vr_p#"$VAULT_ROOT_NATIVE"/}"
  printf '%s\n' "$_vr_p"
}

DURABLE_DIRS=(00-System 01-Projects 02-Areas 03-Decisions 04-Lessons 10-Wiki 90-Indexes)
ARCHIVE_DIRS=(30-Archive)
EXTRA_DIRS=(20-Raw 40-Observability 50-Outputs 80-Templates 95-Views)
ROOT_NOTES=(START.md README.md)

SCOPE=durable
MAX_NOTES=12
MAX_LINES=3
CONTEXT=0
REGEX=0
CASE_SENSITIVE=0
PATHS_ONLY=0
QUERY=""

die() { printf '%s\n' "vault-search: $*" >&2; exit 2; }

usage() { sed -nE 's|^# ?||p' "$0" | awk '/^Usage:/,/^Determinism:/'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --scope)   [ $# -ge 2 ] || die "--scope needs a value"; SCOPE="$2"; shift 2 ;;
    --max)     [ $# -ge 2 ] || die "--max needs a value"; MAX_NOTES="$2"; shift 2 ;;
    --lines)   [ $# -ge 2 ] || die "--lines needs a value"; MAX_LINES="$2"; shift 2 ;;
    --context) [ $# -ge 2 ] || die "--context needs a value"; CONTEXT="$2"; shift 2 ;;
    --regex)   REGEX=1; shift ;;
    --case-sensitive) CASE_SENSITIVE=1; shift ;;
    --paths-only) PATHS_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --*)       die "unknown flag: $1" ;;
    *)         [ -n "$QUERY" ] && die "more than one query given; quote it"; QUERY="$1"; shift ;;
  esac
done

[ -n "$QUERY" ] || { usage; exit 2; }
case "$SCOPE" in durable|archive|all) ;; *) die "--scope must be durable, archive, or all" ;; esac
for n in "$MAX_NOTES" "$MAX_LINES" "$CONTEXT"; do
  case "$n" in ''|*[!0-9]*) die "--max/--lines/--context take a non-negative integer" ;; esac
done
command -v rg >/dev/null 2>&1 || die "ripgrep (rg) not found on PATH"
[ -d "$VAULT_ROOT/00-System" ] || die "vault root does not look like a vault: $VAULT_ROOT"

# Assemble the search set. Missing directories are skipped silently — a vault
# legitimately may not have every optional layer — but an empty set is fatal,
# because scanning nothing would otherwise print a convincing "no matches".
TARGETS=()
case "$SCOPE" in
  durable) DIRS=("${DURABLE_DIRS[@]}") ;;
  archive) DIRS=("${ARCHIVE_DIRS[@]}") ;;
  all)     DIRS=("${DURABLE_DIRS[@]}" "${ARCHIVE_DIRS[@]}" "${EXTRA_DIRS[@]}") ;;
esac
for d in "${DIRS[@]}"; do
  [ -d "$VAULT_ROOT/$d" ] && TARGETS+=("$VAULT_ROOT/$d")
done
if [ "$SCOPE" != "archive" ]; then
  for f in "${ROOT_NOTES[@]}"; do
    [ -f "$VAULT_ROOT/$f" ] && TARGETS+=("$VAULT_ROOT/$f")
  done
fi
[ "${#TARGETS[@]}" -gt 0 ] || die "no searchable paths under $VAULT_ROOT for scope '$SCOPE'"

RG_BASE=(--no-messages --color never
         --glob '*.md' --glob '!*.bak' --glob '!.obsidian/**'
         # The fixture note quotes every retrieval-fixture query verbatim, so
         # leaving it in scope makes it match its own negative controls — and,
         # worse, makes what a CALLER sees differ from what the eval runner
         # measures. It is instrument scaffolding, not vault knowledge, so it
         # is excluded here rather than filtered downstream: the test surface
         # and the caller surface must be the same surface.
         #
         # The `**/` prefix is load-bearing, not decoration. A ripgrep glob that
         # contains a slash anchors to the CURRENT DIRECTORY, not to the paths
         # being searched — so a bare `!00-System/…` silently stops excluding
         # anything the moment the caller runs from outside the vault root, and
         # the fixture note reappears in every result. That failure is invisible
         # from inside the vault directory and only shows up when a test or a
         # session invokes the script by absolute path.
         --glob '!**/00-System/Retrieval Fixtures.md')
[ "$CASE_SENSITIVE" -eq 1 ] && RG_BASE+=(--case-sensitive) || RG_BASE+=(--ignore-case)
# Literal by default. This is an agent-facing natural-language surface, and a
# question like "what is the promotion test?" or "the [staging] path" carries
# regex metacharacters that silently widen or narrow the match with no error.
# Regex is available, but it must be asked for.
[ "$REGEX" -eq 1 ] || RG_BASE+=(--fixed-strings)

# TWO PASSES, deliberately. Ranking is computed from a context-FREE pass, because
# ripgrep's context records use `-` separators (`path-lineno-text`) and `--` group
# separators, which the `path:lineno:text` parse below turns into phantom
# filenames. With --context 2 that inflates a small result into hundreds of
# "matched notes" and invents a note literally named `--`. Counting and display
# are therefore separate concerns and separate invocations.
COUNT_RAW="$(rg "${RG_BASE[@]}" --count-matches --with-filename -- "$QUERY" "${TARGETS[@]}" 2>/dev/null)"
RG_STATUS=$?
# rg exits 1 for "no matches" and 2 for a real error. Only 0 and 1 are
# acceptable outcomes; anything else must be loud, never an empty report.
if [ "$RG_STATUS" -gt 1 ]; then
  die "ripgrep failed (exit $RG_STATUS) — reporting no result would be a false clean"
fi
# In --paths-only mode stdout is a machine surface (one path per line), so the
# human-readable no-match notice goes to stderr there — a caller consuming
# stdout must never mistake prose for a path. The exit code carries the result.
if [ -z "$COUNT_RAW" ]; then
  if [ "$PATHS_ONLY" -eq 1 ]; then
    echo "no matches for: $QUERY (scope: $SCOPE)" >&2
  else
    echo "no matches for: $QUERY (scope: $SCOPE)"
  fi
  exit 1
fi

# --count-matches emits `path:N`; the count is the field after the LAST colon, so
# a colon inside a filename cannot corrupt it (`cut -d: -f1` could and did).
RANKED="$(printf '%s\n' "$COUNT_RAW" \
          | sed -E 's/^(.*):([0-9]+)$/\2\t\1/' \
          | sort -k1,1nr -k2,2 \
          | awk -v n="$MAX_NOTES" 'NR<=n')"
TOTAL_NOTES="$(printf '%s\n' "$COUNT_RAW" | grep -c . | tr -d ' ')"

# The display pass carries context only if the caller asked for it.
RG_DISPLAY=("${RG_BASE[@]}" --no-heading --with-filename --line-number)
[ "$CONTEXT" -gt 0 ] && RG_DISPLAY+=(--context "$CONTEXT")
RAW="$(rg "${RG_DISPLAY[@]}" -- "$QUERY" "${TARGETS[@]}" 2>/dev/null)"

if [ "$PATHS_ONLY" -eq 1 ]; then
  printf '%s\n' "$RANKED" | cut -f2- | while IFS= read -r _p; do
    [ -n "$_p" ] && vault_relpath "$_p"
  done
  exit 0
fi

printf 'query: %s   scope: %s   notes matched: %s (showing up to %s)\n\n' \
  "$QUERY" "$SCOPE" "$TOTAL_NOTES" "$MAX_NOTES"

printf '%s\n' "$RANKED" | while IFS=$'\t' read -r hits file; do
  [ -n "$file" ] || continue
  relpath="$(vault_relpath "$file")"
  title="$(sed -nE 's/^title:[[:space:]]*//p' "$file" 2>/dev/null | head -1 | tr -d '"')"
  # Fall back on the NORMALIZED relative path, not the raw one: POSIX basename
  # splits only on `/`, so a backslash-shaped native path would yield the whole
  # path as the "title" for a note without frontmatter (panel finding).
  [ -n "$title" ] || title="$(basename "$relpath" .md)"
  printf '%s  (%s hit(s))\n    %s\n' "$relpath" "$hits" "$title"
  # Match records are `path:lineno:text`; context records (only present when
  # --context > 0) are `path-lineno-text`. Both must pass the filter, or the
  # context the caller asked for is silently dropped — accepting only the colon
  # form did exactly that. The per-note line cap scales with the context window
  # so context does not evict the matches it belongs to.
  note_cap="$MAX_LINES"
  [ "$CONTEXT" -gt 0 ] && note_cap=$((MAX_LINES * (1 + 2 * CONTEXT)))
  # NEVER pass a filesystem path through `awk -v`. POSIX requires -v assignments
  # to undergo escape processing, so every backslash in the value is interpreted:
  # a Windows path like `03-Decisions\2026-....md` has its `\202` read as an
  # OCTAL escape and it silently becomes a single byte. The filter then matches
  # nothing and every excerpt line vanishes from the output — with no error, on
  # a code path that looks obviously correct. ENVIRON is not escape-processed,
  # so the path arrives intact. Same trap for any POSIX filename that
  # legitimately contains a backslash.
  printf '%s\n' "$RAW" \
    | VS_FILE="$file" awk 'BEGIN { fc = ENVIRON["VS_FILE"] ":"; fd = ENVIRON["VS_FILE"] "-" }
                           index($0, fc) == 1 || index($0, fd) == 1' \
    | head -n "$note_cap" | while IFS= read -r line; do
    rest="${line#"$file"}"
    sep="${rest%"${rest#?}"}"; rest="${rest#?}"
    lineno="${rest%%[!0-9]*}"
    text="${rest#"$lineno"}"; text="${text#?}"
    # Trim leading whitespace and clamp the excerpt so one long line cannot
    # blow the output budget. Context lines are marked `|` to keep them
    # visually distinct from the `:` match lines.
    text="$(printf '%s' "$text" | sed -E 's/^[[:space:]]+//' | cut -c1-160)"
    if [ "$sep" = ":" ]; then
      printf '    L%s: %s\n' "$lineno" "$text"
    else
      printf '    L%s| %s\n' "$lineno" "$text"
    fi
  done
  printf '\n'
done

exit 0
