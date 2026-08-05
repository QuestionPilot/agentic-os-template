#!/usr/bin/env bash
# scripts/check-state-currentness.sh — advisory SEMANTIC-currentness signal.
#
# Answers the question the mechanical audit cannot: "is what the durable layers
# SAY about tracker state still TRUE?" Every other checker in scripts/ proves a
# structural property of the filesystem — an index resolves, a manifest is
# fresh, a heading exists. All of them can pass while a memory note or a vault
# project note confidently asserts an issue state that the tracker changed
# hours ago. That failure mode is invisible to a structural gate and expensive
# in practice: an agent orients off the stale claim and acts on it.
#
# Two finding classes:
#
#   1. CLAIM MISMATCH. A note asserts a state for a tracker issue
#      (`<PREFIX>-<N>`) that disagrees with the issue's live state. Each finding
#      is sub-classed by whether the claim carried an explicit as-of date:
#        stale-claim     — an UNDATED present-tense assertion. The real defect:
#                          the note reads as current and is wrong.
#        stale-snapshot  — a claim under an explicitly dated heading/bullet
#                          ("Open issues as of 2026-08-04"). Aging is expected;
#                          the finding says the snapshot needs a refresh, not
#                          that the note lied. Reported separately so a refresh
#                          backlog never masquerades as a correctness bug.
#      History LOGS are not claims at all and are skipped outright (see
#      HISTORY_SECTIONS below) — a `## State Deltas` bullet records what was
#      true on a past date and stays correct as written forever.
#
#   2. PROJECT/CHILD CONTRADICTION. A project's own status disagrees with the
#      states of its child issues:
#        project-closed-with-open-children   Completed/Canceled, ≥1 open child
#        project-idle-with-active-children   Backlog/Planned, ≥1 In Progress child
#        project-active-with-no-open-children In Progress, 0 open children
#
# ADVISORY, WARN-only — never a gate, and it never edits memory, vault notes, or
# tracker state. Deliberately NOT wired into `make verify`: CI has no tracker
# token, and tracker state is workspace state, not repo state. `self-audit`
# invokes it and reports the findings in a section separate from the mechanical
# pillar scores, so a semantically stale system can no longer present as an
# unqualified 100/100.
#
# FALSE POSITIVES ARE THE ENEMY. This is a heuristic text scanner, not a parser,
# and it is deliberately tuned to under-report: a missed stale claim costs one
# audit cycle, a false accusation costs operator trust in the whole signal.
# Claim extraction therefore only fires on a `<PREFIX>-<N>` token that owns a
# state word by proximity (see the awk scanner), skips fenced code, and skips
# history sections entirely.
#
# Requires the lineark CLI (linear/linear-setup.md §3.2), jq, and awk. Override
# the binary with $LINEARK_BIN — the hermetic tests inject a stub that serves
# fixture JSON, so this check is testable without live credentials.
#
# Usage:
#   check-state-currentness.sh [--memory-dir <d>]... [--vault-dir <d>]
#                              [--prefix <P>] [--limit <n>] [--max-reads <n>]
#                              [--no-projects] [--list] [--isolated]
#
#   --memory-dir <d>  a memory store to scan (repeatable). Default: resolved
#                     from local.env CLAUDE_CONFIG_DIR (its projects/*/memory
#                     stores) unless --isolated.
#   --vault-dir <d>   durable-knowledge vault root. Active project notes under
#                     01-Projects/ are scanned. Default: local.env
#                     OBSIDIAN_VAULT_PATH unless --isolated.
#   --prefix <P>      tracker issue prefix (e.g. the team key). Default:
#                     local.env TRACKER_ISSUE_PREFIX. Without one, claim
#                     scanning cannot run and the check skips.
#   --limit <n>       max issues pulled in the bulk state-map call (default 250,
#                     lineark's documented ceiling). A payload that comes back
#                     AT the limit is treated as possibly truncated: unmatched
#                     identifiers fall back to per-issue reads rather than being
#                     silently reported as unknown.
#   --max-reads <n>   cap on per-issue/per-project follow-up read calls
#                     (default 40; 0 = bulk-list evidence only).
#   --no-projects     skip finding class 2 (claim scanning only).
#   --list            machine mode: one TSV finding per line, for self-audit.
#   --isolated        no local.env / ambient-env fallbacks (tests).
#
# --list record shape (tab-separated, stable field order):
#   claim<TAB>class<TAB>identifier<TAB>stored<TAB>live<TAB>observed_at<TAB>file:line
#   project<TAB>class<TAB>name<TAB>status<TAB>open_children<TAB>active_children
# `observed_at` is `-` when the claim carried no date.
#
# Exit codes (BOTH modes):
#   0  clean — no mismatch found among the evidence that could be checked
#   1  findings — at least one mismatch or contradiction (advisory WARN)
#   2  skip — could not determine (no lineark / jq / awk / prefix, bulk call
#             failed, unparseable payload, no sources to scan, bad argument).
#             Callers preserve their own score; the reason is named on STDERR
#             in BOTH modes as `SKIP <reason>` so the skip is never anonymous.
set -uo pipefail

LINEARK_BIN="${LINEARK_BIN:-lineark}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MEMORY_DIRS=()
VAULT_DIR=""
PREFIX=""
LIMIT=250
MAX_READS=40
DO_PROJECTS=1
MODE_LIST=0
ISOLATED=0

while [ $# -gt 0 ]; do
  case "$1" in
    # Every value-taking flag guards its argument BEFORE `shift 2` (parity with
    # check-linear-hygiene.sh): a value-less flag would otherwise re-loop on
    # itself forever.
    --memory-dir) [ $# -ge 2 ] || { printf 'check-state-currentness: --memory-dir needs a path\n' >&2; exit 2; }
                  MEMORY_DIRS[${#MEMORY_DIRS[@]}]="$2"; shift 2 ;;
    --vault-dir)  [ $# -ge 2 ] || { printf 'check-state-currentness: --vault-dir needs a path\n' >&2; exit 2; }
                  VAULT_DIR="$2"; shift 2 ;;
    --prefix)     [ $# -ge 2 ] || { printf 'check-state-currentness: --prefix needs a value\n' >&2; exit 2; }
                  PREFIX="$2"; shift 2 ;;
    --limit)      [ $# -ge 2 ] || { printf 'check-state-currentness: --limit needs a value\n' >&2; exit 2; }
                  LIMIT="$2"; shift 2 ;;
    --max-reads)  [ $# -ge 2 ] || { printf 'check-state-currentness: --max-reads needs a value\n' >&2; exit 2; }
                  MAX_READS="$2"; shift 2 ;;
    --no-projects) DO_PROJECTS=0; shift ;;
    --list)       MODE_LIST=1; shift ;;
    --isolated)   ISOLATED=1; shift ;;
    *) printf 'check-state-currentness: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$LIMIT" in ''|*[!0-9]*) printf 'check-state-currentness: --limit must be a non-negative integer\n' >&2; exit 2 ;; esac
case "$MAX_READS" in ''|*[!0-9]*) printf 'check-state-currentness: --max-reads must be a non-negative integer\n' >&2; exit 2 ;; esac

# skip <reason> — emit the reason and exit 2 (indeterminate).
#
# The reason goes to STDERR in BOTH modes, so `--list` stdout stays pure TSV
# while the caller can still report a NAMED skip rather than a bare exit 2. That
# naming is the point: "lineark not found" and "no comparable evidence found"
# are different operator actions, and an unnamed skip collapses them.
skip() {
  printf 'SKIP %s\n' "$1" >&2
  exit 2
}

# _localenv_get <path> <key> — read ONE key from local.env WITHOUT sourcing it.
# Verbatim-equivalent to self-audit.sh's _sa_localenv_get: sourcing would EXECUTE
# an operator file that can carry arbitrary code and could poison the PATH the
# `command -v` lookups below depend on. Reads config as DATA only.
_localenv_get() {
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

# ---- source + prefix resolution (flag > local.env > ambient env) -------------
if [ "$ISOLATED" -eq 0 ]; then
  _lv=""
  if [ -z "$PREFIX" ]; then
    _lv="$(_localenv_get "$REPO_ROOT/local.env" TRACKER_ISSUE_PREFIX)"
    [ -n "$_lv" ] && PREFIX="$_lv"
    [ -z "$PREFIX" ] && PREFIX="${TRACKER_ISSUE_PREFIX:-}"
  fi
  if [ -z "$VAULT_DIR" ]; then
    _lv="$(_localenv_get "$REPO_ROOT/local.env" OBSIDIAN_VAULT_PATH)"
    [ -n "$_lv" ] && VAULT_DIR="$_lv"
    [ -z "$VAULT_DIR" ] && VAULT_DIR="${OBSIDIAN_VAULT_PATH:-}"
  fi
  if [ "${#MEMORY_DIRS[@]}" -eq 0 ]; then
    _cfg="$(_localenv_get "$REPO_ROOT/local.env" CLAUDE_CONFIG_DIR)"
    [ -z "$_cfg" ] && _cfg="${CLAUDE_CONFIG_DIR:-}"
    if [ -n "$_cfg" ] && [ -d "$_cfg/projects" ]; then
      # Every per-project auto-memory store under the harness config dir. A
      # store with no notes is harmless — the scanner just finds no claims.
      while IFS= read -r _d; do
        [ -n "$_d" ] && MEMORY_DIRS[${#MEMORY_DIRS[@]}]="$_d"
      done < <(find "$_cfg/projects" -mindepth 2 -maxdepth 2 -type d -name memory 2>/dev/null | sort)
    fi
  fi
fi

# Strip one trailing slash from directory inputs so joined paths never double up.
VAULT_DIR="${VAULT_DIR%/}"

[ -n "$PREFIX" ] || skip "no tracker issue prefix (--prefix, or TRACKER_ISSUE_PREFIX in local.env) — claim scanning cannot run"
case "$PREFIX" in
  *[!A-Za-z0-9_]*) skip "tracker prefix '$PREFIX' is not alphanumeric — refusing to build a scan pattern from it" ;;
esac

command -v jq   >/dev/null 2>&1 || skip "jq unavailable; cannot parse tracker payloads"
command -v awk  >/dev/null 2>&1 || skip "awk unavailable; cannot scan notes for claims"
command -v "$LINEARK_BIN" >/dev/null 2>&1 || skip "lineark not found (\$LINEARK_BIN or PATH) — see linear/linear-setup.md §3.2"

# ---- collect the files to scan ----------------------------------------------
# Memory stores: every note. Vault: active project notes only (frontmatter
# `status: active`) — an archived or completed project note is a historical
# record by definition and its claims are not present-tense assertions.
SCAN_FILES=()
for _md in ${MEMORY_DIRS[@]+"${MEMORY_DIRS[@]}"}; do
  [ -d "$_md" ] || continue
  while IFS= read -r _f; do
    [ -n "$_f" ] && SCAN_FILES[${#SCAN_FILES[@]}]="$_f"
  done < <(find "$_md" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
done
if [ -n "$VAULT_DIR" ] && [ -d "$VAULT_DIR/01-Projects" ]; then
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    # `status: active` must appear in the frontmatter block, not anywhere in the
    # body — check only the leading block.
    if awk '/^---[[:space:]]*$/{n++; if(n==2) exit} n==1 && tolower($0) ~ /^status:[[:space:]]*active[[:space:]]*$/{found=1} END{exit !found}' "$_f" 2>/dev/null; then
      SCAN_FILES[${#SCAN_FILES[@]}]="$_f"
    fi
  done < <(find "$VAULT_DIR/01-Projects" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
fi

[ "${#SCAN_FILES[@]}" -gt 0 ] || skip "no memory or vault sources to scan (--memory-dir / --vault-dir)"

# ---- live state map ----------------------------------------------------------
# ONE bulk call carries every issue's identifier + state, so the common case
# costs a single request no matter how many claims are scanned.
bulk_json="$("$LINEARK_BIN" issues list --show-done --limit "$LIMIT" --format json 2>/dev/null)" \
  || skip "lineark issues list failed — tracker unreachable or unauthenticated"
printf '%s' "$bulk_json" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || skip "unexpected issues-list payload (not a JSON array)"

bulk_count="$(printf '%s' "$bulk_json" | jq 'length')"
# A payload returned AT the ceiling may be truncated — record it so unmatched
# identifiers fall back to a per-issue read instead of being reported unknown.
possibly_truncated=0
[ "$bulk_count" -ge "$LIMIT" ] && [ "$LIMIT" -gt 0 ] && possibly_truncated=1

# bash 3.2 has no associative arrays: the map is a newline-delimited
# "IDENT<TAB>STATE" table looked up with a fixed-string grep.
STATE_MAP="$(printf '%s' "$bulk_json" | jq -r '
  def s(f): (f // ""
    | if type == "object" then (.name // tostring) else tostring end);
  .[] | select((.identifier // "") != "") | [ s(.identifier), s(.state) ] | @tsv')"

reads=0
# live_state <ident> — echo the live state name, or "" when unknown.
live_state() {
  local ident="$1" hit=""
  hit="$(printf '%s\n' "$STATE_MAP" | grep -F "$(printf '%s\t' "$ident")" | head -n 1)"
  if [ -n "$hit" ]; then
    printf '%s' "${hit#*$'\t'}"
    return 0
  fi
  # Not in the bulk payload. If the payload may have been truncated, spend a
  # read; otherwise the identifier genuinely does not exist in the workspace.
  if [ "$possibly_truncated" -eq 1 ] && [ "$reads" -lt "$MAX_READS" ]; then
    reads=$((reads + 1))
    local rj
    if rj="$("$LINEARK_BIN" issues read "$ident" --format json 2>/dev/null)" \
       && printf '%s' "$rj" | jq -e 'type == "object"' >/dev/null 2>&1; then
      printf '%s' "$(printf '%s' "$rj" | jq -r '(.state // "") | if type == "object" then (.name // "") else tostring end')"
      return 0
    fi
  fi
  printf '%s' ""
}

# ---- claim extraction --------------------------------------------------------
# The scanner emits FILE<TAB>LINE<TAB>IDENT<TAB>CLAIMED<TAB>OBSERVED_AT.
#
# PROXIMITY IN PROSE IS NOT A CLAIM. The first cut of this scanner assigned a
# state to any identifier that merely shared a line with a state word, and the
# live corpus buried it in false positives: "mixes effective and cancelled
# actions" made an issue Canceled; a frontmatter headline whose "In Progress"
# described the PROJECT was pinned onto all seven issues it went on to list;
# "Phase 2 exits only after all four child issues are Done" — a future
# CONDITION — read as a present assertion. Every one of those is a state word
# within a few words of an identifier, and every one is noise.
#
# So the scanner recognizes only the shapes a genuine state claim actually
# takes in this corpus, and treats everything else as prose:
#
#   A. TIGHT ADJACENCY (the primary rule). The state word must appear in the
#      window immediately after the identifier, within ADJ_MAX characters, and
#      everything between the identifier and the state word must be "light" —
#      punctuation, emphasis marks, one parenthetical, or a copula
#      (is/was/are/remains/stays/now/->). A full clause of prose in between
#      means the state word belongs to the sentence, not to the identifier.
#        matches: "TEAM-1 — Backlog (High):"  "TEAM-2 (memory consolidation) Done"
#                 "TEAM-3 is Done"  "TEAM-4 remains Backlog"
#        rejects: "The disposable TEAM-5 runtime proof then passed on Postgres"
#
#   B. LABEL LEAD. A SHORT state label ending in a colon at the head of the line
#      ("**Done:** TEAM-1 …; TEAM-2 …") distributes to identifiers that rule A did
#      not resolve. Bounded to LEAD_MAX characters and required to be
#      substantially just the state word — so a sentence that happens to end in
#      a colon cannot distribute its verb across a list.
#
#   C. CONJUNCTION INHERITANCE. "TEAM-1 and TEAM-2 remain Backlog" — an identifier
#      separated from the next only by conjunction/punctuation inherits that
#      neighbor's rule-A state.
#
# Anything unresolved yields NO claim. Under-reporting is the deliberate bias.
scan_claims() {
  awk -v prefix="$PREFIX" '
    function lc(s) { return tolower(s) }
    BEGIN {
      idre = prefix "-[0-9]+"
      ADJ_MAX = 44       # chars after an identifier that can still carry its state
      LEAD_MAX = 34      # max length of a distributing "State:" label
      fence = 0; section = ""; secdate = ""
      # A light connector: what may sit between an identifier and its state word.
      LIGHT = "^[[:space:]*_`:;,.=—–>-]*((is|was|are|were|remains|remain|stays|stay|now|moved|set)[[:space:]]+(to[[:space:]]+)?)?[[:space:]*_`:;,.=—–>-]*$"
    }
    # canonical state named at the START of a window, else ""
    function state_at(w,   t) {
      t = lc(w)
      if (t ~ /^in[ _-]progress([^a-z]|$)/)                  return "In Progress"
      if (t ~ /^in[ _-]review([^a-z]|$)/)                    return "In Review"
      if (t ~ /^backlog([^a-z]|$)/)                          return "Backlog"
      if (t ~ /^to[ _-]?do([^a-z]|$)/)                       return "Todo"
      if (t ~ /^cancell?ed([^a-z]|$)/)                       return "Canceled"
      if (t ~ /^(done|completed|complete|closed)([^a-z]|$)/) return "Done"
      if (t ~ /^(still[ ]+open|remains[ ]+open|open|outstanding|unresolved|blocked)([^a-z]|$)/) return "OPEN"
      return ""
    }
    # Rule A: scan the window for a state word reachable through light text only.
    function adjacent_state(win,   w, k, pre, st, stripped) {
      w = substr(win, 1, ADJ_MAX)
      # Strip ONE leading parenthetical ("(memory-store consolidation) Done").
      if (match(w, /^[[:space:]]*\([^)]*\)/)) {
        stripped = substr(w, RLENGTH + 1)
        st = adjacent_state_raw(stripped)
        if (st != "") return st
      }
      return adjacent_state_raw(w)
    }
    function adjacent_state_raw(w,   k, pre, st) {
      for (k = 1; k <= length(w); k++) {
        st = state_at(substr(w, k))
        if (st == "") continue
        pre = substr(w, 1, k - 1)
        if (pre ~ LIGHT) return st
        return ""      # a state word exists but prose separates it — not a claim
      }
      return ""
    }
    # Rule B: is the lead a short, bare "State:" label?
    function label_state(lead,   t, st) {
      t = lead
      sub(/^[[:space:]*_>#-]+/, "", t)
      if (length(t) > LEAD_MAX) return ""
      if (t !~ /:[[:space:]*_]*$/) return ""
      st = state_at(t)
      if (st == "") return ""
      # Require the label to be essentially just the state word + colon.
      gsub(/[[:space:]*_`:-]/, "", t)
      if (length(t) > 12) return ""
      return st
    }
    function is_conjunction(w,   t) {
      t = lc(w); gsub(/[[:space:],;\/&*_`()-]|and|plus|through|thru|then/, "", t)
      return (t == "")
    }
    function date_in(s) {
      if (match(s, /20[0-9][0-9]-[01][0-9]-[0-3][0-9]/)) return substr(s, RSTART, RLENGTH)
      return ""
    }
    # Fenced code is documentation of syntax, never a state claim.
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^#{1,6}[[:space:]]/ {
      section = lc($0)
      # A heading date only dates the claims beneath it when the heading
      # explicitly frames a snapshot; an incidental date in a title does not.
      secdate = (section ~ /as of|verified|snapshot|state at/) ? date_in($0) : ""
    }
    {
      # History LOGS record what was true then; they are not present claims.
      if (section ~ /state[ -]delta/ || section ~ /audit log/ || section ~ /changelog/ || section ~ /^#+[[:space:]]*history/) next

      line = $0
      n = 0; rest = line; base = 0
      while (match(rest, idre)) {
        n++
        ids[n] = substr(rest, RSTART, RLENGTH)
        pos[n] = base + RSTART
        len[n] = RLENGTH
        base += RSTART + RLENGTH - 1
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (n == 0) next

      dflt = label_state(substr(line, 1, pos[1] - 1))

      obs = ""
      if (line ~ /(as of|verified|snapshot|confirmed)/) obs = date_in(line)
      if (obs == "") obs = secdate

      for (i = 1; i <= n; i++) {
        wstart = pos[i] + len[i]
        wend = (i < n) ? pos[i+1] - 1 : length(line)
        win = (wend >= wstart) ? substr(line, wstart, wend - wstart + 1) : ""
        st = adjacent_state(win)
        if (st == "" && dflt != "") st = dflt
        if (st == "" && i < n && is_conjunction(win)) {
          for (j = i + 1; j <= n; j++) {
            js = pos[j] + len[j]
            je = (j < n) ? pos[j+1] - 1 : length(line)
            jw = (je >= js) ? substr(line, js, je - js + 1) : ""
            fs = adjacent_state(jw)
            if (fs != "") { st = fs; break }
            if (!is_conjunction(jw)) break
          }
        }
        if (st == "") continue
        printf "%s\t%d\t%s\t%s\t%s\n", FILENAME, FNR, ids[i], st, (obs == "" ? "-" : obs)
      }
    }
  ' "$@"
}

# ---- compare -----------------------------------------------------------------
findings=0
stale_claims=0
stale_snapshots=0
unknown_idents=""
checked_claims=0

# mismatch <claimed> <live> — 0 when the pair contradicts, 1 when consistent.
mismatch() {
  local claimed="$1" live="$2"
  case "$claimed" in
    OPEN)  case "$live" in Done|Canceled) return 0 ;; *) return 1 ;; esac ;;
    Done)  [ "$live" = "Done" ] && return 1 || return 0 ;;
    Canceled) [ "$live" = "Canceled" ] && return 1 || return 0 ;;
    *)     [ "$live" = "$claimed" ] && return 1 || return 0 ;;
  esac
}

while IFS=$'\t' read -r cfile cline cident cclaim cobs; do
  [ -n "${cident:-}" ] || continue
  live="$(live_state "$cident")"
  if [ -z "$live" ]; then
    case "$unknown_idents" in
      *" $cident "*) : ;;
      *) unknown_idents="$unknown_idents $cident " ;;
    esac
    continue
  fi
  checked_claims=$((checked_claims + 1))
  if mismatch "$cclaim" "$live"; then
    if [ "$cobs" = "-" ]; then
      klass="stale-claim"; stale_claims=$((stale_claims + 1))
    else
      klass="stale-snapshot"; stale_snapshots=$((stale_snapshots + 1))
    fi
    findings=$((findings + 1))
    if [ "$MODE_LIST" -eq 1 ]; then
      printf 'claim\t%s\t%s\t%s\t%s\t%s\t%s:%s\n' \
        "$klass" "$cident" "$cclaim" "$live" "$cobs" "$cfile" "$cline"
    else
      printf 'WARN %s %s: note says "%s", tracker says "%s" (as-of %s) — %s:%s\n' \
        "$klass" "$cident" "$cclaim" "$live" "$cobs" "$cfile" "$cline"
    fi
  fi
done < <(scan_claims "${SCAN_FILES[@]}")

# ---- project / child contradictions -----------------------------------------
projects_checked=0
projects_skipped=""
if [ "$DO_PROJECTS" -eq 1 ]; then
  pj="$("$LINEARK_BIN" projects list --format json 2>/dev/null || true)"
  if printf '%s' "$pj" | jq -e 'type == "array"' >/dev/null 2>&1; then
    while IFS=$'\t' read -r pid pname; do
      [ -n "${pid:-}" ] || continue
      if [ "$reads" -ge "$MAX_READS" ]; then
        projects_skipped="$projects_skipped $pname;"
        continue
      fi
      reads=$((reads + 1))
      prj="$("$LINEARK_BIN" projects read "$pid" --format json 2>/dev/null || true)"
      printf '%s' "$prj" | jq -e 'type == "object"' >/dev/null 2>&1 || { projects_skipped="$projects_skipped $pname;"; continue; }
      pstatus="$(printf '%s' "$prj" | jq -r '(.status // "") | if type == "object" then (.name // "") else tostring end')"
      [ -n "$pstatus" ] || { projects_skipped="$projects_skipped $pname;"; continue; }

      if [ "$reads" -ge "$MAX_READS" ]; then
        projects_skipped="$projects_skipped $pname;"
        continue
      fi
      reads=$((reads + 1))
      # Default list scope hides Done/Canceled, so this IS the open-issue cut.
      pij="$("$LINEARK_BIN" issues list --project "$pid" --limit "$LIMIT" --format json 2>/dev/null || true)"
      printf '%s' "$pij" | jq -e 'type == "array"' >/dev/null 2>&1 || { projects_skipped="$projects_skipped $pname;"; continue; }
      open_n="$(printf '%s' "$pij" | jq 'length')"
      active_n="$(printf '%s' "$pij" | jq '[ .[] | ((.state // "") | if type == "object" then (.name // "") else tostring end) | select(. == "In Progress" or . == "In Review") ] | length')"
      projects_checked=$((projects_checked + 1))

      pclass=""
      case "$pstatus" in
        Completed|Canceled) [ "$open_n" -gt 0 ] && pclass="project-closed-with-open-children" ;;
        Backlog|Planned)    [ "$active_n" -gt 0 ] && pclass="project-idle-with-active-children" ;;
        "In Progress")      [ "$open_n" -eq 0 ] && pclass="project-active-with-no-open-children" ;;
      esac
      [ -n "$pclass" ] || continue
      findings=$((findings + 1))
      if [ "$MODE_LIST" -eq 1 ]; then
        printf 'project\t%s\t%s\t%s\t%s\t%s\n' "$pclass" "$pname" "$pstatus" "$open_n" "$active_n"
      else
        printf 'WARN %s "%s": status "%s" with %s open child issue(s), %s active\n' \
          "$pclass" "$pname" "$pstatus" "$open_n" "$active_n"
      fi
    done < <(printf '%s' "$pj" | jq -r '.[] | select((.id // "") != "") | [ .id, (.name // "-") ] | @tsv')
  else
    projects_skipped=" (projects list failed);"
  fi
fi

# ---- verdict -----------------------------------------------------------------
# Never let an empty scan read as a clean bill of health: if not a single claim
# could be compared and no project was evaluated, there is no evidence at all.
if [ "$checked_claims" -eq 0 ] && [ "$projects_checked" -eq 0 ]; then
  skip "no comparable evidence found (0 claims matched a live issue, 0 projects evaluated) — check --prefix and the scanned sources"
fi

if [ "$MODE_LIST" -eq 0 ]; then
  [ -n "$unknown_idents" ] && \
    printf 'NOTE identifier(s) named in notes but absent from the tracker payload:%s\n' "$unknown_idents"
  [ -n "$projects_skipped" ] && \
    printf 'NOTE project(s) not evaluated (read cap --max-reads=%s, or a failed read):%s\n' "$MAX_READS" "$projects_skipped"
fi

if [ "$findings" -eq 0 ]; then
  [ "$MODE_LIST" -eq 1 ] || printf 'PASS %s claim(s) and %s project(s) agree with live tracker state\n' \
    "$checked_claims" "$projects_checked"
  exit 0
fi

[ "$MODE_LIST" -eq 1 ] || printf 'SUMMARY %s finding(s): %s stale claim(s), %s stale snapshot(s), across %s compared claim(s) and %s project(s) — advisory; reconcile the note or the tracker\n' \
  "$findings" "$stale_claims" "$stale_snapshots" "$checked_claims" "$projects_checked"
exit 1
