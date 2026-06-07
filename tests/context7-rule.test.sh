#!/usr/bin/env bash
# tests/context7-rule.test.sh — ctx7 rule block in
# harnesses/codex/AGENTS.template.md so install.sh --harness codex does not
# clobber it on re-render.
#
# Phase 1.4 ran `npx ctx7 setup --universal --cli -y` which wrote a
# rule block (bracketed by `<!-- context7 -->` markers) directly to
# ~/.codex/AGENTS.md. Since the framework regenerates that file from
# harnesses/codex/AGENTS.template.md, the source template must carry the same
# block — otherwise the next install.sh run silently reverts ctx7's edit.
# Same pattern as (codegraph reconcile into the Claude template).
#
# Test files are SOURCED by tests/run.sh — do NOT `exit`, do NOT re-source
# lib.sh, do NOT set -e. Just call assert_*.

CODEX_TEMPLATE="$REPO_ROOT/harnesses/codex/AGENTS.template.md"
assert_file "Codex harness template exists" "$CODEX_TEMPLATE"

# --- Template source: ctx7 block present with markers for re-detection -------

# Opening + closing HTML-comment markers preserved so ctx7's `setup --universal`
# re-run can find and update its own block in place (rather than appending a
# duplicate). The markers are identical strings on their own line — assert
# exactly 2 *whole-line* matches via grep -cFx so an accidental future inline
# mention of the marker substring in prose can't silently bump the count
# without breaking ctx7's actual marker-pair contract (Codex F-1 amendment).
ct_markers="$(grep -cFx '<!-- context7 -->' "$CODEX_TEMPLATE")"
assert_eq "Codex template has the ctx7 open+close markers (exactly 2 whole-line matches)" "2" "$ct_markers"

# Rule prose itself — anchor on the leading sentence ctx7 writes.
assert_exit "Codex template carries the ctx7 'Use the ctx7 CLI' rule" 0 -- \
  /usr/bin/grep -qF "Use the \`ctx7\` CLI to fetch current documentation" "$CODEX_TEMPLATE"

# The 4 numbered operating steps — anchor on Step 1 (library resolution).
assert_exit "Codex template carries ctx7 Step 1 (library resolution)" 0 -- \
  /usr/bin/grep -qF "Resolve library:" "$CODEX_TEMPLATE"

# Codex-specific sandbox guidance ctx7 appends inside the codex-harness block
# (sandbox-aware DNS/fetch-error retry advice). Codex-only; Claude template
# intentionally does not carry this — that's the asymmetric install surface.
assert_exit "Codex template carries the Codex-sandbox guidance ctx7 appended" 0 -- \
  /usr/bin/grep -qF "outside Codex's default sandbox" "$CODEX_TEMPLATE"

# --- Render round-trip: the block survives install.sh into AGENTS.md ---------

CTX7_DIR="$(mktemp -d)"
CTX7_OUT="$CTX7_DIR/out"; mkdir -p "$CTX7_OUT"
CTX7_ENV="$CTX7_DIR/local.env"
make_codex_env "$CTX7_ENV" "$CTX7_OUT" "$CTX7_DIR/vault"
ctx7_build="$(AI_CONFIG_LOCAL_ENV="$CTX7_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness codex --build-only 2>/dev/null)"

if [ -n "$ctx7_build" ] && [ -f "$ctx7_build/AGENTS.md" ]; then
  built_markers="$(grep -cFx '<!-- context7 -->' "$ctx7_build/AGENTS.md")"
  assert_eq "rendered AGENTS.md preserves the ctx7 open+close markers (exactly 2 whole-line matches)" "2" "$built_markers"
  built="$(cat "$ctx7_build/AGENTS.md")"
  assert_contains "rendered AGENTS.md carries the ctx7 rule prose" "$built" "Use the \`ctx7\` CLI to fetch current documentation"
  assert_contains "rendered AGENTS.md carries the Codex-sandbox guidance" "$built" "outside Codex's default sandbox"
else
  _fail "ctx7 build: codex --build-only produced no AGENTS.md at $ctx7_build"
fi
[ -n "$ctx7_build" ] && rm -rf "$ctx7_build"
rm -rf "$CTX7_DIR"

# --- Drift gate: a full install with the ctx7 block round-trips clean --------

CTX7_FI_DIR="$(mktemp -d)"
CTX7_FI_OUT="$CTX7_FI_DIR/target"; mkdir -p "$CTX7_FI_OUT"
CTX7_FI_ENV="$CTX7_FI_DIR/local.env"
make_codex_env "$CTX7_FI_ENV" "$CTX7_FI_OUT"
AI_CONFIG_LOCAL_ENV="$CTX7_FI_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness codex >/dev/null 2>&1
assert_exit "codex full install with ctx7 block passes drift check" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$CTX7_FI_OUT"
rm -rf "$CTX7_FI_DIR"
