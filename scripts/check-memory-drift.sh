#!/usr/bin/env bash
# check-memory-drift.sh — flag memory-index health failures.
#
# Inspects the per-harness memory directory for four failure classes:
#
#   1. Headline-vs-body DRIFT in project_*.md files. A project_*.md file has
#      DRIFT when its frontmatter description headline claims a closed state
#      (COMPLETE / CLOSED / DONE) but its body links to a different
#      `[[project_*]]` follow-on AND the description itself does not acknowledge
#      the follow-on. This catches the case where a session closed a project and
#      spawned a follow-on, updated the body, but never updated the headline.
#
#   2. MEMORY.md index BLOAT. When <memory-dir>/MEMORY.md exists it is
#      checked against two caps documented in core/memory-model.md:
#        - MEMORY_INDEX_SIZE_CAP_BYTES (24400) — the harness truncates memory
#          recall around this size, silently dropping tail entries.
#        - MEMORY_INDEX_LINE_CAP_CHARS (300) — index entries are one-line
#          headlines; an over-long line is detail that belongs in a topic file.
#      Crossing either cap is a memory-index health failure (same exit 1 as
#      drift) — the index has bloated past the point of reliable recall.
#
#   3. FRONTMATTER PARSER-SAFETY. Each memory note (every *.md in the dir except
#      MEMORY.md — the store uses kebab-case slugs with the type in frontmatter,
#      so no filename type-prefix is assumed) is scanned for the silent-corruption
#      class where a strict YAML parser misreads frontmatter without raising: a
#      missing/unterminated `---` block, or a TOP-LEVEL scalar value carrying an
#      unquoted ` #` (space-then-hash → YAML drops the rest as a comment) or `: `
#      (colon-space → YAML may read it as a nested mapping).
#
#      SCOPE — this is a NARROW line-oriented hazard linter, NOT a YAML parser,
#      NOT normalization/rewriting, NOT schema (required-field/enum) validation.
#      Ported from CE validate-frontmatter.py as a 3rd bash class (no new Python
#      dependency; the framework is bash + PS twins and the check is line scanning
#      this script already does). KNOWN false-negatives, accepted by design:
#        - folded/literal block scalars (`key: >` / `key: |`) — value is skipped
#          as already-structured; literal text after them is not scanned.
#        - continuation lines under a top-level scalar.
#        - a `#` not preceded by whitespace (not a YAML comment delimiter).
#        - malformed escapes/quotes INSIDE an already-quoted value (we skip
#          quoted values; validating quote-matching is not regex's job).
#      If this ever needs to grow past hazard-detection, a real YAML parser
#      (Python/pyyaml) becomes the right tool — see <TEAM>-208 python-over-bash.
#
#   4. INJECTION-DEFENSE on agent-written memory. Each note BODY is
#      scanned for prompt-injection payloads an agent might have copied verbatim
#      from untrusted tool/web output, which would hijack a future agent when the
#      note is recalled. CONSERVATIVE: flags only BARE, LINE-LEADING directives
#      (role-tag/role-header spoofs, ignore/forget/override-instructions, persona
#      flips, future-agent targeting, memory-write directives, prompt exfil) and
#      SKIPS fenced/indented code, blockquotes, and inline-code-led lines so a
#      security note can DISCUSS the patterns by fencing/quoting them. Hazard
#      linter, not a parser; see the in-body block + core/memory-model.md for the
#      pattern list and accepted false-negatives.
#
# Usage:
#   check-memory-drift.sh --memory-dir <path>
#   check-memory-drift.sh                       (derives from CLAUDE_CONFIG_DIR)
#   check-memory-drift.sh --injection-scan <file>   (scan ONE file's body for
#                                                    injection payloads; standalone,
#                                                    no --memory-dir needed)
#   check-memory-drift.sh --help
#
# Exit codes:
#   0 — clean (or no project_*.md files / MEMORY.md to inspect)
#   1 — drift detected, or MEMORY.md over a documented cap
#   2 — usage error (missing dir, bad args)
#
# This is a textual heuristic check. It does not call out to Linear. A future
# enhancement may cross-reference Linear-project status.

set -uo pipefail

# Caps documented in core/memory-model.md (Per-Harness Memory Index section).
MEMORY_INDEX_SIZE_CAP_BYTES=24400
MEMORY_INDEX_LINE_CAP_CHARS=300

usage() {
  sed -nE 's|^# ?||p' "$0" | awk '/^check-memory-drift\.sh/,/^A future/' | head -50
}

# scan_injection_file <file> — echo the prompt-injection payload class if the file
# carries a BARE, LINE-LEADING directive in a scannable position; empty = clean.
# CONSERVATIVE: skips fenced/indented code, blockquotes, and inline-code-led lines so
# a note can safely DISCUSS the patterns by fencing/quoting them — those, plus
# Unicode-whitespace-obfuscated and heading-embedded payloads, are ACCEPTED
# false-negatives (it catches the realistic threat: untrusted text pasted VERBATIM as
# a bare line-leading directive). Used by the --injection-scan single-file mode below.
#
# FAIL-SAFE body boundary (hardening over the per-note scan, which is paired with the
# frontmatter-safety check; standalone mode has no such companion): a leading UTF-8
# BOM is stripped so a BOM'd first `---` is recognized, and if the file has NO complete
# frontmatter (< 2 `---` delimiters — malformed or none) the WHOLE file is scanned
# rather than silently treated as bodyless. The PAYLOAD PATTERN SET (the kind=...
# chain) is what stays in lockstep with the class-4 per-note scan + the
# check-memory-drift.ps1 twin; the multi-class lockstep test exercises that set
# through both modes. Body-boundary handling intentionally differs (see above).
scan_injection_file() {
  LC_ALL=C awk '
    {
      if (NR==1 && substr($0,1,3) == "\357\273\277") $0 = substr($0,4)   # strip UTF-8 BOM
      lines[NR] = $0
      if ($0 ~ /^---[[:space:]]*$/) { seps++; if (seps==2) bodystart = NR+1 }
    }
    END {
      if (seps < 2) bodystart = 1                                        # no complete frontmatter -> scan all
      fence = 0
      for (i = bodystart; i <= NR; i++) {
        line = lines[i]
        if (line ~ /^[[:space:]]*(```|~~~)/) { fence = 1 - fence; continue }
        if (fence) continue
        if (line ~ /^[[:space:]]*$/) continue
        if (line ~ /^[[:space:]]*>/) continue
        if (substr(line,1,1) == "\t") continue
        if (substr(line,1,4) == "    ") continue
        m = line
        sub(/^[ \t]+/, "", m)
        sub(/^([*+-]|[0-9]+\.)[ \t]+/, "", m)
        sub(/^[ \t]+/, "", m)
        if (substr(m,1,1) == "`") continue
        lc = tolower(m)
        kind = ""
        if (lc ~ /^<[\/|]?(system|developer|assistant|user)[|]?>/) kind="role-tag"
        else if (lc ~ /^\[?(system|assistant|developer|user)\]?([ \t]+(message|prompt|instructions?))?[ \t]*:/) kind="role-header"
        else if (lc ~ /^(ignore|forget|override|disregard)[ \t]+(all[ \t]+|the[ \t]+)?(previous|prior|above)/) kind="override"
        else if (lc ~ /^do not follow[ \t]+(the[ \t]+)?(previous|prior|above)/) kind="override"
        else if (lc ~ /^you are now[ \t]/) kind="persona"
        else if (lc ~ /^from now on,?[ \t]+you[ \t]+(are|will|must)/) kind="persona"
        else if (lc ~ /^if you are (an?[ \t]+)?(ai|agent|assistant|llm)[ \t]+reading this/) kind="future-agent"
        else if (lc ~ /^when you read this/) kind="future-agent"
        else if (lc ~ /^when loaded into context/) kind="future-agent"
        else if (lc ~ /^(remember this|save this to memory|store this in memory|add this to memory|write this into memory|write this to memory)([ \t]+(forever|permanently|always))?[ \t]*:/) kind="memory-directive"
        else if (lc ~ /^(reveal|print|output|send|exfiltrate|leak).*(system prompt|developer instructions|hidden instructions|hidden prompt|your instructions)/) kind="exfil"
        if (kind != "") { print kind; exit }
      }
    }
  ' "$1"
}

memory_dir=""
injection_scan_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --memory-dir)
      [ $# -ge 2 ] || { printf 'FAIL --memory-dir requires a value\n' >&2; exit 2; }
      memory_dir="$2"; shift 2 ;;
    --injection-scan)
      [ $# -ge 2 ] || { printf 'FAIL --injection-scan requires a file path\n' >&2; exit 2; }
      injection_scan_file="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'FAIL unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# --injection-scan MODE: lint ONE arbitrary file (e.g. a drafted session log) for
# bare line-leading injection payloads before it is written into the durable vault.
# Standalone — does NOT require --memory-dir / CLAUDE_CONFIG_DIR. Exit 0 clean,
# 1 payload found, 2 usage/missing-file.
if [ -n "$injection_scan_file" ]; then
  [ -f "$injection_scan_file" ] || { printf 'FAIL --injection-scan: file does not exist: %s\n' "$injection_scan_file" >&2; exit 2; }
  inj_hit=$(scan_injection_file "$injection_scan_file")
  if [ -n "$inj_hit" ]; then
    printf 'FAIL injection %s: line-leading prompt-injection payload (class: %s) — fence/quote it under Raw observations, or remove it (see core/memory-model.md)\n' "$(basename "$injection_scan_file")" "$inj_hit" >&2
    exit 1
  fi
  printf 'PASS no injection payloads in %s\n' "$injection_scan_file"
  exit 0
fi

if [ -z "$memory_dir" ]; then
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    # Derive the Claude-harness memory dir from CLAUDE_CONFIG_DIR. The exact
    # subpath is harness-specific; we look for any projects/* subdir containing
    # a memory/ folder. If multiple match, prefer the one matching CWD-derived
    # naming. If exactly one exists, use it.
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

[ -d "$memory_dir" ] || { printf 'FAIL memory dir does not exist: %s\n' "$memory_dir" >&2; exit 2; }

drift=0
scanned=0
# Counts the FULL note set (every *.md except MEMORY.md) walked by
# the frontmatter + injection scans below — `scanned` counts only the project_*.md
# headline-drift subset. Reported separately in the PASS line: a single
# project-only count on a large mixed dir reads as a coverage gap that isn't there.
notes_scanned=0

# Use NUL-delimited find for paths with spaces; process_substitution + while-read
# is bash-3.2-safe (no mapfile).
while IFS= read -r -d '' f; do
  base=$(basename "$f")
  case "$base" in
    project_*.md) ;;
    *) continue ;;
  esac

  scanned=$((scanned + 1))

  # Parse frontmatter (between the first two `---` lines).
  description=$(awk '
    BEGIN { in_fm=0; saw_sep=0 }
    /^---$/ { saw_sep++; if (saw_sep==1) { in_fm=1; next } else { exit } }
    in_fm && /^description:/ {
      sub(/^description:[[:space:]]*/, "")
      sub(/^"/, "")
      sub(/"[[:space:]]*$/, "")
      print
      exit
    }
  ' "$f")

  own_name=$(awk '
    BEGIN { in_fm=0; saw_sep=0 }
    /^---$/ { saw_sep++; if (saw_sep==1) { in_fm=1; next } else { exit } }
    in_fm && /^name:/ { sub(/^name:[[:space:]]*/, ""); print; exit }
  ' "$f")

  # Heuristic trigger: headline claims closed state.
  if ! printf '%s' "$description" | grep -qiE 'COMPLETE|CLOSED|DONE'; then
    continue
  fi

  # Exception: if the description ALSO mentions a follow-on / pointer, the
  # headline acknowledges the live state — not drift.
  if printf '%s' "$description" | grep -qiE 'follow-?on|see body|active.*continu|see .?\['; then
    continue
  fi

  # Inspect body for [[project_*]] links to a DIFFERENT project.
  # awk: print everything after the second `---`.
  body=$(awk '
    BEGIN { saw_sep=0 }
    /^---$/ { saw_sep++; next }
    saw_sep>=2 { print }
  ' "$f")

  followon=""
  # Extract [[project_*]] links and find one that names a different project.
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    [ "$link" = "$own_name" ] && continue
    followon="$link"
    break
  done < <(printf '%s' "$body" | grep -oE '\[\[project_[A-Za-z0-9_]+(\|[^]]+)?\]\]' | sed -E 's/\[\[(project_[A-Za-z0-9_]+).*\]\]/\1/')

  if [ -n "$followon" ]; then
    printf 'FAIL drift: %s — headline claims closed but body links to follow-on [[%s]]; description does not acknowledge it\n' "$base" "$followon" >&2
    drift=1
  fi
done < <(find "$memory_dir" -maxdepth 1 -type f -name 'project_*.md' -print0)

# --- <TEAM>-136: MEMORY.md index size + per-entry line-length enforcement. -------
# When the index file exists, fail if it crosses either documented cap. This is
# the bloat the headline-vs-body staleness check could never catch: an index
# that grows past the harness recall cap silently truncates + loses recall.
index_fail=0
if [ -f "$memory_dir/MEMORY.md" ]; then
  size_bytes=$(wc -c < "$memory_dir/MEMORY.md" 2>/dev/null | tr -d ' ')
  if [ -n "$size_bytes" ] && [ "$size_bytes" -gt "$MEMORY_INDEX_SIZE_CAP_BYTES" ]; then
    printf 'FAIL MEMORY.md is %s bytes — over the ~%s-byte recall cap; the harness truncates recall past this size. Shorten the longest one-line index entries; move detail into the named topic files.\n' \
      "$size_bytes" "$MEMORY_INDEX_SIZE_CAP_BYTES" >&2
    index_fail=1
  fi

  # Per-entry line-length: count lines whose CHARACTER length exceeds the cap.
  # The cap is documented in CHARS, and the PS twin counts characters via
  # .Length, so bash must count characters too — not bytes. BSD awk has no
  # UTF-8 awareness (length is always bytes regardless of locale), so we derive
  # the Unicode codepoint count locale-independently: byte length minus the
  # count of UTF-8 continuation bytes (0x80–0xBF). LC_ALL=C keeps both the byte
  # `length` and the continuation-byte gsub deterministic across BSD/GNU awk
  # (see [[reference_awk_portability]] — set LC_ALL=C explicitly so gawk's gsub
  # does not silently no-op under an empty LANG). This matches PS .Length for
  # all BMP characters (em-dash, accented Latin, etc.); astral-plane codepoints
  # (1 here vs 2 UTF-16 units in PS) are out of scope for a text memory index.
  long_lines=$(LC_ALL=C awk -v cap="$MEMORY_INDEX_LINE_CAP_CHARS" \
    '{ s=$0; cont=gsub(/[\200-\277]/,"",s); if ((length($0)-cont) > cap) n++ } END { print n+0 }' \
    "$memory_dir/MEMORY.md" 2>/dev/null)
  if [ -n "$long_lines" ] && [ "$long_lines" -gt 0 ]; then
    printf 'FAIL MEMORY.md has %s index line(s) over the ~%s-char per-entry line-length cap. Trim each to a one-line headline; move detail into the named topic file.\n' \
      "$long_lines" "$MEMORY_INDEX_LINE_CAP_CHARS" >&2
    index_fail=1
  fi
fi

# --- <TEAM>-206: frontmatter parser-safety scan (narrow hazard linter). ----------
# For each memory note, flag the silent-corruption class a strict YAML parser
# would misread (see header for scope + accepted false-negatives). awk does the
# per-file scan — same engine + bash-3.2-safety (NUL find, no mapfile) as the
# description parser above. `---` delimiters match with trailing-whitespace
# tolerance so a CRLF file's trailing \r does not defeat the match (the PS twin's
# ReadAllLines strips \r — both converge). Single-quote/double-quote chars in awk
# strings use \047 / \042 octal escapes to avoid bash-quote nesting.
fm_fail=0
while IFS= read -r -d '' f; do
  base=$(basename "$f")
  notes_scanned=$((notes_scanned + 1))
  issues=$(LC_ALL=C awk '
    BEGIN { infm=0; saw_open=0; closed=0; buf="" }
    NR==1 {
      # Strip a leading UTF-8 BOM (EF BB BF). A strict YAML parser consumes the
      # BOM as stream-start, and PS ReadAllLines strips it too — without this,
      # bash would see "\xef\xbb\xbf---" and wrongly report no-open while the PS
      # twin accepts the file (a verified parity divergence). LC_ALL=C makes the
      # substr byte-based so the 3-byte octal compare is exact.
      if (substr($0,1,3) == "\357\273\277") $0 = substr($0,4)
      if ($0 !~ /^---[[:space:]]*$/) { print "no-open"; exit }
      infm=1; saw_open=1; next
    }
    infm && /^---[[:space:]]*$/ { closed=1; infm=0; next }
    infm {
      if ($0 ~ /^[[:space:]]*$/) next            # blank
      if ($0 ~ /^[[:space:]]*#/) next            # comment
      if ($0 ~ /^[[:space:]]/) next              # nested (indented) value
      if ($0 ~ /^-[[:space:]]/) next             # top-level list marker
      if ($0 !~ /:/) next                        # not a mapping line
      key=$0; sub(/:.*/, "", key)
      val=$0; sub(/^[^:]*:/, "", val)
      gsub(/^[[:space:]]+/, "", val); gsub(/[[:space:]]+$/, "", val)
      if (val == "") next                        # parent of a nested block
      c=substr(val, 1, 1)
      if (c=="\042" || c=="\047" || c=="[" || c=="{" || c=="|" || c==">") next  # quoted / flow / block scalar
      if (val ~ /[[:space:]]#/) buf = buf "hash\t" key "\n"
      if (val ~ /:[[:space:]]/) buf = buf "colon\t" key "\n"
    }
    END {
      # Unterminated frontmatter: report ONLY the structural failure. The buffered
      # scalar hazards are unreliable (body text gets scanned as frontmatter once
      # the close delimiter is missing); a re-run after the close is added surfaces
      # any genuine scalar hazard without the misleading body noise.
      if (saw_open==1 && closed==0) { print "no-close" }
      else { printf "%s", buf }
    }
  ' "$f")
  [ -z "$issues" ] && continue
  fm_fail=1
  printf '%s\n' "$issues" | while IFS="$(printf '\t')" read -r kind key; do
    case "$kind" in
      no-open)  printf 'FAIL frontmatter %s: missing opening --- delimiter line\n' "$base" >&2 ;;
      no-close) printf 'FAIL frontmatter %s: frontmatter not closed (no second --- line)\n' "$base" >&2 ;;
      hash)     printf 'FAIL frontmatter %s: top-level key "%s" value has unquoted " #" — quote it (YAML drops everything after a space-#)\n' "$base" "$key" >&2 ;;
      colon)    printf 'FAIL frontmatter %s: top-level key "%s" value has unquoted ": " — quote it (YAML may read it as a nested mapping)\n' "$base" "$key" >&2 ;;
    esac
  done
done < <(find "$memory_dir" -maxdepth 1 -type f -name '*.md' ! -name 'MEMORY.md' -print0)

# --- <TEAM>-218: injection-defense scan (line-leading payload hazard linter). -----
# For each memory note, scan the BODY (after the 2nd `---`) for prompt-injection
# payloads an agent might have copied verbatim from untrusted tool/web output —
# text that would hijack a FUTURE agent when this note is autoloaded/recalled.
#
# CONSERVATIVE by design (the real store is security-note-heavy and legitimately
# DISCUSSES these patterns): a payload is flagged ONLY when it sits as a BARE,
# LINE-LEADING directive — the shape verbatim-copied hostile text takes. The scan
# SKIPS fenced code blocks (``` / ~~~), markdown blockquotes, indented code
# (>=4 spaces or a leading tab), and inline-code-led lines — which is the
# documented safe way to discuss these patterns in a security note. Same
# hazard-linter framing as the <TEAM>-206 class above: a high-signal heuristic, NOT
# an exhaustive parser. KNOWN false-negatives, accepted by design:
#   - payloads inside fences/quotes/blockquotes/inline-code (discussion, not a
#     live directive — fencing IS the escape hatch).
#   - multi-line, obfuscated, or non-line-leading injections.
#   - credential-string exfil (covered by the outbound-content scan, not here).
# The fix when flagged: if the note is documenting the pattern, fence or quote
# it; if it is a real copied payload, remove it. See core/memory-model.md.
inj_fail=0
while IFS= read -r -d '' f; do
  base=$(basename "$f")
  hit=$(LC_ALL=C awk '
    BEGIN { saw_sep=0; fence=0 }
    /^---[[:space:]]*$/ { saw_sep++; next }
    saw_sep < 2 { next }
    {
      line=$0
      if (line ~ /^[[:space:]]*(```|~~~)/) { fence = 1 - fence; next }   # fenced code toggle
      if (fence) next
      if (line ~ /^[[:space:]]*$/) next                                  # blank
      if (line ~ /^[[:space:]]*>/) next                                  # blockquote
      if (substr(line,1,1) == "\t") next                                # tab-indented code
      if (substr(line,1,4) == "    ") next                              # 4-space-indented code
      m=line
      sub(/^[ \t]+/, "", m)
      sub(/^([*+-]|[0-9]+\.)[ \t]+/, "", m)                             # strip a list marker
      sub(/^[ \t]+/, "", m)
      if (substr(m,1,1) == "`") next                                    # inline-code-led line
      lc=tolower(m)
      kind=""
      # NOTE: token whitespace is ASCII [ \t] (not [[:space:]]) so the bash awk
      # scan and the PS -imatch twin agree exactly. A Unicode-whitespace-obfuscated
      # payload (e.g. NBSP between words) is an accepted false-negative in BOTH —
      # documented in core/memory-model.md.
      if (lc ~ /^<[\/|]?(system|developer|assistant|user)[|]?>/)                                         kind="role-tag"
      else if (lc ~ /^\[?(system|assistant|developer|user)\]?([ \t]+(message|prompt|instructions?))?[ \t]*:/) kind="role-header"
      else if (lc ~ /^(ignore|forget|override|disregard)[ \t]+(all[ \t]+|the[ \t]+)?(previous|prior|above)/) kind="override"
      else if (lc ~ /^do not follow[ \t]+(the[ \t]+)?(previous|prior|above)/)                            kind="override"
      else if (lc ~ /^you are now[ \t]/)                                                                 kind="persona"
      else if (lc ~ /^from now on,?[ \t]+you[ \t]+(are|will|must)/)                                      kind="persona"
      else if (lc ~ /^if you are (an?[ \t]+)?(ai|agent|assistant|llm)[ \t]+reading this/)                kind="future-agent"
      else if (lc ~ /^when you read this/)                                                               kind="future-agent"
      else if (lc ~ /^when loaded into context/)                                                         kind="future-agent"
      else if (lc ~ /^(remember this|save this to memory|store this in memory|add this to memory|write this into memory|write this to memory)([ \t]+(forever|permanently|always))?[ \t]*:/) kind="memory-directive"
      else if (lc ~ /^(reveal|print|output|send|exfiltrate|leak).*(system prompt|developer instructions|hidden instructions|hidden prompt|your instructions)/) kind="exfil"
      if (kind != "") { print kind; exit }
    }
  ' "$f")
  [ -z "$hit" ] && continue
  inj_fail=1
  printf 'FAIL injection %s: line-leading prompt-injection payload (class: %s) — if documenting the pattern, fence or quote it; if real, remove it (see core/memory-model.md)\n' "$base" "$hit" >&2
done < <(find "$memory_dir" -maxdepth 1 -type f -name '*.md' ! -name 'MEMORY.md' -print0)

if [ "$drift" -eq 0 ] && [ "$index_fail" -eq 0 ] && [ "$fm_fail" -eq 0 ] && [ "$inj_fail" -eq 0 ]; then
  printf 'PASS no memory headline-vs-body drift; MEMORY.md within caps; frontmatter parser-safe; no injection payloads (%s project files headline-checked, %s notes frontmatter+injection-scanned in %s)\n' "$scanned" "$notes_scanned" "$memory_dir"
  exit 0
fi

if [ "$drift" -ne 0 ]; then
  printf 'FAIL %s drift(s) detected in %s\n' "$drift" "$memory_dir" >&2
fi
exit 1
