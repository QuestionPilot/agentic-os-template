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
# Requires the schpet/linear-cli `linear` binary (linear/linear-setup.md §3.2),
# jq, and awk. Override the binary with $LINEAR_CLI_BIN — the hermetic tests
# inject a stub that serves fixture JSON, so this check is testable without
# live credentials. $LINEARK_BIN is still accepted as a deprecated fallback.
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
#   --limit <n>       max issues pulled in the bulk state-map call (default
#                     250). A payload that comes back
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
#   2  skip — could not determine (no linear CLI / jq / awk / prefix, bulk call
#             failed, unparseable payload, no sources to scan, bad argument).
#             Callers preserve their own score; the reason is named on STDERR
#             in BOTH modes as `SKIP <reason>` so the skip is never anonymous.
set -uo pipefail

# Binary seam. Precedence: $LINEAR_CLI_BIN, then $LINEARK_BIN (deprecated —
# accepted for one transition release), then `linear` on PATH.
LINEAR_CLI_BIN="${LINEAR_CLI_BIN:-${LINEARK_BIN:-linear}}"
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
# naming is the point: "linear CLI not found" and "no comparable evidence found"
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
      done < <(find "$_cfg/projects" -mindepth 2 -maxdepth 2 -type d -name memory 2>/dev/null | LC_ALL=C sort)
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

# jqr — jq -r with CRLF normalization (parity with check-drift.sh): a
# Windows-built jq emits \r\n line endings, and command substitution strips
# only TRAILING \r — every interior line of a multi-line capture keeps its \r.
# Unstripped, STATE_MAP's interior rows ride the awk exact-key lookup as
# "Done\r" != "Done" (phantom stale-claims), and captured counts fail integer
# tests. jq's exit status survives the tr stage: set -o pipefail is active.
jqr() { jq -r "$@" | tr -d '\r'; }
command -v awk  >/dev/null 2>&1 || skip "awk unavailable; cannot scan notes for claims"
command -v "$LINEAR_CLI_BIN" >/dev/null 2>&1 || skip "linear CLI not found (\$LINEAR_CLI_BIN or PATH) — see linear/linear-setup.md §3.2"

# ---- collect the files to scan ----------------------------------------------
# Memory stores: every note. Vault: active project notes only (frontmatter
# `status: active`) — an archived or completed project note is a historical
# record by definition and its claims are not present-tense assertions.
SCAN_FILES=()
for _md in ${MEMORY_DIRS[@]+"${MEMORY_DIRS[@]}"}; do
  [ -d "$_md" ] || continue
  while IFS= read -r _f; do
    [ -n "$_f" ] && SCAN_FILES[${#SCAN_FILES[@]}]="$_f"
  done < <(find "$_md" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
done
if [ -n "$VAULT_DIR" ] && [ -d "$VAULT_DIR/01-Projects" ]; then
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    # `status: active` must appear in the frontmatter block, not anywhere in the
    # body — check only the leading block.
    if LC_ALL=C awk '/^---[[:space:]]*$/{n++; if(n==2) exit} n==1 && tolower($0) ~ /^status:[[:space:]]*active[[:space:]]*$/{found=1} END{exit !found}' "$_f" 2>/dev/null; then
      SCAN_FILES[${#SCAN_FILES[@]}]="$_f"
    fi
  done < <(find "$VAULT_DIR/01-Projects" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
fi

[ "${#SCAN_FILES[@]}" -gt 0 ] || skip "no memory or vault sources to scan (--memory-dir / --vault-dir)"

# ---- live state map ----------------------------------------------------------
# ONE bulk call carries every issue's identifier + state, so the common case
# costs a single request no matter how many claims are scanned.
#
# schpet/linear-cli returns ALL states (incl. Done/Canceled) by DEFAULT — there
# is no --show-done analogue and none is needed; do NOT add open-state filters
# here or the state map loses exactly the closed issues stale claims point at.
# List payloads are objects {nodes:[...]} — unwrap .nodes; a bare array is
# accepted too; any other shape means the call failed.
bulk_raw="$("$LINEAR_CLI_BIN" issue query --all-teams --limit "$LIMIT" --json 2>/dev/null)" \
  || skip "linear CLI issue query failed — tracker unreachable or unauthenticated"
bulk_json="$(printf '%s' "$bulk_raw" | jq -c 'if type == "object" then (.nodes // null) elif type == "array" then . else null end' 2>/dev/null)"
printf '%s' "$bulk_json" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || skip "unexpected issue-query payload (neither {nodes:[...]} nor a JSON array)"

bulk_count="$(printf '%s' "$bulk_json" | jqr 'length')"
# A payload returned AT the ceiling may be truncated — record it so unmatched
# identifiers fall back to a per-issue read instead of being reported unknown.
possibly_truncated=0
[ "$bulk_count" -ge "$LIMIT" ] && [ "$LIMIT" -gt 0 ] && possibly_truncated=1

# bash 3.2 has no associative arrays: the map is a newline-delimited
# "IDENT<TAB>STATE" table looked up with a fixed-string grep.
STATE_MAP="$(printf '%s' "$bulk_json" | jqr '
  def s(f): (f // ""
    | if type == "object" then (.name // tostring) else tostring end);
  .[] | select((.identifier // "") != "") | [ s(.identifier), s(.state) ] | @tsv')"

# The read budget is FILE-BACKED, not a shell variable. live_state is invoked as
# `live="$(live_state "$id")"` — a command substitution, i.e. a SUBSHELL — so a
# plain `reads=$((reads+1))` inside it is discarded when the subshell exits and
# the cap silently stops applying (measured: 5 reads under --max-reads 1, while
# the PowerShell twin correctly made 1). A file survives the subshell, keeps the
# twins' call counts identical, and keeps the cap meaningful.
READS_FILE="$(mktemp)"
printf '0' > "$READS_FILE"
trap 'rm -f "$READS_FILE"' EXIT
reads_get() { cat "$READS_FILE" 2>/dev/null || printf '0'; }
reads_inc() { printf '%s' "$(( $(reads_get) + 1 ))" > "$READS_FILE"; }

# live_state <ident> — echo the live state name, or "" when unknown.
live_state() {
  local ident="$1" hit=""
  # Field-exact match, NOT a substring grep: `grep -F "ABC-1<TAB>"` also matches
  # a row for `XABC-1`, so an overlapping team prefix would compare a claim
  # against the wrong issue — while the PS twin's hashtable lookup requires an
  # exact key. awk `$1==id` is the exact-key equivalent.
  hit="$(printf '%s\n' "$STATE_MAP" | LC_ALL=C awk -F'\t' -v id="$ident" '$1 == id { print $2; exit }')"
  if [ -n "$hit" ]; then
    printf '%s' "$hit"
    return 0
  fi
  # Not in the bulk payload. If the payload may have been truncated, spend a
  # read; otherwise the identifier genuinely does not exist in the workspace.
  if [ "$possibly_truncated" -eq 1 ] && [ "$(reads_get)" -lt "$MAX_READS" ]; then
    reads_inc
    local rj
    # `issue view` returns a single OBJECT (not nodes-wrapped); its state is an
    # object {name,type,...} which the jq below flattens to the name.
    if rj="$("$LINEAR_CLI_BIN" issue view "$ident" --json 2>/dev/null)" \
       && printf '%s' "$rj" | jq -e 'type == "object"' >/dev/null 2>&1; then
      printf '%s' "$(printf '%s' "$rj" | jqr '(.state // "") | if type == "object" then (.name // "") else tostring end')"
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
#
# LC_ALL=C is load-bearing, not decoration. This program is deliberately BYTE-
# oriented: it normalizes NBSP by its UTF-8 bytes and its LIGHT/HEAVY connector
# classes carry literal em/en dashes inside bracket expressions. Under a UTF-8
# locale BSD awk switches those bracket expressions to character semantics, the
# dashes and the NBSP stop matching, and every claim whose identifier is
# separated from its state word by a multibyte character silently vanishes —
# the scanner reports "no comparable evidence" instead of a finding. That is a
# false-clean on the exact notes this gate exists to police, and it reproduces
# only when the CALLER exports a UTF-8 locale, so a C-locale test run is green
# either way. Pinning the locale at the call site makes the byte assumption
# true everywhere instead of true by accident.
scan_claims() {
  LC_ALL=C awk -v prefix="$PREFIX" '
    function lc(s) { return tolower(s) }
    BEGIN {
      idre = prefix "-[0-9]+"
      ADJ_MAX = 44       # chars after an identifier that can still carry its state
      LEAD_MAX = 34      # max length of a distributing "State:" label
      fence = 0; section = ""; secdate = ""
      # A light connector: what may sit between an identifier and its state word.
      # The optional ADVERB slot after the copula is load-bearing — without it
      # "ABC-1 is now Done" and "ABC-1 is currently Done" (both ordinary
      # phrasings) resolve to NO claim, which is a silent miss, not restraint.
      # The perfect auxiliary ("has been closed") is a separate alternative from
      # the plain copula ("is closed") — both are ordinary ways to assert state.
      LIGHT = "^[[:space:]*_`:;,.=—–>-]*((((has|have|had)[[:space:]]+been)|(is|was|are|were|remains|remain|stays|stay|now|moved|set))[[:space:]]+((now|currently|still|already|again)[[:space:]]+)?((moved|set|changed|switched|flipped)[[:space:]]+)?(to[[:space:]]+)?)?[[:space:]*_`:;,.=—–>-]*$"
      # A state word FOLLOWED BY one of these is not a state assertion but the
      # head of a longer phrase: a deadline ("Done by Friday"), a condition
      # ("Done when the memo lands"), or a noun compound ("open questions",
      # "done criteria"). Without this, Rule A fires on any identifier trailed
      # by a bare state word in ordinary prose.
      STATEALT = "(in[ _-]progress|in[ _-]review|backlog|to[ _-]?do|cancell?ed|completed|complete|closed|done|still[[:space:]]+open|remains[[:space:]]+open|outstanding|unresolved|blocked|open)"
      NOTSTATE = "^" STATEALT "[[:space:]]+(by|until|till|when|after|before|once|unless|if|for|to|as|about|regarding|criteria|questions?|items?|tasks?|work|list|state|status|column|label|issues?)([^a-z]|$)"
      # Same token set with the separators already stripped — Rule B compares
      # against this AFTER collapsing punctuation out of the label.
      STATEBARE = "^(inprogress|inreview|backlog|todo|cancell?ed|completed|complete|closed|done|stillopen|remainsopen|outstanding|unresolved|blocked|open)$"
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
        if (pre !~ LIGHT) return ""   # a state word exists but prose separates it
        # The state word is adjacent — but is it the CLAIM, or the head of a
        # longer phrase? "Done by Friday" / "open questions" are not states.
        if (lc(substr(w, k)) ~ NOTSTATE) return ""
        return st
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
      # The label must be the state word and NOTHING else. A length budget is
      # not enough: "Done except:" strips to "Doneexcept" (10 chars) and used to
      # distribute a Done claim across every identifier on the line — the exact
      # inversion of what the label means. Compare against the canonical token
      # set instead of counting characters.
      gsub(/[[:space:]*_`:-]/, "", t)
      return (lc(t) ~ STATEBARE) ? st : ""
    }
    function is_conjunction(w,   t) {
      t = lc(w); gsub(/[[:space:],;\/&*_`()-]|and|plus|through|thru|then/, "", t)
      return (t == "")
    }
    function date_in(s) {
      if (match(s, /20[0-9][0-9]-[01][0-9]-[0-3][0-9]/)) return substr(s, RSTART, RLENGTH)
      return ""
    }
    # One awk invocation scans EVERY file, so per-file state must reset at each
    # file boundary — a note ending inside a history section (or an unclosed
    # fence) must not suppress the next note. The PS twin resets per file by
    # construction (Get-Claims is called once per path).
    FNR == 1 { fence = 0; section = ""; secdate = "" }
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
      # NBSP -> space. The awk [[:space:]] class is ASCII-only under the C
      # locale while the PS twin \s matches U+00A0, so an editor-inserted
      # non-breaking space made the twins disagree. Normalizing on BOTH sides
      # fixes the divergence in the direction that keeps the claim visible.
      # (No apostrophes in this awk program — it is single-quoted in bash.)
      gsub(/\xc2\xa0/, " ", line)

      # A DATE-LED line is a log entry, not a present-tense assertion — the
      # `- 2026-08-04 (…): TEAM-1 was In Progress` shape that closeout writes.
      # Section-level history detection only covers it when the writer used a
      # recognized heading; this covers the bullet wherever it lands.
      if (line ~ /^[[:space:]*_>#-]*20[0-9][0-9]-[01][0-9]-[0-3][0-9]/) next
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
  pj_raw="$("$LINEAR_CLI_BIN" project list --json 2>/dev/null || true)"
  pj="$(printf '%s' "$pj_raw" | jq -c 'if type == "object" then (.nodes // null) elif type == "array" then . else null end' 2>/dev/null)"
  if printf '%s' "$pj" | jq -e 'type == "array"' >/dev/null 2>&1; then
    # Project state rides the list payload in schpet/linear-cli (each row carries
    # a status object) — the per-project read lineark needed is gone.
    while IFS=$'\t' read -r pid pname pstatus; do
      [ -n "${pid:-}" ] || continue
      # jq on Windows writes CRLF, and `read` leaves the \r on the LAST TSV
      # field. The lineark-era code took pstatus through a command substitution
      # (which Git Bash CR-strips); this TSV read must strip it explicitly or
      # every status silently fails the case match below on Windows.
      pstatus="${pstatus%$'\r'}"
      [ -n "${pstatus:-}" ] || { projects_skipped="$projects_skipped $pname;"; continue; }

      if [ "$(reads_get)" -ge "$MAX_READS" ]; then
        projects_skipped="$projects_skipped $pname;"
        continue
      fi
      reads_inc
      # schpet/linear-cli has no hiding default — the open-issue cut must be
      # EXPLICIT via the open state types, so this IS the open-issue cut.
      pij_raw="$("$LINEAR_CLI_BIN" issue query --all-teams --project "$pid" -s triage -s backlog -s unstarted -s started --limit "$LIMIT" --json 2>/dev/null || true)"
      pij="$(printf '%s' "$pij_raw" | jq -c 'if type == "object" then (.nodes // null) elif type == "array" then . else null end' 2>/dev/null)"
      printf '%s' "$pij" | jq -e 'type == "array"' >/dev/null 2>&1 || { projects_skipped="$projects_skipped $pname;"; continue; }
      open_n="$(printf '%s' "$pij" | jqr 'length')"
      # A child list returned AT the ceiling may be truncated, and every class
      # below is a statement about the WHOLE child set — an active child on page
      # two would silently produce "PASS ... projects agree". Unknown evidence is
      # a skip, never a pass.
      if [ "$LIMIT" -gt 0 ] && [ "$open_n" -ge "$LIMIT" ]; then
        projects_skipped="$projects_skipped $pname (child list may be truncated at --limit=$LIMIT);"
        continue
      fi
      active_n="$(printf '%s' "$pij" | jqr '[ .[] | ((.state // "") | if type == "object" then (.name // "") else tostring end) | select(. == "In Progress" or . == "In Review") ] | length')"
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
    done < <(printf '%s' "$pj" | jq -r '.[] | select((.id // "") != "") | [ .id, (.name // "-"), ((.status // "") | if type == "object" then (.name // "") else tostring end) ] | @tsv')
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
