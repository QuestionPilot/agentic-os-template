#!/usr/bin/env bash
# check-wikilinks.sh — pre-drain wikilink validator for the closeout session-log
# drain. Fails CLOSED: a draft whose [[wikilink]] does not resolve against the
# vault is rejected BEFORE the drain writes it, instead of surfacing on the next
# vault audit (the window <TEAM>-290's prose guard left open).
#
# WHY THIS EXISTS. The closeout drain composes a session-log body and writes it
# to `30-Archive/Sessions/`. It runs the vault audit BEFORE writing its own log,
# so the log's OWN links are not validated until the NEXT audit run — exactly how
# a bare-basename subfolder link once sat undetected until a manual audit. This
# check closes that window: it resolves the drafted body's wikilinks at write
# time, the SAME way the vault audit does, and blocks the write on any miss.
#
# RESOLUTION RULE — mirrors the vault audit's `checkWikilinks`
# (`bin/hendo-vault-audit.js`) EXACTLY. That resolver is the source of truth; it
# lives in the operator's vault, not this repo, so the harness-neutral framework
# cannot import it — this is a pinned mirror, kept honest by tests/wikilinks.test.sh.
# The rule:
#   - Build a target set of every vault `*.md`/`*.base` note's vault-relative
#     path (forward slashes) AND that path with the `.md`/`.base` extension
#     stripped. Skip the same dirs the audit's walk() skips: .git node_modules
#     .venv .claude .agents .codex.
#   - Extract each wikilink with the audit's regex `!?\[\[([^]|#]+)(?:[|#]...)?\]\]`
#     — the target is the text up to the first `|` (alias) or `#` (heading), trimmed.
#   - A target resolves iff the set contains it, OR it + ".md", OR it + ".base".
#     So a full vault-relative path (±ext) resolves, and a BARE name resolves only
#     for a vault-ROOT note — never a subdirectory note by basename. That is the
#     exact asymmetry <TEAM>-290 documented and this check enforces.
#
# Backticked memory-store names (`project_*`/`feedback_*`/`reference_*`) are NOT
# wikilinks — they carry no `[[ ]]`, so the extractor never sees them and they
# cannot false-positive. A memory-store name WRONGLY written as `[[project_x]]`
# correctly fails (it is not a vault note): the rule the drain must follow is to
# backtick those names, and this check enforces exactly that.
#
# Usage:
#   check-wikilinks.sh --draft <path> [--vault <path>]
#   check-wikilinks.sh --draft <path>           (derives vault from OBSIDIAN_VAULT_PATH)
#   check-wikilinks.sh --help
#
# Exit codes:
#   0 — every wikilink in the draft resolves (or the draft has none)
#   1 — one or more wikilinks do not resolve (FAIL CLOSED — do not write the draft)
#   2 — usage error (missing/unreadable draft, missing/unresolvable vault, bad args)
#
# The caller (the closeout drain) treats ANY non-zero exit as "do not write" —
# the same contract as the injection scan it runs alongside.

set -uo pipefail

usage() {
  sed -nE 's|^# ?||p' "$0" | awk '/^check-wikilinks\.sh/,/^The caller/' | head -60
}

draft=""
vault=""
while [ $# -gt 0 ]; do
  case "$1" in
    --draft)
      [ $# -ge 2 ] || { printf 'FAIL --draft requires a value\n' >&2; exit 2; }
      draft="$2"; shift 2 ;;
    --vault)
      [ $# -ge 2 ] || { printf 'FAIL --vault requires a value\n' >&2; exit 2; }
      vault="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'FAIL unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Draft is required and must be a readable file.
[ -n "$draft" ] || { printf 'FAIL no --draft given\n' >&2; exit 2; }
[ -f "$draft" ] || { printf 'FAIL draft file does not exist: %s\n' "$draft" >&2; exit 2; }
[ -r "$draft" ] || { printf 'FAIL draft file not readable: %s\n' "$draft" >&2; exit 2; }

# Resolve the vault — explicit flag, else OBSIDIAN_VAULT_PATH. Strip any trailing
# slash so the relative-path prefix strip below is exact.
if [ -z "$vault" ]; then
  if [ -n "${OBSIDIAN_VAULT_PATH:-}" ]; then
    vault="$OBSIDIAN_VAULT_PATH"
  else
    printf 'FAIL no --vault given and OBSIDIAN_VAULT_PATH unset\n' >&2
    exit 2
  fi
fi
vault="${vault%/}"
[ -d "$vault" ] || { printf 'FAIL vault dir does not exist: %s\n' "$vault" >&2; exit 2; }

tmpd="$(mktemp -d 2>/dev/null)" || { printf 'FAIL cannot create temp dir\n' >&2; exit 2; }
trap 'rm -rf "$tmpd"' EXIT
targets_file="$tmpd/targets"

# Build the target set, mirroring checkWikilinks: every *.md/*.base note's
# vault-relative path AND its extension-stripped form. Prune the audit's skip
# dirs. -print0 + read -d '' is space-safe (the real vault path has spaces).
find "$vault" \
  \( -name .git -o -name node_modules -o -name .venv -o -name .claude -o -name .agents -o -name .codex \) -type d -prune -o \
  -type f \( -name '*.md' -o -name '*.base' \) -print0 2>/dev/null \
| while IFS= read -r -d '' f; do
    rel="${f#"$vault"/}"
    printf '%s\n' "$rel"
    # Strip exactly ONE trailing extension (.md or .base), like the audit's
    # single `.replace(/\.(md|base)$/, "")` — not both, so a `foo.base.md`
    # registers as `foo.base` (with-ext) + `foo.base` (sans-.md), matching JS.
    case "$rel" in
      *.md)   printf '%s\n' "${rel%.md}" ;;
      *.base) printf '%s\n' "${rel%.base}" ;;
    esac
  done > "$targets_file"

# resolves <target> — exit 0 if the target is in the set under the audit's three
# accepted forms (verbatim / +.md / +.base). grep -Fxq: fixed-string, whole-line.
resolves() {
  local t="$1"
  grep -Fxq -- "$t"       "$targets_file" && return 0
  grep -Fxq -- "$t.md"    "$targets_file" && return 0
  grep -Fxq -- "$t.base"  "$targets_file" && return 0
  return 1
}

# suggest_full_path <target> — if exactly one vault note has basename == target
# (with or without extension), echo its extension-stripped full vault-relative
# path so the operator can fix a bare-basename link to its full form. Silent when
# zero or multiple candidates (ambiguous). String-equality on basenames — no
# regex, so a target with metacharacters is handled safely.
suggest_full_path() {
  local t="$1" line base base_noext full_noext matches cnt
  matches=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    base="${line##*/}"
    case "$base" in
      *.md)   base_noext="${base%.md}" ;;
      *.base) base_noext="${base%.base}" ;;
      *)      base_noext="$base" ;;
    esac
    if [ "$base" = "$t" ] || [ "$base_noext" = "$t" ]; then
      case "$line" in
        *.md)   full_noext="${line%.md}" ;;
        *.base) full_noext="${line%.base}" ;;
        *)      full_noext="$line" ;;
      esac
      matches="$matches$full_noext
"
    fi
  done < "$targets_file"
  matches="$(printf '%s' "$matches" | sed '/^$/d' | LC_ALL=C sort -u)"
  cnt="$(printf '%s\n' "$matches" | sed '/^$/d' | grep -c '' )"
  [ "$cnt" = "1" ] && printf '%s' "$matches"
}

# Extract distinct wikilink targets from the draft. grep -oE finds each `[[...]]`
# (inner has no `]`); we then cut the alias/heading and trim. `|| true` so a
# draft with no links does not trip pipefail on grep's exit 1.
raw="$(grep -oE '\[\[[^]]+\]\]' "$draft" 2>/dev/null || true)"
distinct="$tmpd/distinct"
printf '%s\n' "$raw" | while IFS= read -r tok; do
  [ -n "$tok" ] || continue            # skips the empty line when there are no links
  inner="${tok#\[\[}"; inner="${inner%\]\]}"
  t="${inner%%|*}"; t="${t%%#*}"       # cut at first alias `|` / heading `#`
  # Trim leading + trailing whitespace (mirror JS String.trim()).
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  # Emit the target verbatim — INCLUDING an empty string for a malformed `[[ ]]`
  # link. Do NOT substitute a display sentinel here: a literal like "(empty)"
  # could collide with a real note named "(empty)" and diverge from the reference
  # (which would resolve `[[(empty)]]` against a real `(empty).md`). The empty
  # target is carried as "" through resolution — where it matches no vault note
  # and so fails closed, exactly as the reference does — and is rendered as
  # "(empty)" only at print time.
  printf '%s\n' "$t"
done | LC_ALL=C sort -u > "$distinct"

total="$(grep -c '' "$distinct" 2>/dev/null || printf '0')"
[ -s "$distinct" ] || total=0

unresolved="$tmpd/unresolved"
: > "$unresolved"
# We report DISTINCT unresolved targets (deduped above), not one entry per
# occurrence the way the reference's `broken[]` does. The pass/fail VERDICT is
# identical — the gate blocks the write iff ANY target is unresolved — only the
# repeat-count of an identical broken link differs, which is cosmetic for a gate.
while IFS= read -r t; do
  resolves "$t" || printf '%s\n' "$t" >> "$unresolved"
done < "$distinct"

if [ -s "$unresolved" ]; then
  u="$(grep -c '' "$unresolved")"
  while IFS= read -r t; do
    disp="$t"; [ -n "$t" ] || disp="(empty)"
    printf 'FAIL unresolved wikilink: %s -> %s\n' "$draft" "$disp" >&2
    if [ -n "$t" ]; then
      sugg="$(suggest_full_path "$t")"
      [ -n "$sugg" ] && printf '       did you mean the full path: [[%s]] ?\n' "$sugg" >&2
    fi
  done < "$unresolved"
  printf 'FAIL %s of %s wikilink target(s) unresolved in %s — fix to full vault-relative paths before the drain writes (capabilities/closeout.md → Full-path wikilinks)\n' \
    "$u" "$total" "$draft" >&2
  exit 1
fi

printf 'PASS all %s wikilink target(s) resolve against vault: %s\n' "$total" "$draft"
exit 0
