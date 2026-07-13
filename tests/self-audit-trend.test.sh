#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/self-audit-trend.test.sh — score-history persistence + trend view for the
# self-audit capability.
#
# self-audit gains a trend view across runs without making the capability write
# into the framework tree: history persists in an operator-local JSONL store
# keyed off $CLAUDE_CONFIG_DIR. These tests exercise scripts/self-audit-history.sh
# (append/read) against a TEMP store only — never the operator's real store —
# and assert the capability prose documents the behavior.
#
# Sourced by tests/run.sh: no `exit`, no `set -e`/`-u`/`pipefail` (they'd leak
# into the runner). Cleanup is inline per test.

HIST_SH="$REPO_ROOT/scripts/self-audit-history.sh"

# --- the helper script ships and is executable -------------------------------
assert_file "scripts/self-audit-history.sh exists" "$HIST_SH"
if [ -x "$HIST_SH" ]; then
  _pass "scripts/self-audit-history.sh is executable"
else
  _fail "scripts/self-audit-history.sh is executable" "not +x: $HIST_SH"
fi
assert_file "scripts/self-audit-history.ps1 twin exists" \
  "$REPO_ROOT/scripts/self-audit-history.ps1"

# --- append: a self-audit --json scorecard writes one JSONL record -----------
_test_append_writes_record() {
  command -v jq >/dev/null 2>&1 || { _skip "append writes record" "jq not installed"; return 0; }
  local store; store="$(mktemp -d)/hist.jsonl" || return 1

  # Build a scorecard against a minimal fixture repo so we exercise the real
  # self-audit.sh --json producer end-to-end, then pipe it to append.
  local fixture; fixture="$(mktemp -d)" || return 1
  mkdir -p "$fixture/capabilities" "$fixture/verification" \
           "$fixture/harnesses/claude/capabilities" "$fixture/harnesses/codex/capabilities"
  bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null \
    | bash "$HIST_SH" append "$store" 2>/dev/null

  local lines total has_pillars has_ts
  lines="$(grep -c . "$store" 2>/dev/null || printf '0')"
  total="$(tail -1 "$store" 2>/dev/null | jq -r '.total' 2>/dev/null)"
  has_pillars="$(tail -1 "$store" 2>/dev/null | jq -r '.pillars | type' 2>/dev/null)"
  has_ts="$(tail -1 "$store" 2>/dev/null | jq -r 'has("timestamp")' 2>/dev/null)"
  rm -rf "$(dirname "$store")" "$fixture"

  if [ "$lines" = "1" ] && [ -n "$total" ] && [ "$total" != "null" ] \
     && [ "$has_pillars" = "object" ] && [ "$has_ts" = "true" ]; then
    _pass "append writes one JSONL record with total + pillars + timestamp"
  else
    _fail "append writes one JSONL record with total + pillars + timestamp" \
          "lines=[$lines] total=[$total] pillars=[$has_pillars] ts=[$has_ts]"
  fi
}
_test_append_writes_record

# --- append: each run appends (does not clobber) -----------------------------
_test_append_is_append_only() {
  command -v jq >/dev/null 2>&1 || { _skip "append is append-only" "jq not installed"; return 0; }
  local store; store="$(mktemp -d)/hist.jsonl" || return 1
  local sc='{"date":"2026-05-30","total":95,"pillars":{"a":{"score":20},"b":{"score":15}},"gaps":[],"skipped":[]}'
  printf '%s' "$sc" | bash "$HIST_SH" append "$store" 2>/dev/null
  printf '%s' "$sc" | bash "$HIST_SH" append "$store" 2>/dev/null
  printf '%s' "$sc" | bash "$HIST_SH" append "$store" 2>/dev/null
  local lines; lines="$(grep -c . "$store" 2>/dev/null || printf '0')"
  rm -rf "$(dirname "$store")"
  assert_eq "append is append-only: 3 runs -> 3 records" "3" "$lines"
}
_test_append_is_append_only

# --- append: malformed stdin is REFUSED (no junk record) ---------------------
_test_append_refuses_malformed() {
  command -v jq >/dev/null 2>&1 || { _skip "append refuses malformed" "jq not installed"; return 0; }
  local store; store="$(mktemp -d)/hist.jsonl" || return 1
  # The {"error":...} shape self-audit.sh emits when jq is missing has no.total.
  local rc
  printf '%s' '{"error":"jq required for --json"}' | bash "$HIST_SH" append "$store" >/dev/null 2>&1
  rc=$?
  local exists=0; [ -f "$store" ] && exists=1
  rm -rf "$(dirname "$store")"
  if [ "$rc" -ne 0 ] && [ "$exists" -eq 0 ]; then
    _pass "append refuses a malformed scorecard and writes no record"
  else
    _fail "append refuses a malformed scorecard and writes no record" \
          "expected non-zero exit + no store, got rc=[$rc] store_exists=[$exists]"
  fi
}
_test_append_refuses_malformed

# --- trend: per-pillar table over the last N records, with deltas ------------
# Build a deterministic store by hand (fixed timestamps) so the table is stable.
_sa_seed_store() {
  local store="$1"
  {
    printf '{"timestamp":"2026-05-28T10:00:00Z","total":90,"overall":90,"pillars":{"cross-layer-handoffs":20,"memory-hygiene":18,"folder-hygiene":20,"verification-coverage":12,"closeout-spine-discipline":20}}\n'
    printf '{"timestamp":"2026-05-29T10:00:00Z","total":94,"overall":94,"pillars":{"cross-layer-handoffs":20,"memory-hygiene":20,"folder-hygiene":20,"verification-coverage":14,"closeout-spine-discipline":20}}\n'
    printf '{"timestamp":"2026-05-30T10:00:00Z","total":100,"overall":100,"pillars":{"cross-layer-handoffs":20,"memory-hygiene":20,"folder-hygiene":20,"verification-coverage":20,"closeout-spine-discipline":20}}\n'
  } > "$store"
}

_test_trend_table() {
  command -v jq >/dev/null 2>&1 || { _skip "trend table" "jq not installed"; return 0; }
  local d; d="$(mktemp -d)" || return 1
  local store="$d/hist.jsonl"
  _sa_seed_store "$store"

  local out; out="$(bash "$HIST_SH" trend "$store" 5 2>/dev/null)"
  rm -rf "$d"

  # Header names the run count, a Pillar header row, a per-pillar row, a Total
  # row, and the latest-vs-prior deltas (+6 total, +6 verification-coverage).
  assert_contains "trend heading names the run count" \
    "$out" "last 3 run(s)"
  assert_contains "trend has a Pillar header column" \
    "$out" "| Pillar |"
  assert_contains "trend shows the verification-coverage pillar row" \
    "$out" "| verification-coverage |"
  assert_contains "trend shows the Total row" \
    "$out" "| **Total** |"
  assert_contains "trend shows the Total delta latest-vs-prior (+6)" \
    "$out" "| 90 | 94 | 100 | +6 |"
  assert_contains "trend shows a per-pillar delta (verification-coverage +6)" \
    "$out" "| verification-coverage | 12 | 14 | 20 | +6 |"
  assert_contains "trend shows a flat-pillar delta as 0" \
    "$out" "| cross-layer-handoffs | 20 | 20 | 20 | 0 |"
}
_test_trend_table

# --- trend: N caps the window to the most recent records ---------------------
_test_trend_respects_N() {
  command -v jq >/dev/null 2>&1 || { _skip "trend respects N" "jq not installed"; return 0; }
  local d; d="$(mktemp -d)" || return 1
  local store="$d/hist.jsonl"
  _sa_seed_store "$store"
  local out; out="$(bash "$HIST_SH" trend "$store" 2 2>/dev/null)"
  rm -rf "$d"
  # With N=2 only the two newest runs (94, 100) appear; the oldest (90) is dropped.
  assert_contains "trend N=2 names 2 runs" "$out" "last 2 run(s)"
  assert_contains "trend N=2 keeps the two newest totals" \
    "$out" "| 94 | 100 | +6 |"
  assert_not_contains "trend N=2 drops the oldest total column" \
    "$out" "| 90 | 94 | 100 |"
}
_test_trend_respects_N

# --- bash<->pwsh byte-parity: trend output on the same seeded store ----------
# Codex confirmation flagged that no test locks the
# twin byte-parity the design requires. Run BOTH twins on an identical store
# and diff after LF-normalizing the PS output (its only legitimate divergence).
_test_trend_twin_byte_parity() {
  command -v jq   >/dev/null 2>&1 || { _skip "trend twin byte-parity" "jq not installed"; return 0; }
  command -v pwsh >/dev/null 2>&1 || { _skip "trend twin byte-parity" "pwsh not installed"; return 0; }
  local hist_ps="$REPO_ROOT/scripts/self-audit-history.ps1"
  [ -f "$hist_ps" ] || { _skip "trend twin byte-parity" "ps twin missing"; return 0; }
  local d; d="$(mktemp -d)" || return 1
  local store="$d/hist.jsonl"
  _sa_seed_store "$store"
  bash "$HIST_SH" trend "$store" 5 > "$d/b.out" 2>/dev/null
  pwsh -NoProfile -File "$hist_ps" trend "$store" 5 2>/dev/null | tr -d '\r' > "$d/p.out"
  local same=0
  diff -q "$d/b.out" "$d/p.out" >/dev/null 2>&1 && same=1
  rm -rf "$d"
  if [ "$same" -eq 1 ]; then
    _pass "trend output is byte-identical bash<->pwsh on a seeded store"
  else
    _fail "trend output is byte-identical bash<->pwsh on a seeded store" \
          "bash and pwsh trend output diverge (LF-normalized)"
  fi
}
_test_trend_twin_byte_parity

# --- bash<->pwsh byte-parity: append record (modulo generated timestamp) -----
# Same scorecard piped to both twins must yield byte-identical JSONL records
# once the generated timestamp field is masked. Locks the pillar key-order +
# field-order parity Codex flagged as untested.
_test_append_twin_record_parity() {
  command -v jq   >/dev/null 2>&1 || { _skip "append twin record parity" "jq not installed"; return 0; }
  command -v pwsh >/dev/null 2>&1 || { _skip "append twin record parity" "pwsh not installed"; return 0; }
  local hist_ps="$REPO_ROOT/scripts/self-audit-history.ps1"
  [ -f "$hist_ps" ] || { _skip "append twin record parity" "ps twin missing"; return 0; }
  local d; d="$(mktemp -d)" || return 1
  local sc='{"date":"2026-05-30","total":83,"pillars":{"cross-layer-handoffs":{"score":20},"memory-hygiene":{"score":16},"folder-hygiene":{"score":12},"verification-coverage":{"score":15},"closeout-spine-discipline":{"score":20}},"gaps":[],"skipped":[]}'
  printf '%s' "$sc" | bash "$HIST_SH" append "$d/b.jsonl" 2>/dev/null
  printf '%s' "$sc" | pwsh -NoProfile -File "$hist_ps" append "$d/p.jsonl" 2>/dev/null
  # Mask the generated timestamp (the only legitimate per-run difference).
  local b p
  b="$(sed -E 's/"timestamp":"[^"]*"/"timestamp":"<TS>"/' "$d/b.jsonl" 2>/dev/null)"
  p="$(tr -d '\r' < "$d/p.jsonl" | sed -E 's/"timestamp":"[^"]*"/"timestamp":"<TS>"/' 2>/dev/null)"
  rm -rf "$d"
  assert_eq "append record is byte-identical bash<->pwsh modulo timestamp" "$b" "$p"
}
_test_append_twin_record_parity

# --- append: store is written no-BOM + LF-only (no CRLF, no BOM) -------------
# Codex missing-test: assert the on-disk bytes carry no UTF-8 BOM and no CR.
_test_append_store_no_bom_lf() {
  command -v jq >/dev/null 2>&1 || { _skip "append store no-BOM/LF" "jq not installed"; return 0; }
  local d; d="$(mktemp -d)" || return 1
  local store="$d/hist.jsonl"
  local sc='{"date":"2026-05-30","total":77,"pillars":{"a":{"score":20}},"gaps":[],"skipped":[]}'
  printf '%s' "$sc" | bash "$HIST_SH" append "$store" 2>/dev/null
  # First 3 bytes must NOT be the UTF-8 BOM (EF BB BF); file must contain no CR.
  local first3 cr
  first3="$(head -c 3 "$store" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  cr="$(tr -cd '\r' < "$store" 2>/dev/null | wc -c | tr -d ' ')"
  rm -rf "$d"
  if [ "$first3" != "efbbbf" ] && [ "$cr" = "0" ]; then
    _pass "append store has no UTF-8 BOM and LF-only line endings"
  else
    _fail "append store has no UTF-8 BOM and LF-only line endings" \
          "first3=[$first3] cr_count=[$cr]"
  fi
}
_test_append_store_no_bom_lf

# --- trend: ordinal pillar-key order matches jq keys (case/punctuation) ------
# Codex confirmation: PS must sort pillar keys by Unicode codepoint (jq `keys`),
# not culture collation. Seed a store with mixed-case + underscore keys where
# the two orderings diverge, and assert bash + (if present) pwsh agree.
_test_trend_ordinal_key_order() {
  command -v jq >/dev/null 2>&1 || { _skip "trend ordinal key order" "jq not installed"; return 0; }
  local d; d="$(mktemp -d)" || return 1
  local store="$d/hist.jsonl"
  printf '{"timestamp":"2026-05-30T10:00:00Z","total":4,"overall":4,"pillars":{"apple":1,"Beta":1,"_under":1,"Zebra":1}}\n' > "$store"
  local b_order
  # Extract the pillar-row order from the bash trend table (rows after header).
  b_order="$(bash "$HIST_SH" trend "$store" 1 2>/dev/null | grep -E '^\| (apple|Beta|_under|Zebra) ' | sed -E 's/^\| ([^ ]+) .*/\1/' | paste -sd, -)"
  local jq_order
  jq_order="$(jq -r '.pillars | keys | join(",")' "$store" 2>/dev/null)"
  local p_ok="skip" p_order=""
  if command -v pwsh >/dev/null 2>&1 && [ -f "$REPO_ROOT/scripts/self-audit-history.ps1" ]; then
    p_order="$(pwsh -NoProfile -File "$REPO_ROOT/scripts/self-audit-history.ps1" trend "$store" 1 2>/dev/null | tr -d '\r' | grep -E '^\| (apple|Beta|_under|Zebra) ' | sed -E 's/^\| ([^ ]+) .*/\1/' | paste -sd, -)"
    [ "$p_order" = "$jq_order" ] && p_ok="ok" || p_ok="bad"
  fi
  rm -rf "$d"
  assert_eq "trend bash key order matches jq codepoint keys" "$jq_order" "$b_order"
  if [ "$p_ok" = "ok" ]; then
    _pass "trend pwsh key order matches jq codepoint keys (ordinal, not collation)"
  elif [ "$p_ok" = "skip" ]; then
    _skip "trend pwsh key order matches jq codepoint keys" "pwsh not installed"
  else
    _fail "trend pwsh key order matches jq codepoint keys (ordinal, not collation)" \
          "expected [$jq_order] got [$p_order]"
  fi
}
_test_trend_ordinal_key_order

# --- trend: empty / absent store degrades gracefully (no crash) --------------
_test_trend_no_history() {
  local d; d="$(mktemp -d)" || return 1
  local out rc
  out="$(bash "$HIST_SH" trend "$d/nope.jsonl" 2>/dev/null)"
  rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "no history yet"; then
    _pass "trend degrades gracefully when the store is absent"
  else
    _fail "trend degrades gracefully when the store is absent" \
          "rc=[$rc] out=[$out]"
  fi
}
_test_trend_no_history

# --- the store path default is operator-local (.gitignore'd) -----------------
# The store keys off $CLAUDE_CONFIG_DIR and must never be committed. The repo's
# gitignore must exclude self-audit-history.jsonl so a store dropped under a
# checkout-rooted CLAUDE_CONFIG_DIR can't be staged.
GITIGNORE_CONTENT="$(cat "$REPO_ROOT/.gitignore" 2>/dev/null || true)"
assert_contains "self-audit-history.jsonl is gitignored (operator-local store)" \
  "$GITIGNORE_CONTENT" "self-audit-history.jsonl"

# --- the capability documents the trend behavior -----------------------------
SA_TREND_CAP="$(cat "$REPO_ROOT/capabilities/self-audit.md" 2>/dev/null || true)"
assert_contains "capability documents the history store filename" \
  "$SA_TREND_CAP" "self-audit-history.jsonl"
assert_contains "capability documents the trend subcommand" \
  "$SA_TREND_CAP" "self-audit-history.sh"
assert_contains "capability documents appending a record after each run" \
  "$SA_TREND_CAP" "append"
assert_contains "capability documents the trend view" \
  "$SA_TREND_CAP" "trend"
