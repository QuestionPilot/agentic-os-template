#!/usr/bin/env bash
# tests/spine-only.test.sh — guards the spine-only invariant.
#
# ai-config (and, post-migration, the public template) ships ONLY the OS
# spine: the three homegrown self-improving capabilities (session-agent,
# closeout, self-audit) + their machinery + the two architectural-layer
# CONTRACTS (linear/, obsidian/) which are documented-not-installed. It ships
# ZERO operator tool opinions — no plugin enables, no CLI/MCP catalog, no
# recommended tool-skills, no connector inventories. All tool choices are
# operator-local (claude-config), mirroring how the Linear/Obsidian surfaces
# are documented as contracts but never auto-installed.
#
# Enumeration is via git (ls-files / grep), never filesystem globs, so an
# untracked stray cannot mask a regression and a dotfile is not silently
# skipped. Forbidden-identifier strings are split + rejoined at runtime so this
# guard file never trips its own audit (defense-in-depth: tests/ is excluded
# from the audit anyway).
#
# ctx7/context7 ARE now audited. The ONE deferred exception is the
# codex ctx7-managed block in harnesses/codex/AGENTS.template.md (a block the
# `ctx7 setup` integration writes + greps; it needs a codex rules/ sidecar before
# it can move operator-local, ~) — line-allowlisted in the audit below,
# ctx7-only, so a non-ctx7 opinion in that template still trips. Bare.codegraph/
# runtime-dir references in scripts remain out of scope (legitimate infra, not a
# tool opinion). F4 replaced the former file-wide exclusions with the
# line-scoped allowlist documented at the audit block.

_so_root="${REPO_ROOT:?REPO_ROOT not set}"

# --- structural: the tool-layer files must not be tracked ------------------
for _so_rel in \
  catalog.md \
  skills/capability-families.md \
  harnesses/claude/connectors.md \
  harnesses/codex/connectors.md
do
  _so_n="$(cd "$_so_root" && git ls-files -- "$_so_rel" | wc -l | tr -d ' ')"
  assert_eq "spine-only: $_so_rel is not shipped" "0" "$_so_n"
done

# skills/recommended/ — the entire recommended tool-skill dir must be gone
_so_n="$(cd "$_so_root" && git ls-files -- 'skills/recommended/*' | wc -l | tr -d ' ')"
assert_eq "spine-only: skills/recommended/ is not shipped" "0" "$_so_n"

# --- structural: capabilities/ ships exactly the 3 spine capabilities ------
# LC_ALL=C sort → byte order (uppercase before lowercase), matched on the PS side
# by an Ordinal StringComparer so both twins produce an identical joined string.
_so_caps="$(cd "$_so_root" && git ls-files -- 'capabilities/*.md' \
  | sed 's#capabilities/##' | LC_ALL=C sort | tr '\n' ',')"
assert_eq "spine-only: capabilities/ = README + 3 spine capabilities only" \
  "README.md,closeout.md,self-audit.md,session-agent.md," "$_so_caps"

# --- structural: shipped settings.base.json enables zero plugins ----------
_so_plugins="$(cd "$_so_root" && tr -d ' \n\t' < harnesses/claude/settings.base.json \
  | grep -oE '"enabledPlugins":\{[^}]*\}' || true)"
assert_eq "spine-only: settings.base.json enables zero plugins" \
  '"enabledPlugins":{}' "$_so_plugins"

# --- structural: shipped settings.base.json ships no cost/behavior preference ---
# theme + effortLevel are operator-local (carried across re-renders by install.sh
# preserve-live); the shared base must not ship them downstream — effortLevel in
# particular is a cost setting.
_so_prefs="$(cd "$_so_root" && tr -d ' \n\t' < harnesses/claude/settings.base.json \
  | grep -oE '"(theme|effortLevel)"' | tr '\n' ',' || true)"
assert_eq "spine-only: settings.base.json ships no theme/effortLevel preference" \
  "" "$_so_prefs"

# --- audit: forbidden tool identifiers appear ONLY in allowlisted DATA lines ---
# The audit targets brain CONTENT (capabilities, core, skills, harness adapters/
# templates, playbooks) + the installer + the architectural-contract dirs
# (linear/, obsidian/) + the publish/scan machinery (scripts/validate.*,
# build-public-snapshot.*, core/tool-use.md).
#
# F1: ctx7/context7 join the forbidden set — the SKILLS overlay split
# removed the last shipped ctx7 routing, so a stray ctx7 reference is now a
# regression (the codex AGENTS ctx7 block is the sole deferred exception, below).
#
# F4: this previously EXCLUDED whole files (validate.*, build-public-
# snapshot.*, linear/, obsidian/, core/tool-use.md) — a tool opinion sneaking
# into any of them was invisible. Now only docs/ (archived point-in-time plans)
# and tests/ (this guard's own pattern strings) stay file-excluded; everything
# else is SCANNED, and a short line-scoped allowlist passes the handful of lines
# that legitimately NAME a tool as DATA, not as a shipped tool opinion. Each is
# anchored by "path:line:" + a stable content signature, so a *different* tool
# opinion added to the same file still trips:
# - scripts/validate.ps1 — the Stripe live-key secret-scan regex
# - obsidian/.../memory-vault-audit.js — the STRIPE_SECRET_KEY secret scan
# - harnesses/codex/AGENTS.template.md — the ctx7-managed block (a block the
# `ctx7 setup` integration writes + greps; deferred to a codex rules/ sidecar,
# ~). Allowlisted ONLY for ctx7/context7, so a non-ctx7 opinion in that
# template still trips.
# Pattern + allowlist are built from halves so this file is not self-matching.
# Case-insensitive: brand names appear both lowercased (CLI identifiers) and
# capitalized (prose / "Stripe — billing. Connected.").
_so_pat="play""wright|sup""abase|net""lify|str""ipe|fire""crawl|web-design-""guidelines|frontend-""design|con""text7|ct""x7"
# The allowlist is per-OCCURRENCE, not per-line (Codex F1): for each hit, strip
# ONLY the name-as-data token that is legitimate FOR ITS FILE, then rescan the
# residual for any forbidden identifier. So a real tool opinion sharing a line
# with an allowed token (e.g. "use ctx7 and install playwright") still trips —
# a per-line drop would have swallowed the whole line. Strip tokens are built
# from halves; we lowercase first (BSD sed has no `I` flag) and the pattern is
# already lowercase, so the residual grep needs no `-i`. Address-scoped sed subs
# keep each allow confined to its own file:
# - scripts/validate.ps1 — the Stripe brand inside its secret-scan regex
# - obsidian/.../memory-vault-audit.js — the Stripe AND Supabase brands inside
# its secret-scan key-prefix regex (SUPABASE_SERVICE_ROLE_KEY / STRIPE_SECRET_KEY)
# - harnesses/codex/AGENTS.template.md — ctx7/context7 (the deferred codex block)
_so_str="str""ipe"; _so_sup="sup""abase"; _so_c7="con""text7"; _so_cx="ct""x7"
_so_hits="$(cd "$_so_root" && git grep -niIE "$_so_pat" -- ':!tests/' ':!docs/' 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E \
      -e "/^scripts\/validate\.ps1:/ s/$_so_str//g" \
      -e "/^obsidian\/vault-scaffolding\/bin\/memory-vault-audit\.js:/ s/$_so_str//g" \
      -e "/^obsidian\/vault-scaffolding\/bin\/memory-vault-audit\.js:/ s/$_so_sup//g" \
      -e "/^harnesses\/codex\/agents\.template\.md:/ s/$_so_c7//g" \
      -e "/^harnesses\/codex\/agents\.template\.md:/ s/$_so_cx//g" \
  | grep -E "$_so_pat" || true)"
assert_eq "spine-only: no operator tool identifiers outside the allowlisted DATA lines" "" "$_so_hits"

# F1 regression (self-trip): a real tool opinion sharing a line with an allowed
# token MUST still trip. Build adversarial lines at runtime (split tokens so this
# source isn't self-listing) and run them through the SAME strip+rescan pipeline.
_so_evil="$(printf '%s\n%s\n' \
  "harnesses/codex/agents.template.md:120:use ct""x7 and install play""wright" \
  "scripts/validate.ps1:210:stripe scanner; also wire fire""crawl")"
_so_evil_residual="$(printf '%s\n' "$_so_evil" \
  | sed -E \
      -e "/^scripts\/validate\.ps1:/ s/$_so_str//g" \
      -e "/^harnesses\/codex\/agents\.template\.md:/ s/$_so_c7//g" \
      -e "/^harnesses\/codex\/agents\.template\.md:/ s/$_so_cx//g" \
  | grep -cE "$_so_pat" || true)"
assert_eq "spine-only: allowlist is per-occurrence (a real opinion sharing an allowed line still trips)" \
  "2" "$_so_evil_residual"

# --- structural: the SHIPPED claude SKILLS template is spine-only ---
# After the overlay split, harnesses/claude/SKILLS.template.md ships ONLY the
# spine: routing method + a spine-only routing table + the generated capability
# catalog + built-in harness skills + the @@OPERATOR_SKILLS_OVERLAY@@ insertion
# marker. The operator's plugin/family catalog (Anthropic Skills, the business
# families, Context7, local CLIs) lives in a local overlay under claude-config,
# appended at render time by install.{sh,ps1}. So the shipped template must carry
# zero operator plugin-namespace / family / local-CLI / ctx7 names. The marker
# string + the forbidden pattern are built from halves so this guard file never
# self-matches (and is excluded from the audit regardless).
_so_tmpl="$_so_root/harnesses/claude/SKILLS.template.md"

_so_marker="@@OPERATOR_SKILLS""_OVERLAY@@"
_so_marker_n="$(grep -cF "$_so_marker" "$_so_tmpl" 2>/dev/null)"
assert_eq "spine-only: SKILLS.template.md carries the operator-overlay marker once" \
  "1" "$_so_marker_n"

# Operator plugin namespaces (rendered as `<ns>:<skill>`), family section
# headers, the two local CLIs, and ctx7/context7 must not appear.
_so_fam="anthropic-""skills:|productivity:|design:|engineering:|product-""management:|marketing:|data:|finance:|operations:|legal:|sales:|human-""resources:|customer-""support:|small-""business:|zoom-""plugin:|enterprise-""search:|pdf-""viewer:|zapier:|claude-md-""management:|code""burn|design""lang|con""text7|ct""x7"
_so_tmpl_hits="$(grep -niE "$_so_fam" "$_so_tmpl" 2>/dev/null || true)"
assert_eq "spine-only: SKILLS.template.md carries no operator plugin/family/CLI names" \
  "" "$_so_tmpl_hits"

# Positive heading allowlist (Codex F4): the $_so_fam denylist above only catches
# KNOWN namespaces — an operator family section with a heading that has no `<ns>:`
# form (e.g. "### Figma Plugin Skills") would slip. So additionally assert every
# H2/H3 heading in the shipped template matches one of the spine section keywords;
# anything else is an operator section that must live in the overlay, not here.
# Keyed on stable ASCII substrings (not the full heading) to avoid transcribing
# the em-dash / quote chars in two heading lines. A new spine heading adds a
# keyword here in lockstep — intentional friction on the shipped template's shape.
_so_head_allow="How to use|Routing Layer|Routing table|Top recommendations|Live Inventory|Agentic OS capabilities|Built-in|Candidates|MCP connectors|Maintenance"
_so_bad_headings="$(grep -E '^#{2,3} ' "$_so_tmpl" | grep -vE "$_so_head_allow" || true)"
assert_eq "spine-only: SKILLS.template.md has only spine section headings (no operator family sections)" \
  "" "$_so_bad_headings"
