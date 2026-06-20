#!/usr/bin/env bash
# tests/harness-index.test.sh — per-harness generated index views
# (obsidian/vault-scaffolding/bin/generate-harness-index.js) + the published
# scaffold audit (memory-vault-audit.js) behavior checks.
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
# Plus the scaffold-audit behaviors backported from the live vault tool:
#   5. .DS_Store is a WARN, never a FAIL (macOS/Drive spray it back, so gating
#      on it would make a cloud-synced scaffold copy fail nondeterministically);
#   6. an unlinked note surfaces as an orphan WARN, never a FAIL;
#   7. a machine-specific absolute path in a note FAILs (keep the vault agnostic);
#   8. a URL whose path contains a Users or home segment does NOT FAIL — the
#      machine-path guard tells a URL path apart from a real machine path —
#      while real macOS, Linux, and Windows home paths still FAIL.
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

  # --- T6-T8: scaffold-audit behaviors backported from the live vault tool.
  # Run on a SECOND, pristine copy: the T1-T5 copy still holds the planted
  # secret (a persistent FAIL), which would mask the exit-0 assertions below.
  HI_TMP2="$(mktemp -d)/vault"
  cp -R "$HI_SCAFFOLD" "$HI_TMP2"
  HI_AUDIT2="$HI_TMP2/$HI_AUDIT"

  # T6: a stray .DS_Store is OS noise (macOS/Finder/Drive regenerate it), so the
  # audit must WARN and stay exit-0 — never FAIL — or a Drive-synced scaffold
  # copy audits nondeterministically.
  : > "$HI_TMP2/.DS_Store"
  hi_ds_out="$(node "$HI_AUDIT2" 2>&1)"; hi_ds_rc=$?
  assert_eq "stray .DS_Store does not FAIL the scaffold audit" 0 "$hi_ds_rc"
  assert_contains "stray .DS_Store surfaces as a WARN" "$hi_ds_out" "WARN OS noise"
  rm -f "$HI_TMP2/.DS_Store"

  # T7: a note with zero inbound wikilinks is an orphan — WARN-only, never FAIL.
  # Regenerate the index around the plant so this isolates ORPHAN behavior from
  # the index-drift FAIL a new note would otherwise cause.
  printf -- '# orphan fixture\n\nNo note links here.\n' \
    > "$HI_TMP2/10-Wiki/__orphan-fixture__.md"
  node "$HI_TMP2/$HI_GEN" >/dev/null 2>&1
  hi_orph_out="$(node "$HI_AUDIT2" 2>&1)"; hi_orph_rc=$?
  assert_eq "an unlinked note does not FAIL the audit (orphans are WARN)" 0 "$hi_orph_rc"
  assert_contains "an unlinked note surfaces as an orphan WARN" \
    "$hi_orph_out" "orphan page — no inbound wikilinks (link it from a hub or index): 10-Wiki/__orphan-fixture__.md"
  rm -f "$HI_TMP2/10-Wiki/__orphan-fixture__.md"
  node "$HI_TMP2/$HI_GEN" >/dev/null 2>&1

  # T8: a machine-specific absolute path in a note must FAIL (keep the vault
  # agnostic). The sentinel path is assembled from halves so THIS test source
  # never trips the repo-wide machine-path scan (feedback_self_tripping_test_source).
  # Regenerate the index AFTER the plant so the ONLY possible FAIL is the machine
  # path — that makes the non-zero exit attributable to checkAgnostic, not to
  # incidental index drift. Assert both the exit code AND the `FAIL ` prefix so a
  # silent fail()->warn() downgrade (same message, WARN not FAIL) is caught.
  _hi_mp="/Users""/sentinel-user/x"
  printf -- '---\ntitle: machinepath fixture\n---\n\nSee %s here.\n' "$_hi_mp" \
    > "$HI_TMP2/10-Wiki/__machinepath-fixture__.md"
  node "$HI_TMP2/$HI_GEN" >/dev/null 2>&1
  hi_mp_out="$(node "$HI_AUDIT2" 2>&1)"; hi_mp_rc=$?
  assert_eq "a machine-specific absolute path FAILs the audit (non-zero exit)" 1 "$hi_mp_rc"
  assert_contains "a machine-specific absolute path surfaces as a FAIL line (not WARN)" \
    "$hi_mp_out" "FAIL machine-specific absolute path (keep vault agnostic): 10-Wiki/__machinepath-fixture__.md"
  rm -f "$HI_TMP2/10-Wiki/__machinepath-fixture__.md"
  node "$HI_TMP2/$HI_GEN" >/dev/null 2>&1

  # T9: a note containing a URL whose path includes a Users or home segment must
  # NOT FAIL — checkAgnostic tells a URL path (the segment is preceded by an
  # alphanumeric host char) apart from a real machine path. The URL is assembled
  # from halves so the contiguous path never trips the repo-wide machine-path
  # scan (feedback_self_tripping_test_source). Regenerate the index after the
  # plant so a non-zero exit could ONLY come from checkAgnostic; assert exit 0
  # AND that no machine-path FAIL names this note (a regression to the old bare
  # substring regex would flag the URL and trip both).
  _hi_url="https://example.com/home""/getting-started"
  printf -- '---\ntitle: url fixture\n---\n\nSee [guide](%s) for setup.\n' "$_hi_url" \
    > "$HI_TMP2/10-Wiki/__url-fixture__.md"
  node "$HI_TMP2/$HI_GEN" >/dev/null 2>&1
  hi_url_out="$(node "$HI_AUDIT2" 2>&1)"; hi_url_rc=$?
  assert_eq "a URL with a home path segment does not FAIL the audit (exit 0)" 0 "$hi_url_rc"
  assert_not_contains "a URL path is not flagged as a machine-specific path" \
    "$hi_url_out" "machine-specific absolute path (keep vault agnostic): 10-Wiki/__url-fixture__.md"
  rm -f "$HI_TMP2/10-Wiki/__url-fixture__.md"
  node "$HI_TMP2/$HI_GEN" >/dev/null 2>&1

  # T10: a real absolute Linux home path must still FAIL — the URL refinement
  # must not disable the home-dir arm. Sentinel assembled from halves
  # (feedback_self_tripping_test_source); regenerate the index after the plant so
  # the FAIL is attributable to checkAgnostic. Assert the `FAIL ` prefix so a
  # silent fail()->warn() downgrade is caught.
  _hi_home="/home""/sentinel-user/notes"
  printf -- '---\ntitle: homepath fixture\n---\n\nSee %s here.\n' "$_hi_home" \
    > "$HI_TMP2/10-Wiki/__homepath-fixture__.md"
  node "$HI_TMP2/$HI_GEN" >/dev/null 2>&1
  hi_home_out="$(node "$HI_AUDIT2" 2>&1)"; hi_home_rc=$?
  assert_eq "a real Linux home-dir path FAILs the audit (non-zero exit)" 1 "$hi_home_rc"
  assert_contains "a real Linux home-dir path surfaces as a FAIL line (not WARN)" \
    "$hi_home_out" "FAIL machine-specific absolute path (keep vault agnostic): 10-Wiki/__homepath-fixture__.md"
  rm -f "$HI_TMP2/10-Wiki/__homepath-fixture__.md"
  node "$HI_TMP2/$HI_GEN" >/dev/null 2>&1

  # T11: a real Windows home path (drive, Users, name) must still FAIL — the
  # tightened Windows arm requires a real user-folder segment, not a bare
  # drive-colon-backslash. Sentinel assembled from halves so the contiguous
  # Windows path never trips the repo-wide machine-path scan
  # (feedback_self_tripping_test_source).
  _hi_win="C:\\Users""\\sentineluser\\notes"
  printf -- '---\ntitle: winpath fixture\n---\n\nSee %s here.\n' "$_hi_win" \
    > "$HI_TMP2/10-Wiki/__winpath-fixture__.md"
  node "$HI_TMP2/$HI_GEN" >/dev/null 2>&1
  hi_win_out="$(node "$HI_AUDIT2" 2>&1)"; hi_win_rc=$?
  assert_eq "a real Windows user-folder path FAILs the audit (non-zero exit)" 1 "$hi_win_rc"
  assert_contains "a real Windows user-folder path surfaces as a FAIL line (not WARN)" \
    "$hi_win_out" "FAIL machine-specific absolute path (keep vault agnostic): 10-Wiki/__winpath-fixture__.md"
  rm -f "$HI_TMP2/10-Wiki/__winpath-fixture__.md"

  rm -rf "${HI_TMP2%/vault}"
fi
