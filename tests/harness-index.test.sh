#!/usr/bin/env bash
# tests/harness-index.test.sh — per-harness generated index views
# (obsidian/vault-scaffolding/bin/generate-harness-index.js) + the vault
# secret scan extension in memory-vault-audit.js.
#
# Pins the contract from core/memory-model.md § Harness-Neutral
# Note Schema:
#   1. scope filter — a note scoped to one harness never appears in another
#      harness's generated view (the mechanical "orient cannot load it" proof);
#   2. determinism — same tree in, same bytes out, twice;
#   3. drift enforcement — a hand-edited view fails `--check`;
#   4. secret scan — a planted credential shape in a vault note trips the
#      audit's scan.
#
# Runs against a TMP COPY of the scaffolding — never mutates the live repo
# tree. Sourced by tests/run.sh; uses assert_* helpers from tests/lib.sh.
# Never call `exit` — failures bubble through assertion counters.

HI_SCAFFOLD="$REPO_ROOT/obsidian/vault-scaffolding"
HI_GEN="bin/generate-harness-index.js"
HI_AUDIT="bin/memory-vault-audit.js"

if ! command -v node >/dev/null 2>&1; then
  _skip "harness-index suite" "node not installed"
elif [ ! -f "$HI_SCAFFOLD/$HI_GEN" ]; then
  _fail "generator present" "missing: $HI_SCAFFOLD/$HI_GEN"
else
  HI_TMP="$(mktemp -d)/vault"
  cp -R "$HI_SCAFFOLD" "$HI_TMP"

  # --- T1: shipped scaffolding views match regeneration (no drift at HEAD) ---
  assert_exit "shipped scaffolding passes generator --check" 0 -- \
    node "$HI_TMP/$HI_GEN" --check

  # --- T2: scope filter — a harness-scoped note appears ONLY in its own view.
  # claude-scoped fixture: visible in the claude view, absent from codex +
  # hermes views. This is the mechanical filter test: an orient that starts
  # from its harness's generated view cannot load the foreign-scoped note.
  printf -- '---\ntitle: scoped fixture\nharness: claude\nlearned_by: claude\n---\n\nClaude-only guidance.\n' \
    > "$HI_TMP/10-Wiki/__scoped-fixture__.md"
  node "$HI_TMP/$HI_GEN" >/dev/null 2>&1

  hi_claude_view="$(cat "$HI_TMP/90-Indexes/Harness Index - claude.md")"
  hi_codex_view="$(cat "$HI_TMP/90-Indexes/Harness Index - codex.md")"
  hi_hermes_view="$(cat "$HI_TMP/90-Indexes/Harness Index - hermes.md")"
  assert_contains "claude view lists the claude-scoped note" \
    "$hi_claude_view" "__scoped-fixture__"
  assert_not_contains "codex view does NOT list the claude-scoped note" \
    "$hi_codex_view" "__scoped-fixture__"
  assert_not_contains "hermes view does NOT list the claude-scoped note" \
    "$hi_hermes_view" "__scoped-fixture__"

  # Unscoped note (no harness: key) defaults to all — visible everywhere.
  printf -- '---\ntitle: unscoped fixture\n---\n\nShared guidance.\n' \
    > "$HI_TMP/10-Wiki/__unscoped-fixture__.md"
  node "$HI_TMP/$HI_GEN" >/dev/null 2>&1
  hi_codex_view="$(cat "$HI_TMP/90-Indexes/Harness Index - codex.md")"
  assert_contains "missing harness: key defaults to all (codex view lists it)" \
    "$hi_codex_view" "__unscoped-fixture__"

  # --- T3: determinism — regenerate twice, byte-identical ---
  hi_sum1="$(cat "$HI_TMP/90-Indexes/Harness Index - "*.md | cksum)"
  node "$HI_TMP/$HI_GEN" >/dev/null 2>&1
  hi_sum2="$(cat "$HI_TMP/90-Indexes/Harness Index - "*.md | cksum)"
  assert_contains "regeneration is deterministic (byte-identical twice)" \
    "$hi_sum1" "$hi_sum2"

  # --- T4: drift enforcement — a hand-edited view fails --check ---
  printf 'HAND EDIT\n' >> "$HI_TMP/90-Indexes/Harness Index - hermes.md"
  assert_exit "hand-edited view fails generator --check" 1 -- \
    node "$HI_TMP/$HI_GEN" --check
  node "$HI_TMP/$HI_GEN" >/dev/null 2>&1   # heal for T5

  # --- T5: vault secret scan — planted credential shape trips the audit.
  # Sentinel assembled from non-matching halves so this test source never
  # self-trips a tree-wide scan (feedback_self_tripping_test_source).
  _HI_KEYNAME="ANTHROPIC_API""_KEY"
  _HI_KEYVAL="sk-""ant-test0123456789abcdefghij"
  printf -- '---\ntitle: planted secret fixture\n---\n\n%s=%s\n' \
    "$_HI_KEYNAME" "$_HI_KEYVAL" > "$HI_TMP/10-Wiki/__planted-secret__.md"
  hi_audit_out="$(node "$HI_TMP/$HI_AUDIT" 2>&1 || true)"
  assert_contains "planted secret in a vault note trips the audit scan" \
    "$hi_audit_out" "likely secret pattern in 10-Wiki/__planted-secret__.md"

  rm -rf "${HI_TMP%/vault}"
fi
