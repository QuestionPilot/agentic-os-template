#!/usr/bin/env bash
# scripts/check-clean.sh — public-repo cleanliness guard.
#
# The permanent enforcement that keeps a public framework tree free of operator
# identity and private tracker issue IDs. It replaces the publish-time scrubber
# model (strip leaks before a snapshot) with a fail-closed gate: the build FAILS
# when a leak is present, so the canonical tree is always clean — there is no
# private original to scrub from.
#
# Scans a target tree (default: the current directory) and FAILS (exit 1) when
# it finds any of:
#   - tracker issue IDs        QUE-<digits>            (the project's issue prefix)
#   - macOS / Linux home paths with a real username segment under the home root
#   - Windows home paths with a real username segment under the profile root
#   - email addresses          (real shape; documentation + noreply domains pass)
#   - operator identity tokens listed in $OPERATOR_PII_TOKENS (component-split
#                              aware: each comma-separated token is scanned alone,
#                              case-insensitively, so a name split across files is
#                              still caught)
#   - commit-metadata identity leaks (opt-in, git mode): with
#                              $COMMIT_IDENTITY_ALLOWLIST set, every ahead-of-default
#                              branch commit must carry an allowlisted author AND
#                              committer — content scans cannot see commit metadata
#
# Enumeration (hardened): in a git work tree the scan walks `git ls-files` and
# inspects each TRACKED file. This closes four bypasses a recursive,
# basename-excluded filesystem grep left open:
#   - an arbitrarily-named committed copy of this guard (e.g. docs/check-clean.sh)
#     is no longer skipped — self-exclusion is by EXACT repo-relative path, not
#     basename;
#   - a committed gitignored-by-name file (local.env / .mcp.json) is caught;
#   - tracked content is read as BYTES with NUL stripped, so a UTF-16 / binary
#     file carrying a leak is de-binarised and scanned (not skipped as binary),
#     and an UNREADABLE tracked file FAILS closed rather than passing silently;
#   - a tracked symlink is inspected by its TARGET text (where a home path can
#     hide), not by following the link.
# A non-git target (synthetic test fixtures) falls back to a filesystem walk
# with the same per-file scanning.
#
# A bounded multi-line pass additionally rejoins hard-wrapped lines so a
# high-signal token split across a newline (QUE-\n123, alice@\ncorp.example) is
# still caught — an adversarial split, not the accidental-operator-leak model.
#
# Design (rationale in prose, no issue IDs in this public file): the denylist
# derives from the retiring operator-naming check and the check-drift portability
# scan. The structural patterns need no operator identity, so they run unchanged
# in CI. The operator's personal name / handle / hostname — which no generic
# pattern can know — come from $OPERATOR_PII_TOKENS, populated in the gitignored
# local.env. The shipped guard therefore carries ZERO operator PII, and every
# operator defends their own identity.
#
# A clean no-match is the ONLY pass. A missing or erroring scanner FAILS rather
# than silently passing.
#
# Tested against SYNTHETIC dirty/clean fixtures, never a live framework tree
# (which carries issue IDs by design). See tests/check-clean.test.sh.
set -uo pipefail

target="${1:-.}"
if [ ! -d "$target" ]; then
  printf 'FAIL check-clean: target is not a directory: %s\n' "$target" >&2
  exit 2
fi

# Pick up operator tokens from local.env in the target tree when not already
# exported (a local pre-push convenience). Absent in CI, so this no-ops there.
if [ -z "${OPERATOR_PII_TOKENS:-}" ] && [ -f "$target/local.env" ]; then
  # Strip CR (CRLF local.env from a Windows operator), then drop an unquoted
  # trailing ` # comment`, then peel one layer of surrounding quotes.
  OPERATOR_PII_TOKENS="$(grep -E '^[[:space:]]*(export[[:space:]]+)?OPERATOR_PII_TOKENS=' "$target/local.env" \
    | head -n1 | tr -d '\r' | sed -E 's/^[^=]*=//' \
    | sed -E 's/[[:space:]]+#.*$//' | sed -e 's/^["'\'']//' -e 's/["'\'']$//')"
fi

fail=0

# --- Patterns --------------------------------------------------------------
# Tracker issue IDs. (`QUE-[0-9]+` does not match its own source: the literal is
# followed by `[`, not a digit.)
ISSUE_RE='QUE-[0-9]+'
# Home paths carrying a REAL username segment. The username class begins with an
# alphanumeric / dot / underscore, so angle-bracket or $-variable placeholders do
# not match — and the pattern does not match its own source either. The Windows
# arm accepts ONE OR MORE backslashes, so simple, JSON-escaped, and nested
# source-of-JSON profile paths (one, two, or four backslashes) are all caught.
HOME_RE='/(Users|home)/[A-Za-z0-9._][A-Za-z0-9._-]*|[A-Za-z]:\\+Users\\+[A-Za-z0-9._-]+'
# Email addresses (real shape).
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

# Pre-split the operator token list once: split on commas AND whitespace, so a
# configured "Jane Doe" catches a stray "Jane" or "Doe" on its own; sub-tokens
# shorter than 3 chars are skipped to avoid noise. Empty in the CI case.
_TOKENS=()
if [ -n "${OPERATOR_PII_TOKENS:-}" ]; then
  set -f  # no globbing while word-splitting the token list
  for _t in $(printf '%s' "$OPERATOR_PII_TOKENS" | tr ',' ' '); do
    [ "${#_t}" -ge 3 ] && _TOKENS+=("$_t")
  done
  set +f
fi

# --- Exclusions ------------------------------------------------------------
# is_excluded_path <relpath> — 0 if the path is excluded from CONTENT scans.
# Self-reference is by EXACT repo-relative path (this guard + its test twins name
# the very patterns they scan for) — NOT by basename, so a same-named copy
# elsewhere in the tree is still scanned. Machine-local files (local.env /
# .mcp.json) are content-excluded ONLY in git mode, where the operator's
# gitignored copy legitimately holds local data and is not even enumerated, and a
# TRACKED copy is caught by the explicit check below; in a non-git tree (a
# release dir, an extracted archive) there is no gitignore semantics, so a
# present local.env / .mcp.json IS scanned for leaks. VCS / harness state dirs
# are pruned.
is_excluded_path() {
  case "$1" in
    scripts/check-clean.sh|scripts/check-clean.ps1|tests/check-clean.test.sh|tests/check-clean.test.ps1) return 0 ;;
  esac
  if [ "$is_git" -eq 1 ]; then
    case "$1" in
      local.env|*/local.env|.mcp.json|*/.mcp.json) return 0 ;;
    esac
  fi
  case "/$1/" in
    */.git/*|*/.claude/*|*/.codex/*|*/.agents/*|*/cross-model-out/*) return 0 ;;
  esac
  return 1
}

# --- Content acquisition ---------------------------------------------------
# get_content <abspath> — echo the file's text (NUL-stripped so a UTF-16 / binary
# blob is de-binarised) on stdout. A symlink yields its TARGET text (separators
# normalised to '/'), not the pointed-to content. Returns non-zero (fail-closed)
# when the file is unreadable.
get_content() {
  local abs="$1"
  if [ -L "$abs" ]; then
    readlink "$abs" 2>/dev/null | tr '\\' '/'
    return $?
  fi
  [ -r "$abs" ] || return 3
  LC_ALL=C tr -d '\0' < "$abs"
}


# hard_unwrap — stdin -> stdout with hard line-wraps removed: each line is
# trimmed of leading/trailing horizontal whitespace (incl. CR) and concatenated
# with no separator, so a token split across a wrap becomes contiguous. Bounded
# high-signal pass for the adversarial split-leak model.
hard_unwrap() {
  LC_ALL=C awk '{ l=$0; gsub(/^[ \t\r]+/,"",l); gsub(/[ \t\r]+$/,"",l); printf "%s", l }'
}

# --- Per-file scanners -----------------------------------------------------
# scan_class <rel> <content> <joined> <label> <ere> — report a structural-pattern
# leak. The line-aware pass over <content> fires first; only when it is clean is
# the bounded multi-line pass over <joined> tried, so a single-line leak is not
# double-reported.
scan_class() {
  local rel="$1" content="$2" joined="$3" label="$4" re="$5" hits status
  hits="$(printf '%s\n' "$content" | grep -aEn -e "$re")"; status=$?
  if [ "$status" -eq 0 ]; then
    printf 'FAIL %s\n' "$label" >&2
    printf '%s\n' "$hits" | sed "s#^#  $rel:#" | head -n 50 >&2
    fail=1; return
  elif [ "$status" -gt 1 ]; then
    printf 'FAIL %s — scan errored (grep exit %s); not treated as a pass\n' "$label" "$status" >&2
    fail=1; return
  fi
  local mhits mstatus
  mhits="$(printf '%s\n' "$joined" | grep -aEn -e "$re")"; mstatus=$?
  if [ "$mstatus" -eq 0 ]; then
    printf 'FAIL %s (multi-line)\n' "$label" >&2
    printf '%s\n' "$mhits" | sed "s#^#  $rel:#" | head -n 50 >&2
    fail=1
  elif [ "$mstatus" -gt 1 ]; then
    printf 'FAIL %s (multi-line) — scan errored (grep exit %s); not treated as a pass\n' "$label" "$mstatus" >&2
    fail=1
  fi
}

# scan_email_pass <rel> <text> <suffix> — extract every address in <text>; FAIL
# if any address's FULL domain is not EXACTLY an allowed documentation/noreply
# domain (substring allow-listing would let bot@users.noreply.github.com.evil.net
# slip through). Returns 0 if a leak was reported, 1 otherwise.
scan_email_pass() {
  local rel="$1" text="$2" suffix="$3" addrs status leaks="" addr
  addrs="$(printf '%s\n' "$text" | grep -aEo -e "$EMAIL_RE")"; status=$?
  if [ "$status" -gt 1 ]; then
    printf 'FAIL email scan errored%s (grep exit %s); not treated as a pass\n' "$suffix" "$status" >&2
    fail=1; return 0
  fi
  [ "$status" -ne 0 ] && return 1
  while IFS= read -r addr; do
    [ -z "$addr" ] && continue
    case "${addr##*@}" in
      example.com|example.org|example.net|users.noreply.github.com) : ;;  # allowed exactly
      *) leaks="${leaks}${addr}"$'\n' ;;
    esac
  done <<< "$addrs"
  if [ -n "$leaks" ]; then
    printf 'FAIL email address found%s\n' "$suffix" >&2
    printf '%s' "$leaks" | sort -u | head -n 50 | sed "s#^#  $rel:#" >&2
    fail=1; return 0
  fi
  return 1
}

# scan_email_class <rel> <content> <joined> — line-aware email pass, then the
# bounded multi-line pass only if the first is clean.
scan_email_class() {
  scan_email_pass "$1" "$2" "" && return
  scan_email_pass "$1" "$3" " (multi-line)"
}

# scan_token_class <rel> <content> <joined> <tok> — case-insensitive FIXED-string
# scan for an operator identity token (a name may legitimately contain regex
# metacharacters). Line-aware first; only when clean is the bounded multi-line
# (hard-unwrapped) pass tried, so a token split across a wrap is caught too.
scan_token_class() {
  local rel="$1" content="$2" joined="$3" tok="$4" hits status
  hits="$(printf '%s\n' "$content" | grep -aFn -i -e "$tok")"; status=$?
  if [ "$status" -eq 0 ]; then
    printf 'FAIL operator identity token found ("%s")\n' "$tok" >&2
    printf '%s\n' "$hits" | sed "s#^#  $rel:#" | head -n 50 >&2
    fail=1; return
  elif [ "$status" -gt 1 ]; then
    printf 'FAIL operator identity token scan errored (grep exit %s); not treated as a pass\n' "$status" >&2
    fail=1; return
  fi
  local mhits mstatus
  mhits="$(printf '%s\n' "$joined" | grep -aFn -i -e "$tok")"; mstatus=$?
  if [ "$mstatus" -eq 0 ]; then
    printf 'FAIL operator identity token found ("%s") (multi-line)\n' "$tok" >&2
    printf '%s\n' "$mhits" | sed "s#^#  $rel:#" | head -n 50 >&2
    fail=1
  elif [ "$mstatus" -gt 1 ]; then
    printf 'FAIL operator identity token scan errored (multi-line; grep exit %s); not treated as a pass\n' "$mstatus" >&2
    fail=1
  fi
}

# scan_file_content <rel> <content> — run every class scanner over one file.
scan_file_content() {
  local rel="$1" content="$2" joined
  joined="$(printf '%s' "$content" | hard_unwrap)"
  scan_class "$rel" "$content" "$joined" 'tracker issue ID found (QUE-<n>)' "$ISSUE_RE"
  scan_class "$rel" "$content" "$joined" 'machine-specific home path found' "$HOME_RE"
  scan_email_class "$rel" "$content" "$joined"
  if [ "${#_TOKENS[@]}" -gt 0 ]; then
    local _tok
    for _tok in "${_TOKENS[@]}"; do
      scan_token_class "$rel" "$content" "$joined" "$_tok"
    done
  fi
}

# --- Enumerate + scan ------------------------------------------------------
# Prefer git ls-files (tracked set only: gitignored operator junk is skipped, a
# committed leak is scanned). Fall back to a filesystem walk for non-git
# fixtures.
is_git=0
if command -v git >/dev/null 2>&1 && git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  is_git=1
fi

if [ "$is_git" -eq 1 ]; then
  # ls-files -s gives the index MODE per path. A symlink is mode 120000 on every
  # platform (the mode is index-canonical; core.symlinks only affects checkout),
  # so it is the authoritative symlink signal. A symlink is scanned from its
  # canonical git BLOB (the target path) with separators normalised to '/', not
  # from the OS-resolved worktree link (Windows may store '\\' or check it out as
  # plain text). Regular files are read from the worktree (bytes, NUL-stripped).
  while IFS= read -r -d '' entry; do
    mode="${entry%% *}"
    rel="${entry#*$'\t'}"
    is_excluded_path "$rel" && continue
    if [ "$mode" = "120000" ]; then
      content="$(git -C "$target" show ":$rel" 2>/dev/null | tr '\\' '/')"; rc=$?
    else
      content="$(get_content "$target/$rel")"; rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      printf 'FAIL unreadable tracked file (fail-closed): %s\n' "$rel" >&2
      fail=1; continue
    fi
    scan_file_content "$rel" "$content"
  done < <(git -C "$target" ls-files -s -z)
else
  while IFS= read -r -d '' abs; do
    rel="${abs#"$target"/}"
    is_excluded_path "$rel" && continue
    content="$(get_content "$abs")"; rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'FAIL unreadable file (fail-closed): %s\n' "$rel" >&2
      fail=1; continue
    fi
    scan_file_content "$rel" "$content"
  done < <(find "$target" \
    \( -name .git -o -name .claude -o -name .codex -o -name .agents -o -name cross-model-out \) -prune -o \
    \( -type f -o -type l \) -print0)
fi

# A committed local.env / .mcp.json is itself a leak — they hold machine-local
# PII (home paths, tokens). They are excluded from the CONTENT scans above (the
# operator's gitignored copies legitimately hold local data), so catch a TRACKED
# copy explicitly. No-ops on a non-git target (synthetic fixtures).
if [ "$is_git" -eq 1 ]; then
  _tracked_local="$(git -C "$target" ls-files -- 'local.env' '*/local.env' '.mcp.json' '*/.mcp.json' 2>/dev/null)"
  if [ -n "$_tracked_local" ]; then
    printf 'FAIL machine-local file is tracked (must be gitignored)\n' >&2
    printf '%s\n' "$_tracked_local" >&2
    fail=1
  fi
fi

# --- Commit-metadata identity check -----------------------------------------
# The content scans above cannot see git COMMIT METADATA: author/committer
# name+email are their own leak vector — a clone with no repo-local identity
# derives the operator's personal name and machine hostname into PUBLIC history
# on a plain `git commit`. When COMMIT_IDENTITY_ALLOWLIST is set (exported, or
# read from the target's gitignored local.env — the same opt-in pattern as
# OPERATOR_PII_TOKENS, so the shipped guard carries zero operator identity),
# every commit the current branch would publish — the range ahead of the
# published default branch — must carry an allowlisted author AND committer.
# Entries are comma-separated, matched EXACTLY as `Name <email>`. Unset, the
# check is a documented no-op (downstream operators opt in); the PASS line
# reports which way it went so coverage is never overstated. Git mode only —
# a non-git tree has no commit metadata.
identity_note=""
if [ "$is_git" -eq 1 ]; then
  if [ -z "${COMMIT_IDENTITY_ALLOWLIST:-}" ] && [ -f "$target/local.env" ]; then
    COMMIT_IDENTITY_ALLOWLIST="$(grep -E '^[[:space:]]*(export[[:space:]]+)?COMMIT_IDENTITY_ALLOWLIST=' "$target/local.env" \
      | head -n1 | tr -d '\r' | sed -E 's/^[^=]*=//' \
      | sed -E 's/[[:space:]]+#.*$//' | sed -e 's/^["'\'']//' -e 's/["'\'']$//')"
  fi
  if [ -z "${COMMIT_IDENTITY_ALLOWLIST:-}" ]; then
    identity_note="; commit-identity check skipped (COMMIT_IDENTITY_ALLOWLIST unset)"
  elif ! git -C "$target" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    identity_note="; commit-identity: no commits to check"
  else
    # Parse the allowlist into exact identities. A set-but-empty-after-parsing
    # allowlist is a misconfiguration — fail closed rather than skip silently.
    _ALLOWED=()
    _old_ifs="$IFS"; IFS=','
    for _e in $COMMIT_IDENTITY_ALLOWLIST; do
      _e="${_e#"${_e%%[![:space:]]*}"}"; _e="${_e%"${_e##*[![:space:]]}"}"
      [ -n "$_e" ] && _ALLOWED+=("$_e")
    done
    IFS="$_old_ifs"
    if [ "${#_ALLOWED[@]}" -eq 0 ]; then
      printf 'FAIL commit-identity: COMMIT_IDENTITY_ALLOWLIST is set but parses to no entries (fail-closed)\n' >&2
      fail=1
    else
      # Base = the published default branch; the range ahead of it is exactly
      # the commit set a push/PR would publish. No resolvable base (a fixture
      # repo with no remote) => check every commit reachable from HEAD.
      _base=""
      for _ref in origin/HEAD origin/main origin/master; do
        if git -C "$target" rev-parse --verify --quiet "$_ref" >/dev/null 2>&1; then _base="$_ref"; break; fi
      done
      if [ -n "$_base" ]; then _range="$_base..HEAD"; else _range="HEAD"; fi
      _meta="$(git -C "$target" log --format='%h%x09%an <%ae>%x09%cn <%ce>' "$_range" 2>/dev/null)"; _rc=$?
      if [ "$_rc" -ne 0 ]; then
        printf 'FAIL commit-identity: git log failed over %s (fail-closed)\n' "$_range" >&2
        fail=1
      else
        _checked=0
        while IFS="$(printf '\t')" read -r _h _author _committer; do
          [ -z "$_h" ] && continue
          _checked=$((_checked + 1))
          _ok=0
          for _allowed in "${_ALLOWED[@]}"; do
            [ "$_author" = "$_allowed" ] && { _ok=1; break; }
          done
          if [ "$_ok" -eq 0 ]; then
            printf 'FAIL commit-identity: commit %s author not allowlisted: %s\n' "$_h" "$_author" >&2
            fail=1
          fi
          _ok=0
          for _allowed in "${_ALLOWED[@]}"; do
            [ "$_committer" = "$_allowed" ] && { _ok=1; break; }
          done
          if [ "$_ok" -eq 0 ]; then
            printf 'FAIL commit-identity: commit %s committer not allowlisted: %s\n' "$_h" "$_committer" >&2
            fail=1
          fi
        done <<< "$_meta"
        identity_note="; $_checked branch commit(s) identity-checked"
      fi
    fi
  fi
fi

if [ "$fail" -ne 0 ]; then
  printf 'FAIL check-clean: leaks found in %s\n' "$target" >&2
  exit 1
fi
printf 'PASS check-clean: %s is clean (no issue IDs / home paths / emails / operator tokens)%s\n' "$target" "$identity_note"
exit 0
