#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/spine-only.test.sh — guards the spine-only invariant.
#
# agentic-os-template (and, post-migration, the public template) ships ONLY the OS
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
# ctx7/context7 ARE audited with NO template exception. The former codex
# ctx7-managed block in harnesses/codex/AGENTS.template.md was relocated to an
# operator-local overlay (spliced at @@OPERATOR_CODEX_RULES_OVERLAY@@ by
# install.sh), so the shipped template is spine-only and ANY ctx7/context7
# reference in it is now a hard regression. Bare codegraph/runtime-dir references
# in scripts remain out of scope (legitimate infra, not a tool opinion). F4
# replaced the former file-wide exclusions with the line-scoped allowlist
# documented at the audit block.

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
# ctx7/context7 are in the forbidden set — the SKILLS overlay split plus the
# codex rules-overlay relocation removed all shipped ctx7 routing, so a stray
# ctx7 reference anywhere in shipped content is now a regression (no exception).
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
# Pattern + allowlist are built from halves so this file is not self-matching.
# Case-insensitive: brand names appear both lowercased (CLI identifiers) and
# capitalized (prose / "Stripe — billing. Connected.").
_so_pat="play""wright|sup""abase|net""lify|str""ipe|fire""crawl|web-design-""guidelines|frontend-""design|con""text7|ct""x7"
# The allowlist is per-OCCURRENCE, not per-line (Codex F1), AND each strip is
# anchored to the secret-scan CONTENT SIGNATURE — a brand-free token from the
# surrounding secret-scan construct — NOT just the file path. The bare brand is
# removed ONLY on lines that carry that signature, then the residual is rescanned.
# Two properties fall out:
#  - a forbidden identifier sharing a real secret-scan line still trips — only the
#    brand is removed, a co-located identifier survives;
#  - a tool opinion ANYWHERE ELSE in the file trips, even one that embeds the brand
#    inside a variable/key name (e.g. "use stripelive"), because such a line lacks
#    the secret-scan signature so nothing is stripped. A file-scoped token strip —
#    even of the signature form — masked these (Codex adversarial pass on this
#    change); content anchoring is the gap this closes.
# Anchors (post-lowercase), brand-free + metachar-free so the sed addresses need no
# escaping and the PS twin matches the same substrings:
# - scripts/validate.ps1 — `_live_` (the Stripe live-key regex on the def line) and
#   `bgnpriv` (the $bgnPriv sibling on the assembled-$pattern line) bracket the two
#   $stripeLive occurrences; strip the Stripe brand on each.
# - obsidian/.../memory-vault-audit.js — `secretpattern` (the const secretPattern
#   regex) brackets the STRIPE_SECRET_KEY + SUPABASE_SERVICE_ROLE_KEY occurrences;
#   strip both brands.
# Brands are built from halves; we lowercase first (BSD sed has no `I` flag) and the
# pattern is already lowercase, so the residual grep needs no `-i`.
_so_str="str""ipe"; _so_sup="sup""abase"
# Shared strip pipeline (reads stdin) — one definition feeds the live audit and
# each regression so the four copies cannot drift.
_so_strip() {
  sed -E \
    -e "/^scripts\/validate\.ps1:.*_live_/ s/$_so_str//g" \
    -e "/^scripts\/validate\.ps1:.*bgnpriv/ s/$_so_str//g" \
    -e "/^obsidian\/vault-scaffolding\/bin\/memory-vault-audit\.js:.*secretpattern/ s/$_so_str//g" \
    -e "/^obsidian\/vault-scaffolding\/bin\/memory-vault-audit\.js:.*secretpattern/ s/$_so_sup//g"
}
_so_hits="$(cd "$_so_root" && git grep -niIE "$_so_pat" -- ':!tests/' ':!docs/' 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' | _so_strip | grep -E "$_so_pat" || true)"
assert_eq "spine-only: no operator tool identifiers outside the allowlisted DATA lines" "" "$_so_hits"

# Self-trip regression A — per-occurrence: a forbidden identifier sharing a real
# secret-scan line MUST still trip. The brand on the anchored line is stripped; the
# co-located identifier survives. Tokens split so this source isn't self-listing.
_so_evil="$(printf '%s\n%s\n' \
  "scripts/validate.ps1:210:${_so_str}live = '_live_' regex; also wire fire""crawl" \
  "obsidian/vault-scaffolding/bin/memory-vault-audit.js:69:const secretpattern ${_so_str}_secret_key|${_so_sup}_service_role_key; plus play""wright")"
_so_evil_residual="$(printf '%s\n' "$_so_evil" | _so_strip | grep -cE "$_so_pat" || true)"
assert_eq "spine-only: a forbidden identifier on a real secret-scan line still trips" \
  "2" "$_so_evil_residual"

# Self-trip regression B — pure opinion: a bare-brand tool opinion in an allowlisted
# file (no secret-scan signature) MUST trip. Brands split so this source isn't
# self-listing.
_so_pure="$(printf '%s\n%s\n' \
  "scripts/validate.ps1:99:# use the ${_so_str} cli for billing checks" \
  "obsidian/vault-scaffolding/bin/memory-vault-audit.js:99:# wire ${_so_sup} and ${_so_str} here")"
_so_pure_residual="$(printf '%s\n' "$_so_pure" | _so_strip | grep -cE "$_so_pat" || true)"
assert_eq "spine-only: a pure bare-brand opinion in an allowlisted file still trips" \
  "2" "$_so_pure_residual"

# Self-trip regression C — signature-form prose: a tool opinion that embeds the
# brand inside the secret-scan variable/key NAME (e.g. "use stripelive", "wire
# stripe_secret_key") but lacks the surrounding secret-scan signature MUST still
# trip. A file-scoped strip of the signature token alone masked these; content
# anchoring catches them.
_so_evade="$(printf '%s\n%s\n' \
  "scripts/validate.ps1:99:# use ${_so_str}live for billing checks" \
  "obsidian/vault-scaffolding/bin/memory-vault-audit.js:99:# wire ${_so_sup}_service_role_key and ${_so_str}_secret_key here")"
_so_evade_residual="$(printf '%s\n' "$_so_evade" | _so_strip | grep -cE "$_so_pat" || true)"
assert_eq "spine-only: brand in a signature name without the secret-scan context still trips" \
  "2" "$_so_evade_residual"

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
