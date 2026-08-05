#!/usr/bin/env bash
# scripts/orient.sh — deterministic ORIENTATION helper.
#
# session-agent's Mode 1 kickoff collects the same tracker + memory state every
# session, by hand, through a different sequence of ad-hoc CLI calls each time.
# That is the expensive half of the spine: the call order drifts, a surface that
# is down gets narrated instead of named, and the model spends context deciding
# HOW to look rather than reading what it found. This script does the collection
# once, deterministically, and emits ONE compact JSON document the caller reads.
#
# What it emits (schema id `orient/v1`, top-level keys in stable order):
#
#   schema                   "orient/v1"
#   surfaces                 per-surface reachability: linear + memory, each
#                            {status: ok|absent|error, detail: "<human>"}
#   projects                 project-first cut: [{id, name, slug_id,
#                            open_issues: [issue…]}] — one issues-list call per
#                            project, in tracker order
#   projectless_open_issues  open issues in the GLOBAL sweep that appear in no
#                            project's list (identifier set difference) — the
#                            reconciliation cut that a projects-only orient
#                            silently drops. Emitted as [] with a
#                            "reconciliation unavailable" degraded entry when the
#                            project cut is INCOMPLETE (see below)
#   mine_in_progress         assigned-to-me AND In Progress
#   anomalies                [{type, subject, detail}] — see below
#   memory_pointers          project-type memory notes: [{file, name, description}]
#   degraded                 named degraded surfaces, e.g.
#                            "linear: lineark not on PATH (lineark)"
#
# An `issue` is normalized to {identifier, title, state, priority, assignee, url}.
#
# ANOMALY CLASSES. `project-idle-with-active-children` is NOT detectable here:
# `lineark projects list` carries no project state field (verified — it returns
# {id, name, slug_id, lead}), and paying a `projects read` per project to get one
# is check-state-currentness.sh's job, not a kickoff helper's. The two classes a
# single-pass sweep CAN decide:
#   all-issues-backlog-no-assignee  every open issue in a project is Backlog with
#                                   no assignee — a project nobody is on
#   open-issue-count-mismatch       an identifier appears under a project but not
#                                   in the global open sweep, so the two cuts
#                                   disagree about what is open (a truncated
#                                   sweep, or a scope filter that dropped it)
#
# RECONCILIATION INTEGRITY. The projectless cut is a set difference against the
# union of the per-project lists, so it is only meaningful when that union is
# COMPLETE. If the projects list failed, or ANY per-project issues call failed,
# the union is short by exactly the rows that are missing — and the difference
# would name real, correctly-filed issues as projectless while raising an
# open-issue-count-mismatch anomaly from the same hole. In that case the helper
# emits `projectless_open_issues: []`, adds the degraded entry
# "linear: reconciliation unavailable — incomplete project cut", and SUPPRESSES
# the count-mismatch anomaly for that run. A fully absent linear surface is not
# this case: every input is [] and the difference is honestly [].
#
# DEGRADES, NEVER FAILS. A missing or erroring surface produces empty arrays, a
# named `degraded` entry, and STILL a valid `orient/v1` document on exit 0 — the
# caller must be able to parse one shape no matter what is down. A non-zero exit
# means the script itself could not run (bad argument, jq missing), never that a
# surface was unreachable.
#
# Tracker access is the `lineark` CLI ONLY (linear/linear-setup.md §3.2) — no
# MCP. Override the binary with --lineark or $LINEARK_BIN; the hermetic tests
# inject a stub serving fixture JSON, so this runs without live credentials.
#
# Response shapes handled (verified against lineark, not assumed):
#   projects list  -> [{id, name, slug_id, lead}]           NO state field
#   issues list    -> [{identifier, …, state: "Backlog"}]   state is a BARE STRING,
#                                                           Done/Canceled hidden
#   issues read    -> {…, state: {id, name}}                state is an OBJECT
# Every state read goes through one normalizer that accepts either shape, so
# nothing here calls `.state.name` on list output.
#
# Usage:
#   orient.sh [--memory-dir <path>] [--lineark <bin>] [--pretty]
#
#   --memory-dir <path>  memory store to scan for project-type notes (a single
#                        store; omit to skip the memory surface).
#   --lineark <bin>      tracker CLI to invoke (default $LINEARK_BIN, else
#                        `lineark`). Test-injection seam.
#   --pretty             indent the JSON (default: one compact line).
#
# Exit codes:
#   0  a valid orient/v1 document was emitted (degraded or not)
#   2  the script could not run: bad argument, or jq unavailable
set -uo pipefail

LINEARK_BIN="${LINEARK_BIN:-lineark}"
MEMORY_DIR=""
PRETTY=0
# lineark's documented ceiling. Not a flag: a kickoff sweep that needs paging is
# a different problem than this helper solves, and the count-mismatch anomaly
# surfaces the truncation rather than hiding it.
LIMIT=250

die() { printf 'orient: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    # Every value-taking flag guards its argument BEFORE `shift 2` (house
    # pattern, check-state-currentness.sh): a value-less flag would otherwise
    # re-loop on itself forever.
    --memory-dir) [ $# -ge 2 ] || die "--memory-dir needs a path"; MEMORY_DIR="$2"; shift 2 ;;
    --lineark)    [ $# -ge 2 ] || die "--lineark needs a path"; LINEARK_BIN="$2"; shift 2 ;;
    --pretty)     PRETTY=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq unavailable; cannot assemble the orient document"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DEGRADED="$WORK/degraded"; : > "$DEGRADED"
ANOMALIES="$WORK/anomalies.jsonl"; : > "$ANOMALIES"
PROJECTS_OUT="$WORK/projects.jsonl"; : > "$PROJECTS_OUT"
MEM_OUT="$WORK/memory.jsonl"; : > "$MEM_OUT"
PROJ_IDS="$WORK/proj.ids"; : > "$PROJ_IDS"

degrade() { printf '%s\n' "$1" >> "$DEGRADED"; }
anomaly() { jq -nc --arg t "$1" --arg s "$2" --arg d "$3" '{type:$t,subject:$s,detail:$d}' >> "$ANOMALIES"; }

# The ONE state/field normalizer. `state` arrives as a bare string from
# `issues list` and as an object from `issues read`; `priority` and `assignee`
# can be absent or null. Everything downstream consumes this shape only.
#
# `rows` is the ONE entry point for turning a tracker payload into issue rows: it
# drops any element that is not an OBJECT before normalizing. lk() validates only
# that the payload is a top-level ARRAY, so a well-formed-but-wrong body like
# `["unexpected"]` reaches these filters; `.identifier` on a string is a jq HARD
# ERROR, which used to leave the downstream file empty and the emitted key null
# (an invalid orient/v1 document on exit 0). Skipping non-objects keeps every
# array-typed key an array no matter what the tracker answers with.
ISSUE_DEF='def flat(f): (f // "" | if type == "object" then (.name // "") else tostring end);
def objs: map(select(type == "object"));
def issue: {
  identifier: flat(.identifier),
  title:      flat(.title),
  state:      flat(.state),
  priority:   flat(.priority),
  assignee:   flat(.assignee),
  url:        flat(.url)
};
def rows: objs | map(issue);'

# lk <outfile> <lineark args…> — run the tracker CLI, require a JSON ARRAY back.
# A non-zero exit, an exec failure, or a non-array payload are all one thing to
# the caller: this cut is unavailable.
lk() {
  local out="$1"; shift
  "$LINEARK_BIN" "$@" --format json > "$out" 2>/dev/null || return 1
  jq -e 'type == "array"' "$out" >/dev/null 2>&1 || return 1
  return 0
}

# ---- linear surface ----------------------------------------------------------
LINEAR_STATUS="ok"
LINEAR_DETAIL=""
# Set when the PROJECT CUT itself is incomplete — the projects list failed, or any
# per-project issues call failed. The reconciliation below is a SET DIFFERENCE
# against the project union: computing it from a short union manufactures a
# projectless list and a count-mismatch anomaly out of the same missing data. See
# the reconciliation block.
PROJECT_CUT_INCOMPLETE=0
printf '[]' > "$WORK/projects.json"
printf '[]' > "$WORK/global.json"
printf '[]' > "$WORK/mine.json"

if ! command -v "$LINEARK_BIN" >/dev/null 2>&1; then
  LINEAR_STATUS="absent"
  LINEAR_DETAIL="lineark not found (--lineark or PATH): $LINEARK_BIN — see linear/linear-setup.md §3.2"
  degrade "linear: lineark not on PATH ($LINEARK_BIN)"
else
  linear_errs=0

  if ! lk "$WORK/projects.json" projects list; then
    printf '[]' > "$WORK/projects.json"
    linear_errs=1
    PROJECT_CUT_INCOMPLETE=1
    degrade "linear: projects list failed"
  fi
  if ! lk "$WORK/global.json" issues list --limit "$LIMIT"; then
    printf '[]' > "$WORK/global.json"
    linear_errs=1
    # A failed GLOBAL sweep breaks reconciliation the same way a failed project
    # cut does: every project-listed identifier would surface as a phantom
    # count-mismatch against the empty sweep.
    PROJECT_CUT_INCOMPLETE=1
    degrade "linear: global issues list failed"
  fi
  if ! lk "$WORK/mine.json" issues list --mine --limit "$LIMIT"; then
    printf '[]' > "$WORK/mine.json"
    linear_errs=1
    degrade "linear: issues list --mine failed"
  fi

  # Project-first cut: one issues-list call per project, in tracker order.
  pn=0
  while IFS=$'\t' read -r pid pname pslug; do
    [ -n "${pid:-}" ] || continue
    pn=$((pn + 1))
    pf="$WORK/pi-$pn.json"
    if ! lk "$pf" issues list --project "$pid" --limit "$LIMIT"; then
      printf '[]' > "$pf"
      linear_errs=1
      PROJECT_CUT_INCOMPLETE=1
      degrade "linear: issues list failed for project $pname"
    fi

    jq -nc --arg id "$pid" --arg name "$pname" --arg slug "$pslug" --slurpfile iss "$pf" \
      "$ISSUE_DEF"'{id:$id, name:$name, slug_id:$slug, open_issues: (($iss[0] // []) | rows)}' \
      >> "$PROJECTS_OUT"

    jq -r "$ISSUE_DEF"'rows[] | .identifier | select(length > 0)' "$pf" >> "$PROJ_IDS"

    # ANOMALY: a project whose whole open set is unassigned Backlog. Empty
    # projects are NOT this class — nothing is stalled when nothing is open.
    # Counted over `rows` (object elements only), so the total and the idle count
    # are drawn from the SAME set — a non-object element cannot make them differ.
    p_total="$(jq "$ISSUE_DEF"'rows | length' "$pf")"
    if [ "${p_total:-0}" -gt 0 ]; then
      p_idle="$(jq "$ISSUE_DEF"'[ rows[] | select(.state == "Backlog" and .assignee == "") ] | length' "$pf")"
      if [ "${p_idle:-0}" -eq "${p_total:-0}" ]; then
        anomaly "all-issues-backlog-no-assignee" "$pname" \
          "all $p_total open issue(s) are Backlog with no assignee"
      fi
    fi
  done < <(jq -r "$ISSUE_DEF"'objs[] | select((.id // "") != "") | [ (.id | tostring), (.name // "-" | tostring), (.slug_id // "" | tostring) ] | @tsv' "$WORK/projects.json")

  if [ "$linear_errs" -eq 1 ]; then
    LINEAR_STATUS="error"
    LINEAR_DETAIL="one or more lineark calls failed — see degraded"
  else
    LINEAR_DETAIL="lineark ok: $pn project(s), $(jq 'length' "$WORK/global.json") open issue(s) in the global sweep"
  fi
fi

# ---- reconciliation: global sweep vs the union of per-project lists ----------
# LC_ALL=C on every sort/comm/awk call site: these are byte-oriented set
# operations over identifiers, and comm REQUIRES both inputs sorted under the
# SAME collation. A caller-exported UTF-8 locale would otherwise reorder one
# side's punctuation and comm would report bogus differences in both directions
# — a phantom projectless list AND a phantom count-mismatch anomaly.
#
# INTEGRITY GATE. When the project cut is INCOMPLETE (projects list failed, or any
# per-project call failed) the project union is missing rows that really exist, so
# the difference is not "issues in no project" — it is "issues whose project call
# failed". Emitting it would name real, correctly-filed issues as projectless AND
# raise a count-mismatch anomaly from the very same hole. Report the reconciliation
# as unavailable instead. A FULLY ABSENT linear surface is a different, honest
# case: every input is [] and the difference is naturally [] — left unchanged.
if [ "$PROJECT_CUT_INCOMPLETE" -eq 1 ]; then
  printf '[]' > "$WORK/projectless.json"
  degrade "linear: reconciliation unavailable — incomplete project cut"
  jq "$ISSUE_DEF"'[ rows[] | select(.state == "In Progress") ]' "$WORK/mine.json" > "$WORK/mine_ip.json"
else

jq -r "$ISSUE_DEF"'rows[] | .identifier | select(length > 0)' "$WORK/global.json" > "$WORK/global.ids"
LC_ALL=C sort -u "$WORK/global.ids" > "$WORK/global.sorted"
LC_ALL=C sort -u "$PROJ_IDS" > "$WORK/proj.sorted"
LC_ALL=C comm -23 "$WORK/global.sorted" "$WORK/proj.sorted" > "$WORK/projectless.ids"
LC_ALL=C comm -13 "$WORK/global.sorted" "$WORK/proj.sorted" > "$WORK/extra.ids"

# Emitted in GLOBAL SWEEP order (not sorted): the caller reads this as a list of
# issues, and the sweep's own newest-first order is the useful one.
jq --rawfile ids "$WORK/projectless.ids" \
  "$ISSUE_DEF"'(($ids | split("\n") | map(select(length > 0))) as $set
   | objs | map(select((.identifier // "" | tostring) as $i | $set | index($i) != null) | issue))' \
  "$WORK/global.json" > "$WORK/projectless.json"

jq "$ISSUE_DEF"'[ rows[] | select(.state == "In Progress") ]' "$WORK/mine.json" > "$WORK/mine_ip.json"

extra_n="$(LC_ALL=C grep -c . "$WORK/extra.ids" 2>/dev/null || true)"
[ -n "$extra_n" ] || extra_n=0
if [ "$extra_n" -gt 0 ]; then
  extra_list="$(LC_ALL=C awk 'NF { if (s != "") s = s ", " $0; else s = $0 } END { print s }' "$WORK/extra.ids")"
  anomaly "open-issue-count-mismatch" "global-sweep" \
    "$extra_n identifier(s) listed under a project but absent from the global open sweep (global=$(LC_ALL=C grep -c . "$WORK/global.sorted" 2>/dev/null || printf 0), project-union=$(LC_ALL=C grep -c . "$WORK/proj.sorted" 2>/dev/null || printf 0)): $extra_list"
fi

fi

# ---- memory surface ----------------------------------------------------------
# fm_type <file> — the note's memory type from frontmatter: the first `type:`
# line inside the leading `---` block, top-level or nested under `metadata:`.
# Lowercased; empty when absent. `node_type:` is deliberately NOT matched (the
# regex anchors `type:` to the line start after optional indent). Mirrors
# check-memory-drift.sh's reader so both agree on what a "project" note is.
fm_type() {
  LC_ALL=C awk '
    NR==1 {
      if (substr($0,1,3) == "\357\273\277") $0 = substr($0,4)   # strip UTF-8 BOM
      if ($0 !~ /^---[[:space:]]*$/) exit
    }
    /^---[[:space:]]*$/ { saw++; if (saw==2) exit; next }
    saw==1 && /^[[:space:]]*type:[[:space:]]*/ {
      v=$0; sub(/^[[:space:]]*type:[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v)
      if (length(v) >= 2 && ((substr(v,1,1)=="\"" && substr(v,length(v),1)=="\"") || (substr(v,1,1)=="\047" && substr(v,length(v),1)=="\047"))) v=substr(v,2,length(v)-2)
      print tolower(v); exit
    }
  ' "$1"
}

# fm_field <file> <key> — a TOP-LEVEL frontmatter scalar (`name:`, `description:`),
# one surrounding quote pair stripped. Indented keys are ignored on purpose: a
# nested `metadata: name:` is not the note's name.
fm_field() {
  LC_ALL=C awk -v key="$2" '
    NR==1 {
      if (substr($0,1,3) == "\357\273\277") $0 = substr($0,4)
      if ($0 !~ /^---[[:space:]]*$/) exit
    }
    /^---[[:space:]]*$/ { saw++; if (saw==2) exit; next }
    saw==1 && index($0, key ":") == 1 {
      v=substr($0, length(key)+2); sub(/^[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v)
      if (length(v) >= 2 && ((substr(v,1,1)=="\"" && substr(v,length(v),1)=="\"") || (substr(v,1,1)=="\047" && substr(v,length(v),1)=="\047"))) v=substr(v,2,length(v)-2)
      print v; exit
    }
  ' "$1"
}

MEM_STATUS="absent"
MEM_DETAIL=""
if [ -z "$MEMORY_DIR" ]; then
  MEM_DETAIL="no --memory-dir given"
  degrade "memory: no --memory-dir given"
elif [ ! -d "$MEMORY_DIR" ]; then
  MEM_DETAIL="memory dir absent: $MEMORY_DIR"
  degrade "memory: dir absent ($MEMORY_DIR)"
elif [ ! -r "$MEMORY_DIR" ] || [ ! -x "$MEMORY_DIR" ]; then
  MEM_STATUS="error"
  MEM_DETAIL="memory dir not readable: $MEMORY_DIR"
  degrade "memory: dir not readable ($MEMORY_DIR)"
else
  MEM_STATUS="ok"
  mem_total=0
  mem_proj=0
  while IFS= read -r mf; do
    [ -n "$mf" ] || continue
    mem_total=$((mem_total + 1))
    [ "$(fm_type "$mf")" = "project" ] || continue
    mem_proj=$((mem_proj + 1))
    jq -nc --arg file "$(basename "$mf")" \
           --arg name "$(fm_field "$mf" name)" \
           --arg description "$(fm_field "$mf" description)" \
      '{file:$file, name:$name, description:$description}' >> "$MEM_OUT"
  done < <(find "$MEMORY_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
  MEM_DETAIL="$mem_proj project-type note(s) of $mem_total note(s) in $MEMORY_DIR"
fi

# ---- emit --------------------------------------------------------------------
JQ_FLAGS="-c"
[ "$PRETTY" -eq 1 ] && JQ_FLAGS=""

# shellcheck disable=SC2086 — JQ_FLAGS is a deliberate word-split switch.
jq -n $JQ_FLAGS \
  --arg schema "orient/v1" \
  --arg lstatus "$LINEAR_STATUS" --arg ldetail "$LINEAR_DETAIL" \
  --arg mstatus "$MEM_STATUS"   --arg mdetail "$MEM_DETAIL" \
  --slurpfile projects "$PROJECTS_OUT" \
  --slurpfile projectless "$WORK/projectless.json" \
  --slurpfile mineip "$WORK/mine_ip.json" \
  --slurpfile anomalies "$ANOMALIES" \
  --slurpfile memory "$MEM_OUT" \
  --rawfile degraded "$DEGRADED" \
  '# Every array-typed key is `// []`-defaulted. --slurpfile over an EMPTY file
   # yields [], so `[0]` is null — and an intermediate jq that hard-errors (a
   # malformed tracker payload) leaves exactly that empty file behind. Without
   # these defaults the document emits `"mine_in_progress": null` on exit 0: an
   # invalid orient/v1 that every caller must then re-guard. A key may be empty,
   # never null.
   {
     schema: $schema,
     surfaces: {
       linear: { status: $lstatus, detail: $ldetail },
       memory: { status: $mstatus, detail: $mdetail }
     },
     projects: ($projects // []),
     projectless_open_issues: ($projectless[0] // []),
     mine_in_progress: ($mineip[0] // []),
     anomalies: ($anomalies // []),
     memory_pointers: ($memory // []),
     degraded: (($degraded // "") | split("\n") | map(select(length > 0)))
   }'
