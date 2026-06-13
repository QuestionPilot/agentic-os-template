#!/usr/bin/env bash
# install.sh — compiles capabilities/ + a harness adapter into harness-native output.
#
# Usage: install.sh [--harness <name>]... [--out <dir>] [--build-only]
#   --harness <name>  target harness (default: claude). Repeatable — pass it more
#                     than once to build several harnesses in one pass, e.g.
#                     --harness claude --harness codex. Each harness builds into
#                     its own target dir (CLAUDE_CONFIG_DIR / CODEX_HOME).
#   --out <dir>       override build target (default: $CLAUDE_CONFIG_DIR from
#                     local.env). Single-harness only — cannot be combined with
#                     more than one --harness.
#   --build-only      build + validate into a temp dir, print its path, do NOT swap
# Env: AI_CONFIG_LOCAL_ENV  path to local.env (default: <repo>/local.env)
#
# The build is idempotent and atomic: it builds into a temp dir on the target
# filesystem, validates, then renames the managed subtrees into place.
set -euo pipefail

# Bash 5.2 enables patsub_replacement by default — an unescaped '&' in a ${//}
# replacement string then expands to the matched text. The build substitutes
# machine paths (which may contain '&') as literal replacements in hook scripts
# and entrypoint templates, so disable it for deterministic, literal behaviour.
shopt -u patsub_replacement 2>/dev/null || true

HARNESSES=()      # requested harnesses, lowercased + deduped, in request order
OUT=""
BUILD_ONLY=0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
self="$script_dir/$(basename "${BASH_SOURCE[0]}")"

while [ $# -gt 0 ]; do
  case "$1" in
    --harness)
      # Repeatable: accumulate into an ARRAY (not a string). An array element is
      # never re-split on whitespace or glob-expanded, so a value like
      # 'claude codex' or '*' stays a single token and is rejected downstream as
      # an unknown harness rather than silently becoming two requests / matching
      # files in the CWD. Names are lowercased so casing variants dedupe and
      # resolve identically (claude == CLAUDE), and deduped so a repeated harness
      # builds once. `${arr[@]+"${arr[@]}"}` is the empty-array-safe expansion
      # under `set -u` (bash 3.2 errors on a bare "${arr[@]}" when empty).
      _h="${2:?--harness needs a value}"
      _h="$(printf '%s' "$_h" | tr '[:upper:]' '[:lower:]')"
      _seen=0
      for _x in ${HARNESSES[@]+"${HARNESSES[@]}"}; do
        [ "$_x" = "$_h" ] && { _seen=1; break; }
      done
      [ "$_seen" -eq 1 ] || HARNESSES+=("$_h")
      shift 2 ;;
    --out)        OUT="${2:?--out needs a value}"; shift 2;;
    --build-only) BUILD_ONLY=1; shift;;
    -h|--help)    grep -E '^# ' "$0" | sed 's/^# //'; exit 0;;
    *) printf 'install.sh: unknown argument: %s\n' "$1" >&2; exit 2;;
  esac
done

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }
warn() { printf 'install.sh: WARNING %s\n' "$1" >&2; }

# harness_target_env <harness> -> the env var NAME holding its build target.
# Returns non-zero for an unknown harness (callers turn that into a clear die).
# One mapping shared by the multi-harness preflight and the single-harness
# resolution below, so the two can never drift apart.
harness_target_env() {
  case "$1" in
    claude) printf 'CLAUDE_CONFIG_DIR\n' ;;
    codex)  printf 'CODEX_HOME\n' ;;
    hermes) printf 'HERMES_HOME\n' ;;
    *) return 1 ;;
  esac
}

command -v jq >/dev/null 2>&1 || die "jq is required but not found"

# --- portable sha256 ------------------------------------------------------
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else die "no sha256 tool (sha256sum / shasum) found"; fi
}

# --- markdown frontmatter helpers ----------------------------------------
# fm_block <file>  -> the YAML between the first two --- lines (empty if none).
fm_block() {
  awk 'NR==1{if($0!="---"){exit}} NR>1{if($0~/^---[[:space:]]*$/){exit}; print}' "$1"
}
# fm_get <fm-text> <key>  -> the value of key (first match), trimmed.
# An absent key yields empty output and exit 0 — optional keys (allowed-tools,
# enforcement) rely on this not aborting under `set -euo pipefail`.
fm_get() {
  printf '%s\n' "$1" | grep -E "^$2:[[:space:]]*" | head -n 1 | sed -E "s/^$2:[[:space:]]*//" || true
}
# body_after_fm <file>  -> file content after a leading frontmatter block.
# If the file has no frontmatter, prints the whole file.
body_after_fm() {
  if [ "$(head -n 1 "$1")" = "---" ]; then
    awk 'f{print} /^---[[:space:]]*$/{c++; if(c==2){f=1}}' "$1"
  else
    cat "$1"
  fi
}

# --- load local.env ------------------------------------------------------
LOCAL_ENV="${AI_CONFIG_LOCAL_ENV:-$repo_root/local.env}"
[ -f "$LOCAL_ENV" ] || die "local.env not found at $LOCAL_ENV"
set -a
# shellcheck disable=SC1090
. "$LOCAL_ENV"
set +a
AI_CONFIG_DIR="${AI_CONFIG_DIR:-$repo_root}"

# --harness is repeatable. Default to claude when none was given. With more than
# one harness, build each in one pass. Each harness has its OWN target dir, so
# --out / --build-only (single-target operations) are rejected here. PREFLIGHT
# every requested harness BEFORE any mutation — validate the name, its adapter,
# and that its target dir resolves — so a misconfigured second harness (e.g.
# CODEX_HOME unset) fails the whole command up front instead of after the first
# harness has already swapped its live config into place (a half-synced machine).
# Only once every preflight check passes do we re-exec this script once per
# harness, each in a clean process (own temp build dir, hook accumulator, EXIT
# trap). This makes the documented `--harness claude --harness codex` build BOTH;
# the old scalar parse was last-wins and silently built only the last.
[ "${#HARNESSES[@]}" -gt 0 ] || HARNESSES=(claude)
if [ "${#HARNESSES[@]}" -gt 1 ]; then
  [ -z "$OUT" ] || die "--out cannot be combined with multiple --harness values (each harness builds into its own target dir); run install.sh once per harness with --out"
  [ "$BUILD_ONLY" -eq 0 ] || die "--build-only cannot be combined with multiple --harness values (it prints a single build dir); run install.sh once per harness with --build-only"
  for h in "${HARNESSES[@]}"; do
    tenv="$(harness_target_env "$h")" || die "unknown harness '$h' (known: claude, codex, hermes)"
    [ -f "$repo_root/harnesses/$h/adapter.md" ] || die "no adapter for harness '$h' (expected $repo_root/harnesses/$h/adapter.md)"
    [ -n "${!tenv:-}" ] || die "$tenv is not set in $LOCAL_ENV (required to build harness '$h')"
  done
  for h in "${HARNESSES[@]}"; do
    bash "$self" --harness "$h" || die "install failed for harness '$h'"
  done
  exit 0
fi
HARNESS="${HARNESSES[0]}"

# Each harness names its build target via a different env var. Resolve it
# per-harness; an unknown harness is rejected here, before anything else.
target_env="$(harness_target_env "$HARNESS")" \
  || die "unknown harness '$HARNESS' (known: claude, codex, hermes)"
# --out takes precedence; the per-harness env var is only the fallback target,
# so --out must be applied before the requirement check — otherwise --out is
# unusable on a machine where the env var is not set.
target_default="${!target_env:-}"
TARGET="${OUT:-$target_default}"
[ -n "$TARGET" ] || die "$target_env is not set in $LOCAL_ENV (or pass --out <dir>)"

adapter="$repo_root/harnesses/$HARNESS/adapter.md"
[ -f "$adapter" ] || die "no adapter for harness '$HARNESS' (expected $adapter)"

# --- temp build dir on the target filesystem (so the final swap is a rename) ---
mkdir -p "$TARGET"
# Canonicalize TARGET to an absolute path. A relative --out / target env var
# would otherwise leak relative `command` paths into the generated settings.json
# / hooks.json, which the harness resolves against an unpredictable CWD.
# `CDPATH=` neutralizes a hostile CDPATH: without it, `cd` on a bare relative
# target could resolve via a CDPATH entry (wrong directory) and echo the path
# (corrupting the captured TARGET).
TARGET="$(CDPATH= cd "$TARGET" && pwd)"
BUILD="$(mktemp -d "$TARGET/.install-build.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$BUILD/skills" "$BUILD/hooks"

# Accumulators filled by compile_* and emitted by generate_settings.
HOOK_BLOCKS=""          # newline-separated "event<US>matcher<US>script" records
# Field separator: ASCII unit-separator (0x1f). '|' is unsafe (matchers contain
# it) and a tab is unsafe (IFS-whitespace collapses an empty matcher field).
HOOK_REC_SEP=$'\x1f'

# The managed subtrees/files install.sh owns in the target, and the entrypoint
# template:output pairs to compile — both per-harness. MANAGED_PATHS is one
# declaration consumed by the swap/rollback/cleanup loops; ENTRYPOINTS is one
# declaration consumed by the entrypoint-compile and manifest loops — so neither
# set can drift apart from its consumers. HARNESS is already validated above.
case "$HARNESS" in
  claude)
    MANAGED_PATHS="skills hooks settings.json CLAUDE.md SKILLS.md .build-manifest.json"
    ENTRYPOINTS="CLAUDE.template.md:CLAUDE.md SKILLS.template.md:SKILLS.md" ;;
  codex)
    MANAGED_PATHS="skills hooks hooks.json AGENTS.md .build-manifest.json"
    ENTRYPOINTS="AGENTS.template.md:AGENTS.md" ;;
  hermes)
    # config.yaml is user-owned (operator model/provider/platform config), so
    # hook wiring is emitted as a copy-paste snippet at hooks/hooks.yaml inside
    # the managed hooks/ subtree. plugins/ is build-managed wholesale — the
    # adapter directs operators at a dedicated profile dir (HERMES_HOME), where
    # the framework owns the tree.
    MANAGED_PATHS="skills hooks plugins SOUL.md .build-manifest.json"
    ENTRYPOINTS="SOUL.template.md:SOUL.md" ;;
esac

# --- stubs (filled in later tasks) ---------------------------------------
# compile_native <base> <cap-file> <cap-frontmatter>
# Writes <build>/skills/<base>/SKILL.md = generated frontmatter + neutral body
# + per-harness realization body.
compile_native() {
  local base="$1" cap="$2" fm="$3"
  local real="$repo_root/harnesses/$HARNESS/capabilities/$base.md"
  [ -f "$real" ] || die "native capability '$base' has no $HARNESS realization"

  local summary triggers desc tools rfm
  summary="$(fm_get "$fm" summary)"
  triggers="$(fm_get "$fm" triggers | tr -d '[]')"
  desc="$summary Triggers: $triggers"

  # Router caps descriptions at ~1536 chars — warn rather than silently truncate.
  if [ "${#desc}" -gt 1536 ]; then
    warn "capability '$base' description is ${#desc} chars (>1536 router cap)"
  fi

  rfm="$(fm_block "$real")"
  tools="$(fm_get "$rfm" allowed-tools)"

  mkdir -p "$BUILD/skills/$base"
  {
    printf -- '---\n'
    printf 'name: %s\n' "$base"
    # Folded block scalar — robust to ':'/quotes/'#' in the summary or triggers.
    printf 'description: >-\n  %s\n' "$desc"
    [ -n "$tools" ] && printf 'allowed-tools: %s\n' "$tools"
    printf -- '---\n\n'
    body_after_fm "$cap"
    printf '\n'
    body_after_fm "$real"
  } > "$BUILD/skills/$base/SKILL.md"

  # Register the capability's enforcement hook, if it declares one.
  local enf; enf="$(fm_get "$fm" enforcement)"
  if [ -n "$enf" ]; then
    local spec; spec="$(hook_for_class "$enf")" \
      || die "capability '$base' declares unknown enforcement class '$enf'"
    # $spec is deliberately word-split into its 3 fields; set -f disables
    # globbing so a glob char in the metadata cannot trigger pathname expansion.
    set -f
    # shellcheck disable=SC2086
    set -- $spec
    set +f
    install_hook "$1" "$2" "${3:-}"
  fi
}
# compile_vendored <base>
# Installs a vendored skill's committed snapshot directory as-is. If no snapshot
# is committed yet (<TEAM>-42 commits them), warns and skips — never fails the build.
compile_vendored() {
  local base="$1"
  local snap="$repo_root/harnesses/$HARNESS/vendored/$base"
  if [ -d "$snap" ]; then
    cp -R "$snap" "$BUILD/skills/$base"
  else
    warn "vendored capability '$base' has no committed snapshot at harnesses/$HARNESS/vendored/$base — skipping (tracked by <TEAM>-42)"
  fi
}

# generate_capability_catalog — emits a markdown table of the capability specs
# that ship to the target harness, one row per spec. Columns: name, summary,
# kind. A capability is included only when its `harnesses:` list contains
# $HARNESS — so the entrypoint never advertises a capability the harness has no
# installed skill for. Deterministic: the spec list is LC_ALL=C-sorted
# (locale-independent) and carries no timestamps, so repeated builds on any
# machine are byte-identical.
generate_capability_catalog() {
  printf '| Capability | What it does | Kind |\n'
  printf '| --- | --- | --- |\n'
  local cap base cfm summary kind harnesses
  while IFS= read -r cap; do
    [ -n "$cap" ] || continue
    base="$(basename "$cap" .md)"
    [ "$base" = "README" ] && continue
    cfm="$(fm_block "$cap")"
    harnesses="$(fm_get "$cfm" harnesses | tr -d '[]' | tr ',' ' ')"
    case " $harnesses " in *" $HARNESS "*) ;; *) continue;; esac
    summary="$(fm_get "$cfm" summary)"
    kind="$(fm_get "$cfm" kind)"
    # A '|' in a summary would break the table cell — escape it.
    summary="${summary//|/\\|}"
    printf '| `%s` | %s | %s |\n' "$base" "$summary" "$kind"
  done < <(find "$repo_root/capabilities" -maxdepth 1 -name '*.md' | LC_ALL=C sort)
}

# compile_entrypoint <template> <out-name> <catalog>
# Resolves @@VAR@@ path placeholders against the environment and replaces the
# @@CAPABILITY_CATALOG@@ marker with the generated catalog, writing <build>/<out>.
# A path placeholder whose variable is unset/empty fails the build — a generated
# entrypoint must never carry an empty path.
compile_entrypoint() {
  local tmpl="$1" out="$2" catalog="$3"
  [ -f "$tmpl" ] || die "entrypoint template not found: $tmpl"

  local content token var val overlay
  content="$(cat "$tmpl")"

  # Operator skills overlay. The shipped SKILLS template carries only
  # the spine (routing method + spine routing table + capability catalog +
  # built-ins) and a single @@OPERATOR_SKILLS_OVERLAY@@ marker. An operator's
  # plugin/family catalog lives in a local overlay file named by SKILLS_OVERLAY_PATH;
  # splice its contents at the marker (or empty, for a spine-only render). Done
  # BEFORE the @@VAR@@ loop so any path tokens inside the overlay also resolve.
  # Only runs for a template that actually carries the marker (SKILLS.md, not
  # CLAUDE.md) so the missing-overlay warning fires at most once per render.
  case "$content" in
    *@@OPERATOR_SKILLS_OVERLAY@@*)
      overlay=""
      if [ -n "${SKILLS_OVERLAY_PATH:-}" ]; then
        if [ -f "$SKILLS_OVERLAY_PATH" ]; then
          overlay="$(cat "$SKILLS_OVERLAY_PATH")"
          # An operator overlay must never re-introduce ANY overlay marker: the
          # two overlay branches run sequentially on the same $content, so a
          # stray marker in this payload would (a) survive into $content and make
          # the LATER codex branch fire on post-splice content — leaking codex
          # rules into a claude SKILLS.md — or (b) hit the @@VAR@@ loop and die
          # "resolves empty". Neutralize BOTH markers defensively (Codex F3 +
          # cross-overlay composition).
          overlay="${overlay//@@OPERATOR_SKILLS_OVERLAY@@/}"
          overlay="${overlay//@@OPERATOR_CODEX_RULES_OVERLAY@@/}"
          overlay="${overlay//@@OPERATOR_SOUL_IDENTITY@@/}"
        else
          # SET-but-missing is explicit operator intent gone wrong (typo, moved /
          # unmounted path) — warn loudly rather than silently dropping the whole
          # catalog, but still render spine-only so the install completes (Codex F2).
          printf 'warning: SKILLS_OVERLAY_PATH=%s is set but the file does not exist — rendering a spine-only %s\n' \
            "$SKILLS_OVERLAY_PATH" "$out" >&2
        fi
      fi
      content="${content//@@OPERATOR_SKILLS_OVERLAY@@/$overlay}"
      ;;
  esac

  # Operator codex-rules overlay. The shipped codex AGENTS template is spine-only
  # and carries a single @@OPERATOR_CODEX_RULES_OVERLAY@@ marker. An operator's
  # codex tool-policy rules (e.g. a doc-fetch CLI block) live in a local overlay
  # file named by CODEX_RULES_OVERLAY_PATH; splice its contents at the marker (or
  # empty, for a spine-only render). Twin of the SKILLS overlay above — Codex has
  # no auto-loaded rules/ dir, so operator rules must land in the rendered
  # AGENTS.md rather than a sidecar. Done BEFORE the @@VAR@@ loop so any path
  # tokens inside the overlay also resolve. Only runs for a template that carries
  # the marker (AGENTS.md, not CLAUDE/SKILLS) so the warning fires at most once.
  case "$content" in
    *@@OPERATOR_CODEX_RULES_OVERLAY@@*)
      overlay=""
      if [ -n "${CODEX_RULES_OVERLAY_PATH:-}" ]; then
        if [ -f "$CODEX_RULES_OVERLAY_PATH" ]; then
          overlay="$(cat "$CODEX_RULES_OVERLAY_PATH")"
          # Never let the overlay re-introduce ANY overlay marker (single-pass
          # splice). Strip BOTH: a surviving skills marker here would hit the
          # @@VAR@@ loop below and die "resolves empty" (the skills branch already
          # ran for this template, so it cannot consume it). See the skills
          # branch above — symmetric cross-overlay neutralization.
          overlay="${overlay//@@OPERATOR_CODEX_RULES_OVERLAY@@/}"
          overlay="${overlay//@@OPERATOR_SKILLS_OVERLAY@@/}"
          overlay="${overlay//@@OPERATOR_SOUL_IDENTITY@@/}"
        else
          printf 'warning: CODEX_RULES_OVERLAY_PATH=%s is set but the file does not exist — rendering a spine-only %s\n' \
            "$CODEX_RULES_OVERLAY_PATH" "$out" >&2
        fi
      fi
      content="${content//@@OPERATOR_CODEX_RULES_OVERLAY@@/$overlay}"
      ;;
  esac

  # Operator soul-identity overlay. The shipped Hermes SOUL template carries the
  # framework operating section plus a single @@OPERATOR_SOUL_IDENTITY@@ marker;
  # the operator's PERSONAL identity (name, voice, hard-nos — a lean projection of
  # the vault Operator Soul master) lives in a local file named by
  # SOUL_IDENTITY_PATH and is NEVER shipped to the public template (it would carry
  # operator PII + machine paths). Splice its contents at the marker, or empty for
  # an identity-less spine render — exactly what a fresh clone with no
  # SOUL_IDENTITY_PATH gets. Twin of the SKILLS / codex overlays above; done
  # BEFORE the @@VAR@@ loop so any path tokens inside the identity also resolve.
  # Only the SOUL template carries this marker, so the warning fires at most once.
  case "$content" in
    *@@OPERATOR_SOUL_IDENTITY@@*)
      overlay=""
      if [ -n "${SOUL_IDENTITY_PATH:-}" ]; then
        if [ -f "$SOUL_IDENTITY_PATH" ]; then
          overlay="$(cat "$SOUL_IDENTITY_PATH")"
          # Never let the identity payload reintroduce ANY overlay marker (single-
          # pass splice): a stray marker would survive into $content and either
          # leak across overlays or hit the @@VAR@@ loop and die "resolves empty".
          overlay="${overlay//@@OPERATOR_SOUL_IDENTITY@@/}"
          overlay="${overlay//@@OPERATOR_SKILLS_OVERLAY@@/}"
          overlay="${overlay//@@OPERATOR_CODEX_RULES_OVERLAY@@/}"
          # Also neutralize the catalog token: the @@VAR@@ loop SKIPS
          # CAPABILITY_CATALOG, so a literal @@CAPABILITY_CATALOG@@ in the identity
          # prose would survive to the final catalog substitution and graft a
          # second capability table into the identity section. The identity payload
          # never needs the catalog, so strip it here. (A bare, unshaped `@@` still
          # passes through — operator-authored identity must be plain prose with no
          # @@…@@ framework tokens; documented in local.env.example.)
          overlay="${overlay//@@CAPABILITY_CATALOG@@/}"
        else
          # SET-but-missing is explicit operator intent gone wrong (typo, moved /
          # unmounted path) — warn loudly rather than silently dropping identity,
          # but still render so the install completes.
          printf 'warning: SOUL_IDENTITY_PATH=%s is set but the file does not exist — rendering an identity-less spine %s\n' \
            "$SOUL_IDENTITY_PATH" "$out" >&2
        fi
      fi
      content="${content//@@OPERATOR_SOUL_IDENTITY@@/$overlay}"
      ;;
  esac

  for token in $(printf '%s\n' "$content" | grep -oE '@@[A-Z_]+@@' | sort -u); do
    var="${token#@@}"; var="${var%@@}"
    [ "$var" = "CAPABILITY_CATALOG" ] && continue
    val="${!var:-}"
    [ -n "$val" ] || die "entrypoint $out: placeholder $token resolves empty — set $var in local.env"
    content="${content//"$token"/$val}"
  done
  content="${content//@@CAPABILITY_CATALOG@@/$catalog}"
  printf '%s\n' "$content" > "$BUILD/$out"
}

# install_hook <script> <event> <matcher>
# Copies a hook script into the build, substitutes @@AI_CONFIG_DIR@@, makes it
# executable, and records its settings.json wiring. Idempotent: re-registering
# the same script is a no-op.
install_hook() {
  local script="$1" event="$2" matcher="$3"
  local src="$repo_root/harnesses/$HARNESS/hooks/$script"
  [ -f "$src" ] || die "hook script not found: $src"

  if [ ! -f "$BUILD/hooks/$script" ]; then
    # Substitute via bash parameter expansion — no delimiter, so the resolved
    # path may contain any character (#, &, \ are all safe here).
    local content
    content="$(cat "$src")"
    printf '%s\n' "${content//@@AI_CONFIG_DIR@@/$AI_CONFIG_DIR}" > "$BUILD/hooks/$script"
    chmod +x "$BUILD/hooks/$script"
  fi
  case "$HOOK_BLOCKS" in
    *"$HOOK_REC_SEP$script"$'\n'*) ;;   # already registered
    *) HOOK_BLOCKS="${HOOK_BLOCKS}${event}${HOOK_REC_SEP}${matcher}${HOOK_REC_SEP}${script}"$'\n' ;;
  esac
}

# install_hook_script_only <script> — copies + substitutes a hook script into
# the build WITHOUT registering any event wiring (no HOOK_BLOCKS record, so it
# never lands in the generated hook config). For tooling shipped alongside the
# hooks whose scheduling/registration is a deliberate operator act (the hermes
# steward).
install_hook_script_only() {
  local script="$1"
  local src="$repo_root/harnesses/$HARNESS/hooks/$script"
  [ -f "$src" ] || die "hook script not found: $src"
  if [ ! -f "$BUILD/hooks/$script" ]; then
    local content
    content="$(cat "$src")"
    content="${content//@@AI_CONFIG_DIR@@/$AI_CONFIG_DIR}"
    # Substitute the vault path only when set — an empty value would silently
    # bake a broken path, so leave the token in place and let validate_build's
    # unresolved-placeholder gate fail the build loudly instead.
    if [ -n "${OBSIDIAN_VAULT_PATH:-}" ]; then
      content="${content//@@OBSIDIAN_VAULT_PATH@@/$OBSIDIAN_VAULT_PATH}"
    fi
    printf '%s\n' "$content" > "$BUILD/hooks/$script"
    chmod +x "$BUILD/hooks/$script"
  fi
}

# enforcement-class -> "script event matcher"  (mirrors each harness adapter's
# Fact 2). Only the pre-edit matcher differs — claude intercepts
# Write|Edit|NotebookEdit, codex apply_patch.
# Two enforcement classes were removed and intentionally have no rows here:
#   - `prompt-scan` — the cross-model-review capability moved out of
#     agentic-os-template to Shape C; no capability declares it.
#   - `session-end-gate` — the closeout `Stop` hook was removed because
#     it re-fired on closeout's own writes; closeout is now manual-fire. No
#     capability declares it.
# If a new capability later needs either class, restore its rows (and the
# matching hook script in each harnesses/<h>/hooks/) here.
hook_for_class() {
  case "$HARNESS:$1" in
    claude:pre-edit-gate)    echo "session-agent.sh PreToolUse Write|Edit|NotebookEdit" ;;
    codex:pre-edit-gate)     echo "session-agent.sh PreToolUse apply_patch" ;;
    hermes:pre-edit-gate)    echo "session-agent.sh pre_tool_call write_file|patch|terminal" ;;
    *) return 1 ;;
  esac
}

# generate_settings — merges a generated `hooks` object into a copy of
# settings.base.json. The hook `command` is the absolute path of the script in
# the FINAL target (not the temp build dir), so the file is correct post-swap.
generate_settings() {
  local base="$repo_root/harnesses/$HARNESS/settings.base.json"
  [ -f "$base" ] || die "settings.base.json not found at $base"

  local hooks_json='{}' event matcher script entry
  while IFS="$HOOK_REC_SEP" read -r event matcher script; do
    [ -n "$event" ] || continue
    entry="$(jq -n \
      --arg matcher "$matcher" \
      --arg command "$TARGET/hooks/$script" \
      '{matcher: $matcher, hooks: [{type: "command", command: $command, args: [], timeout: 10}]}')"
    # Append the entry to the event's array (creating the array if absent).
    hooks_json="$(printf '%s' "$hooks_json" | jq \
      --arg event "$event" --argjson entry "$entry" \
      '.[$event] = ((.[$event] // []) + [$entry])')"
  done <<< "$HOOK_BLOCKS"

  # Preserve operator-owned preference keys across re-renders. settings.base.json
  # ships spine-only defaults — it carries ZERO plugin opinions (enabledPlugins is
  # empty) and NO cost/behavior preferences (no theme, no effortLevel — those would
  # otherwise ship the authoring operator's xhigh cost setting to every downstream
  # user). Once an operator has a live settings.json, THEIR plugin choices
  # (enabledPlugins), notification preferences (agentPushNotifEnabled,
  # inputNeededNotifEnabled — both app-written), and UI/cost
  # preferences (theme, effortLevel) must survive a re-render; otherwise every
  # install reverts them to base — re-enabling plugins the operator disabled,
  # dropping the notification keys, and discarding the operator's theme/effortLevel.
  # Mirrors the tracker/vault model: the brain stays opinion-free, the operator's
  # choices live in their local config, and the renderer bridges them without
  # overwriting. theme/effortLevel join the overlay on the same spine-only
  # precedent as enabledPlugins — a preference must not ship in the shared base.
  #
  # AI_CONFIG_SKIP_PRESERVE_LIVE: check-drift.sh sets this when it builds the
  # canonical comparison artifact for soft-drift classification. That baseline
  # MUST be opinion-free (base only) — if it copied the live enabledPlugins, an
  # operator/attacker plugin value-change would self-match canonical and be
  # silently cured instead of flagged. The NORMAL render (and the cure re-render,
  # which IS a normal render) still preserves-live, so operator choices persist
  # non-destructively. On a fresh install (no live settings.json) the overlay is
  # empty and the render is byte-identical to a plain `. + {hooks}`.
  local live="$TARGET/settings.json" overlay='{}'
  if [ -z "${AI_CONFIG_SKIP_PRESERVE_LIVE:-}" ] && [ -f "$live" ] \
     && jq -e 'type == "object"' "$live" >/dev/null 2>&1; then
    # enabledPlugins is plugin-id -> boolean; keep only boolean-valued entries so
    # a malformed/hostile nested value can't ride through into the render. theme +
    # effortLevel are scalar string preferences; preserve only when they parse as
    # strings so a hostile non-string value can't ride through.
    overlay="$(jq -c '
        (if (has("enabledPlugins") and (.enabledPlugins | type == "object"))
           then {enabledPlugins: (.enabledPlugins | with_entries(select(.value | type == "boolean")))}
           else {} end)
      + (if has("agentPushNotifEnabled") then {agentPushNotifEnabled} else {} end)
      + (if has("inputNeededNotifEnabled") then {inputNeededNotifEnabled} else {} end)
      + (if (has("theme") and (.theme | type == "string")) then {theme} else {} end)
      + (if (has("effortLevel") and (.effortLevel | type == "string")) then {effortLevel} else {} end)
    ' "$live")" || overlay='{}'
  fi

  jq --argjson hooks "$hooks_json" --argjson overlay "$overlay" \
    '. + $overlay + {hooks: $hooks}' "$base" \
    > "$BUILD/settings.json" || die "failed to generate settings.json"
}

# generate_codex_hooks — emits a fully-generated $BUILD/hooks.json from the
# HOOK_BLOCKS accumulator. The event->matcher->handler shape mirrors Codex's
# native hooks.json (Codex auto-loads $CODEX_HOME/hooks.json). The hook `command`
# is the absolute path of the script in the FINAL target, so it is correct
# post-swap. Codex hooks.json entries carry no `args` array (that is Claude's
# settings.json shape).
generate_codex_hooks() {
  local hooks_json='{}' event matcher script entry
  while IFS="$HOOK_REC_SEP" read -r event matcher script; do
    [ -n "$event" ] || continue
    entry="$(jq -n \
      --arg matcher "$matcher" \
      --arg command "$TARGET/hooks/$script" \
      '{matcher: $matcher, hooks: [{type: "command", command: $command, timeout: 10}]}')"
    # Append the entry to the event's array (creating the array if absent).
    hooks_json="$(printf '%s' "$hooks_json" | jq \
      --arg event "$event" --argjson entry "$entry" \
      '.[$event] = ((.[$event] // []) + [$entry])')"
  done <<< "$HOOK_BLOCKS"

  jq -n --argjson hooks "$hooks_json" '{hooks: $hooks}' \
    > "$BUILD/hooks.json" || die "failed to generate hooks.json"
}

# generate_hermes_hooks — Hermes's config.yaml is user-owned (operator model /
# provider / platform config), so the build cannot write the `hooks:` block in
# place. Instead it (a) emits hooks/hooks.yaml — the exact copy-paste snippet,
# derived from the same HOOK_BLOCKS accumulator so wiring can never drift from
# the registered hooks — and (b) copies the agentic-os-hook-bridge plugin into
# plugins/ (the desktop app's dashboard entrypoint does not register shell
# hooks natively; the plugin restores parity — adapter.md Fact 2).
generate_hermes_hooks() {
  local event matcher script
  {
    printf '# Generated by install.sh --harness hermes — DO NOT hand-edit.\n'
    printf '# Merge this block into %s/config.yaml (hooks: + plugins.enabled),\n' "$TARGET"
    printf '# then approve the hooks on first use (TTY prompt or --accept-hooks).\n'
    printf 'hooks:\n'
    # Group records by event — YAML forbids duplicate mapping keys, so each
    # event header is emitted once with every matching entry under it.
    local seen_events="" ev2 m2 s2
    while IFS="$HOOK_REC_SEP" read -r event matcher script; do
      [ -n "$event" ] || continue
      case "$seen_events" in *" $event "*) continue ;; esac
      seen_events="$seen_events $event "
      printf '  %s:\n' "$event"
      while IFS="$HOOK_REC_SEP" read -r ev2 m2 s2; do
        [ "$ev2" = "$event" ] || continue
        if [ -n "$m2" ]; then
          printf '    - matcher: "%s"\n' "$m2"
          printf '      command: "%s/hooks/%s"\n' "$TARGET" "$s2"
        else
          printf '    - command: "%s/hooks/%s"\n' "$TARGET" "$s2"
        fi
      done <<< "$HOOK_BLOCKS"
    done <<< "$HOOK_BLOCKS"
    printf 'plugins:\n'
    printf '  enabled:\n'
    printf '    - agentic-os-hook-bridge\n'
  } > "$BUILD/hooks/hooks.yaml"

  mkdir -p "$BUILD/plugins"
  cp -R "$repo_root/harnesses/hermes/plugins/agentic-os-hook-bridge" \
    "$BUILD/plugins/agentic-os-hook-bridge" \
    || die "failed to copy the agentic-os-hook-bridge plugin"
}

# write_manifest — writes <build>/.build-manifest.json with sha256 of every
# source input and every generated output. Deterministic: no timestamps; keys
# sorted by jq so repeated builds are byte-identical.
write_manifest() {
  local src_pairs="" gen_pairs="" f rel

  # Source inputs: capability specs, realizations, hook scripts, adapter, and
  # base settings (settings.base.json is claude-only — skipped for codex).
  for f in \
    "$repo_root"/capabilities/*.md \
    "$repo_root/harnesses/$HARNESS"/capabilities/*.md \
    "$repo_root/harnesses/$HARNESS"/hooks/*.sh \
    "$repo_root/harnesses/$HARNESS/adapter.md" \
    "$repo_root/harnesses/$HARNESS/settings.base.json"
  do
    [ -f "$f" ] || continue
    rel="${f#"$repo_root"/}"
    src_pairs="${src_pairs}$(printf '%s\t%s\n' "$rel" "$(sha256 "$f")")"$'\n'
  done

  # Entrypoint templates — per-harness (claude has CLAUDE + SKILLS, codex AGENTS).
  local ep tmpl
  for ep in $ENTRYPOINTS; do
    tmpl="$repo_root/harnesses/$HARNESS/${ep%:*}"
    [ -f "$tmpl" ] || continue
    rel="${tmpl#"$repo_root"/}"
    src_pairs="${src_pairs}$(printf '%s\t%s\n' "$rel" "$(sha256 "$tmpl")")"$'\n'
  done

  # Vendored-skill snapshots are first-class build inputs (compile_vendored
  # installs them verbatim) — hash every file under them so a hand-edit to a
  # committed snapshot registers as source drift.
  if [ -d "$repo_root/harnesses/$HARNESS/vendored" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rel="${f#"$repo_root"/}"
      src_pairs="${src_pairs}$(printf '%s\t%s\n' "$rel" "$(sha256 "$f")")"$'\n'
    done < <(find "$repo_root/harnesses/$HARNESS/vendored" -type f | sort)
  fi

  # Harness plugin sources (hermes: agentic-os-hook-bridge) are installed
  # verbatim — hash every file so a hand-edit registers as source drift.
  if [ -d "$repo_root/harnesses/$HARNESS/plugins" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rel="${f#"$repo_root"/}"
      src_pairs="${src_pairs}$(printf '%s\t%s\n' "$rel" "$(sha256 "$f")")"$'\n'
    done < <(find "$repo_root/harnesses/$HARNESS/plugins" -type f | sort)
  fi

  # Generated outputs: everything in the build dir except the manifest itself.
  while IFS= read -r f; do
    rel="${f#"$BUILD"/}"
    gen_pairs="${gen_pairs}$(printf '%s\t%s\n' "$rel" "$(sha256 "$f")")"$'\n'
  done < <(find "$BUILD" -type f ! -name '.build-manifest.json' | sort)

  # Build {path: hash} objects via jq from tab-separated lines.
  local to_obj='reduce (.[] | select(length>0) | split("\t")) as $p ({}; .[$p[0]] = $p[1])'
  local src_json gen_json
  src_json="$(printf '%s' "$src_pairs" | jq -R -s "split(\"\n\") | $to_obj")"
  gen_json="$(printf '%s' "$gen_pairs" | jq -R -s "split(\"\n\") | $to_obj")"

  jq -n -S \
    --arg harness "$HARNESS" \
    --arg adapterVersion "$(sha256 "$adapter")" \
    --argjson sources "$src_json" \
    --argjson generated "$gen_json" \
    '{harness: $harness, adapterVersion: $adapterVersion, sources: $sources, generated: $generated}' \
    > "$BUILD/.build-manifest.json"
}
# validate_build filled below in Step 2
# swap_in <name> — atomically replaces $TARGET/<name> with $BUILD/<name>.
# Existing content is moved to $TARGET/.install-bak.<name>; main() removes the
# backups only after every swap has succeeded.
#
# Special case: when <name> is "skills", the swap is **per-subdir** instead of
# a wholesale dir replace. Each compiled $BUILD/skills/<base>/ replaces its
# counterpart at $TARGET/skills/<base>/; any subdir of $TARGET/skills/ that
# the build did not produce — i.e. Shape C operator-authored skills from the
# <TEAM>-55 three-shape model — is preserved. Per-subdir backups go under a
# run-private root OUTSIDE the live skills/ tree at
# $TARGET/.install-bak.d/skills/<base>/ — NOT inside $TARGET/skills/.
# This keeps the backup namespace off the live tree so an operator-authored
# Shape C skill literally named `.install-bak.*` is never mistaken for an
# installer backup by the swap, cleanup, or rollback paths. rollback_swaps and
# the post-swap cleanup loop key off this exact root, never a glob of skills/.
swap_in() {
  local name="$1"
  # <TEAM>-147 test seam: deterministic rollback induction for the parity tests.
  # When this env var names a managed path, that path's swap fails, exercising
  # the real rollback_swaps caller path. Test-only — production callers never
  # set it, and a forced failure only triggers a clean rollback (never any
  # destructive behavior).
  if [ "${AI_CONFIG_INSTALL_TEST_FAIL_SWAP:-}" = "$name" ]; then
    return 1
  fi
  [ -e "$BUILD/$name" ] || return 0
  if [ "$name" = "skills" ]; then
    # <TEAM>-68 / Codex F-1: compute orphans (skill subdirs the OLD manifest
    # managed but the NEW build no longer produces) BEFORE the per-subdir swap.
    # Without this, a framework removal (like this PR's cross-model-review
    # removal) would leave the old rendered SKILL.md lingering in $TARGET/skills/
    # and the new check-drift Shape C exemption would silently mask it as if it
    # were operator-local. The $TARGET/.build-manifest.json still holds the OLD
    # content here (it's swapped later in the MANAGED_PATHS order); the NEW
    # manifest is already at $BUILD/.build-manifest.json from write_manifest.
    local orphans=""
    if [ -f "$TARGET/.build-manifest.json" ] && [ -f "$BUILD/.build-manifest.json" ] && command -v jq >/dev/null 2>&1; then
      local old_managed new_managed
      old_managed="$(jq -r '.generated | keys[] | select(startswith("skills/")) | split("/")[1]' "$TARGET/.build-manifest.json" 2>/dev/null | sort -u)"
      new_managed="$(jq -r '.generated | keys[] | select(startswith("skills/")) | split("/")[1]' "$BUILD/.build-manifest.json" 2>/dev/null | sort -u)"
      orphans="$(comm -23 <(printf '%s\n' "$old_managed") <(printf '%s\n' "$new_managed"))"
    fi

    mkdir -p "$TARGET/skills"
    # <TEAM>-147: per-subdir backups go to a run-private root OUTSIDE skills/ so an
    # operator skill named `.install-bak.*` is never treated as a backup. main()
    # recovers + removes any leftover .install-bak.d from a crashed prior run
    # before the swap loop, so the root is fresh here (no stale same-base
    # collision — hence no pre-delete of a per-subdir backup is needed).
    local bak_root="$TARGET/.install-bak.d"
    mkdir -p "$bak_root/skills"
    local sub base
    for sub in "$BUILD/skills"/*/; do
      [ -d "$sub" ] || continue       # nullglob: no matches → literal pattern, skip
      base="$(basename "$sub")"
      if [ -e "$TARGET/skills/$base" ]; then
        mv "$TARGET/skills/$base" "$bak_root/skills/$base" || return 1
      fi
      mv "$BUILD/skills/$base" "$TARGET/skills/$base" || return 1
    done

    # Orphan cleanup runs only after every per-subdir swap succeeded; if any mv
    # above returned non-zero we exited early and never reached here, so
    # rollback_swaps still operates on a coherent .install-bak.* state.
    #
    # Hash gate: only delete an orphan subdir if at least one manifest-tracked
    # file under it exists on disk AND every manifest-tracked file in it still
    # matches the OLD manifest's recorded hash. If the operator has hand-
    # modified the rendered content (e.g. pre-written a Shape C SKILL.md over
    # the bloated framework version, like the <TEAM>-68 cross-model-review
    # migration itself does on the authoring machine), preserve the subdir.
    # Untouched stale framework content is the only thing that gets deleted.
    #
    # <TEAM>-107 hardening: $orphan is derived from `split("/")[1]` of a manifest
    # key; if the manifest is hand-edited (the only realistic way this is
    # exploitable, since install.sh writes the manifest itself), the second
    # path segment could be `.`, `..`, contain a slash, control characters,
    # whitespace, a leading `.install-bak.` prefix, or the exact backup
    # sentinel `.install-bak.`. None of those should ever survive into a
    # filesystem path on the rm -rf side. Reject the orphan and emit a
    # warning. Also flip all_stale to require POSITIVE hash-validation
    # evidence (a found_match counter) before deletion — an orphan dir with
    # zero manifest entries matching `skills/<orphan>/*` (e.g. manifest key
    # shape `skills/<orphan>` with no trailing segment) previously survived
    # the empty inner-loop pass with all_stale at its initial value 1 and got
    # deleted on no evidence.
    #
    # Additional defenses applied during impl review (<TEAM>-107 cross-model
    # adversarial pass):
    #
    # - Reject orphan paths that are symlinks (rm -rf would only remove the
    #   link, but `[ -d ]` follows symlinks for the inner hash validation,
    #   producing ambiguous semantics if the link points outside the install
    #   target). Reject the symlink case explicitly before any filesystem
    #   reads under that path.
    # - Reject mount points (a bind-mount under skills/<orphan> would cause
    #   rm -rf to delete content on a different filesystem; we check
    #   parent/child device-id with stat).
    # - Re-materialize jq's manifest stream once into a temp file and check
    #   jq's exit status — silent failures (corrupt manifest, jq crash) must
    #   skip orphan cleanup entirely, not selectively validate a prefix.
    # - Use `rm -rf --` so a future refactor that strips the path prefix
    #   from $orphan can never let a `-r`/`-i`/`-v` interpretation slip in.
    local orphan rel want_hash got_hash all_stale found_match
    # Stage the manifest into a temp file once; if jq fails to enumerate the
    # OLD manifest, skip orphan cleanup entirely (defense-in-depth: we'd
    # rather LEAVE stale skills than risk a partial validation deleting
    # operator content). The temp file lives under $BUILD which is the
    # mktemp-d build dir already cleaned up by the trap in main().
    local manifest_dump="$BUILD/.orphan-manifest.tsv"
    if ! jq -r '.generated | to_entries[] | "\(.key)\t\(.value)"' \
        "$TARGET/.build-manifest.json" > "$manifest_dump" 2>/dev/null; then
      printf 'install.sh: manifest enumeration failed; skipping orphan cleanup\n' >&2
      return 0
    fi
    # Read orphans line-by-line (NOT `for orphan in $orphans`) — bash word-
    # splitting on $IFS would split a name containing embedded newline / tab
    # into two innocent-looking iterations that each pass the validation
    # guards below, bypassing the control-char rejection. `IFS=` + `read -r`
    # treats the whole line as one value; we then explicitly reject any name
    # that contains control bytes or whitespace via the guards below. (Note:
    # an LF *inside* a manifest key still produces two output lines from jq,
    # so the LF half-names appear as separate orphans here — they're caught
    # by the empty-evidence guard below since no manifest entry matches
    # `skills/<half-name>/*`.)
    while IFS= read -r orphan; do
      [ -n "$orphan" ] || continue
      # <TEAM>-107: reject unsafe orphan names BEFORE any filesystem touch.
      # Each rejection class corresponds to an attack vector documented in the
      # <TEAM>-99 cross-model adversarial review F-8 (Codex).
      # Control/whitespace check FIRST so we report the precise class
      # (otherwise a `.install-bak.<TAB>foo` name would be reported as
      # backup-prefix instead of control-char).
      if printf '%s' "$orphan" | LC_ALL=C grep -q '[[:cntrl:][:space:]]'; then
        printf 'install.sh: unsafe orphan name skipped (control/whitespace): %q\n' "$orphan" >&2
        continue
      fi
      case "$orphan" in
        .|..)
          printf 'install.sh: unsafe orphan name skipped (path-traversal): %q\n' "$orphan" >&2
          continue
          ;;
        */*)
          printf 'install.sh: unsafe orphan name skipped (path-separator): %q\n' "$orphan" >&2
          continue
          ;;
        .install-bak.|.install-bak.*)
          printf 'install.sh: unsafe orphan name skipped (in-flight backup prefix): %q\n' "$orphan" >&2
          continue
          ;;
      esac
      # Reject symlinks. `rm -rf` on a symlink removes only the link, but the
      # inner hash validation (which uses `[ -f "$TARGET/$rel" ]`) follows the
      # symlink; that asymmetry is ambiguous and not what the hash gate is
      # designed to handle.
      if [ -L "$TARGET/skills/$orphan" ]; then
        printf 'install.sh: unsafe orphan name skipped (symlink): %q\n' "$orphan" >&2
        continue
      fi
      [ -d "$TARGET/skills/$orphan" ] || continue
      # Reject mount points: a bind-mount under skills/<orphan> would point
      # `rm -rf` at another filesystem. Compare device-id with the parent
      # skills/ dir. Cross-platform stat is tricky:
      #
      #   - GNU stat (Linux): `stat -c %d <path>` returns device-id. `-f` on
      #     GNU stat selects filesystem stats (different semantics — `%d` then
      #     means free-blocks), so we must try `-c` FIRST.
      #   - BSD stat (macOS): `stat -f %d <path>` returns device-id. `-c` is
      #     an illegal option (exits non-zero).
      #
      # If both fail (busybox, minimal container, etc.), we skip the check —
      # the mount-point threat is residual-risk per the <TEAM>-107 adversarial
      # review (requires mount-creation privilege which is itself elevated).
      local parent_dev orphan_dev
      parent_dev="$(stat -c %d "$TARGET/skills" 2>/dev/null || stat -f %d "$TARGET/skills" 2>/dev/null || true)"
      orphan_dev="$(stat -c %d "$TARGET/skills/$orphan" 2>/dev/null || stat -f %d "$TARGET/skills/$orphan" 2>/dev/null || true)"
      if [ -n "$parent_dev" ] && [ -n "$orphan_dev" ] && [ "$parent_dev" != "$orphan_dev" ]; then
        printf 'install.sh: unsafe orphan name skipped (mount-point): %q\n' "$orphan" >&2
        continue
      fi
      all_stale=1
      found_match=0
      while IFS=$'\t' read -r rel want_hash; do
        [ -n "$rel" ] || continue
        # <TEAM>-147 F6: reject any manifest path with a real `..` component before
        # the prefix match — a hand-edited OLD manifest could otherwise make a
        # `skills/<orphan>/../<elsewhere>` key satisfy the prefix and validate a
        # hash against a file OUTSIDE skills/<orphan>/. Wrapping in slashes means
        # only a true `..` path segment matches (not `foo..bar`/`..foo`/`foo..`).
        case "/$rel/" in */../*) continue ;; esac
        case "$rel" in skills/"$orphan"/*) ;; *) continue ;; esac
        if [ ! -f "$TARGET/$rel" ]; then
          all_stale=0
          break
        fi
        got_hash="$(sha256 "$TARGET/$rel")"
        if [ "$got_hash" != "$want_hash" ]; then
          all_stale=0
          break
        fi
        found_match=1
      done < "$manifest_dump"
      # <TEAM>-107: require POSITIVE hash-validation evidence — at least one
      # manifest entry under skills/$orphan/ must have been validated against
      # its recorded hash. An empty/no-match inner loop is no evidence; the
      # subdir is preserved. `rm -rf --` defends against future refactors
      # that might strip the prefix and let a `-`-prefixed orphan name be
      # interpreted as a flag.
      if [ "$all_stale" -eq 1 ] && [ "$found_match" -eq 1 ]; then
        rm -rf -- "$TARGET/skills/$orphan"
      fi
    done <<< "$orphans"
    return 0
  fi
  if [ -e "$TARGET/$name" ]; then
    rm -rf "$TARGET/.install-bak.$name"
    mv "$TARGET/$name" "$TARGET/.install-bak.$name" || return 1
  fi
  mv "$BUILD/$name" "$TARGET/$name" || return 1
  return 0
}

# rollback_swaps — restore every managed path from its .install-bak.<name>.
# Run when a swap fails mid-sequence: any already-swapped path (and the path
# whose swap just failed) is moved back, leaving the target as it was.
#
# Special case: skills/ uses per-subdir backups under the run-private root
# $TARGET/.install-bak.d/skills/<base>/ (<TEAM>-147 — see swap_in). Rollback
# restores each backed-up subdir, then drops the root. Shape C subdirs (incl.
# any named `.install-bak.*`) were never moved into the root, so they are never
# touched here.
rollback_swaps() {
  local n
  for n in $MANAGED_PATHS; do
    if [ "$n" = "skills" ]; then
      local bak base restore_ok=1
      if [ -d "$TARGET/.install-bak.d/skills" ]; then
        for bak in "$TARGET/.install-bak.d/skills"/*/; do
          [ -d "$bak" ] || continue   # nullglob: no backups present → skip
          base="$(basename "$bak")"
          rm -rf "$TARGET/skills/$base"
          mv "$bak" "$TARGET/skills/$base" || { restore_ok=0; warn "rollback could not restore skills/$base"; }
        done
      fi
      # Codex adversarial <TEAM>-147 F5: only drop the run-private backup root once
      # every restore succeeded — never delete the sole surviving copy on the
      # failure path. If a restore failed, LEAVE .install-bak.d for manual
      # recovery.
      if [ "$restore_ok" -eq 1 ]; then
        rm -rf "$TARGET/.install-bak.d"
      else
        warn "left $TARGET/.install-bak.d after a failed rollback restore"
      fi
      continue
    fi
    if [ -e "$TARGET/.install-bak.$n" ]; then
      rm -rf "$TARGET/$n"
      mv "$TARGET/.install-bak.$n" "$TARGET/$n"
    fi
  done
}

# --- validate_build — sanity-check the temp build before it is swapped in ---
validate_build() {
  # Every managed *.json file the build produced must be valid JSON. The set is
  # harness-specific (claude: settings.json; codex: hooks.json) — derive it from
  # MANAGED_PATHS so this never needs a per-harness branch. A managed JSON file
  # absent from the build is skipped (a stubbed generator may not emit it yet).
  local p
  for p in $MANAGED_PATHS; do
    case "$p" in
      *.json)
        [ -f "$BUILD/$p" ] || continue
        jq empty "$BUILD/$p" 2>/dev/null || die "generated $p is not valid JSON" ;;
    esac
  done
  [ -d "$BUILD/skills" ] || die "build produced no skills/ directory"
  # No unresolved build placeholders may survive into the output.
  if grep -rlE '@@[A-Z_]+@@' "$BUILD" 2>/dev/null | grep -q .; then
    die "unresolved @@PLACEHOLDER@@ tokens in build output"
  fi
}

# --- main flow -----------------------------------------------------------
main() {
  local cap base fm harnesses kind
  for cap in "$repo_root"/capabilities/*.md; do
    base="$(basename "$cap" .md)"
    [ "$base" = "README" ] && continue
    fm="$(fm_block "$cap")"
    harnesses="$(fm_get "$fm" harnesses | tr -d '[]' | tr ',' ' ')"
    case " $harnesses " in *" $HARNESS "*) ;; *) continue;; esac
    kind="$(fm_get "$fm" kind)"
    if [ "$kind" = "native" ]; then
      compile_native "$base" "$cap" "$fm"
    else
      compile_vendored "$base"
    fi
  done

  # framework-surface is a non-capability hook — wired unconditionally. The
  # event name and matcher are harness-native: claude/codex fire SessionStart
  # with a source matcher; hermes fires pre_llm_call — NOT on_session_start,
  # whose {"context":...} return Hermes discards (fire-and-forget). pre_llm_call
  # is the event whose context is injected into the user message; the hook
  # self-gates to the first turn via .extra.is_first_turn. No matcher (matchers
  # apply to pre/post_tool_call events only). See harnesses/hermes/adapter.md Fact 2.
  case "$HARNESS" in
    hermes)
      install_hook "framework-surface.sh" "pre_llm_call" ""
      # Autonomy-governance hooks (hermes-only). All wired DISABLED-BY-DEFAULT
      # or hard-gated: the drain is inert without its enablement flag file, the
      # skill gate blocks mutations pending a consumed per-use approval marker,
      # and the memory sanitize only refuses hostile injection shapes. The
      # steward is copied but NEVER scheduled — cron registration is a
      # deliberate operator act (same enablement gate as the drain).
      install_hook "autonomy-drain.sh" "on_session_end" ""
      install_hook "memory-sanitize.sh" "pre_tool_call" "memory"
      install_hook "skill-gate.sh" "pre_tool_call" "skill_manage"
      install_hook_script_only "steward.sh"
      ;;
    *)      install_hook "framework-surface.sh" "SessionStart" "startup|clear|compact" ;;
  esac

  # Generate the harness entrypoint files from their templates plus the
  # capability-derived catalog. ENTRYPOINTS is per-harness.
  local catalog ep tmpl out
  catalog="$(generate_capability_catalog)"
  for ep in $ENTRYPOINTS; do
    tmpl="${ep%:*}"; out="${ep#*:}"
    compile_entrypoint "$repo_root/harnesses/$HARNESS/$tmpl" "$out" "$catalog"
  done

  # Wire the accumulated hooks into the harness's native config file.
  case "$HARNESS" in
    claude) generate_settings ;;
    codex)  generate_codex_hooks ;;
    hermes) generate_hermes_hooks ;;
  esac
  write_manifest
  validate_build

  if [ "$BUILD_ONLY" -eq 1 ]; then
    printf '%s\n' "$BUILD"
    trap - EXIT          # keep the build dir for inspection
    return 0
  fi

  # <TEAM>-147: a leftover $TARGET/.install-bak.d means a prior install crashed
  # mid-swap (a skill was moved into the run-private backup root but its
  # replacement was never moved into place). Recover conservatively BEFORE the
  # swap loop: restore any backed-up skill whose live counterpart is now
  # missing, then drop the root. A live counterpart that still exists means that
  # subdir's swap completed before the crash, so its backup is stale and
  # discarded. This makes install crash-safe without ever losing skill content
  # — never a blind delete of the only surviving copy.
  if [ -d "$TARGET/.install-bak.d/skills" ]; then
    local rbak rbase recover_ok=1
    for rbak in "$TARGET/.install-bak.d/skills"/*/; do
      [ -d "$rbak" ] || continue
      rbase="$(basename "$rbak")"
      if [ ! -e "$TARGET/skills/$rbase" ]; then
        mv "$rbak" "$TARGET/skills/$rbase" || { recover_ok=0; warn "could not restore skills/$rbase from an interrupted prior install"; }
      fi
    done
    # Codex adversarial <TEAM>-147 F2: never delete the run-private backup root
    # after a FAILED restore — that would discard the sole surviving copy.
    # Abort instead and leave .install-bak.d in place for manual recovery
    # rather than proceeding from a half-restored state.
    if [ "$recover_ok" -ne 1 ]; then
      die "interrupted prior install could not be recovered; $TARGET/.install-bak.d left in place — restore its skills/* subdirs manually, then re-run"
    fi
  fi
  rm -rf "$TARGET/.install-bak.d"

  for name in $MANAGED_PATHS; do
    if ! swap_in "$name"; then
      warn "swap failed for '$name' — rolling back to pre-install state"
      rollback_swaps
      die "install aborted; target restored to its pre-install state"
    fi
  done
  # All swaps succeeded — drop the backups. skills/ uses the run-private backup
  # root $TARGET/.install-bak.d/ (<TEAM>-147 — see swap_in); removing it by its
  # exact path never touches an operator skill named `.install-bak.*`.
  for name in $MANAGED_PATHS; do
    if [ "$name" = "skills" ]; then
      rm -rf "$TARGET/.install-bak.d"
      continue
    fi
    rm -rf "$TARGET/.install-bak.$name"
  done
  printf 'install.sh: built %s harness into %s\n' "$HARNESS" "$TARGET" >&2

  # The codex build is inert until the user trusts the generated hooks.json:
  # Codex does not run a non-managed hooks.json until trusted via the
  # interactive `/hooks` command. install.sh cannot trust hooks on the user's
  # behalf, so it surfaces the step (adapter.md Fact 2 documents it as surfaced).
  if [ "$HARNESS" = codex ]; then
    printf 'install.sh: NEXT STEP — run the interactive `/hooks` command in codex once\n' >&2
    printf '            to review and trust %s/hooks.json; until trusted, the\n' "$TARGET" >&2
    printf '            enforcement hooks will not run. (codex exec runs no hooks at all.)\n' >&2
  fi

  # The hermes build is inert until the operator merges the generated wiring
  # into the user-owned config.yaml and consents to the hooks (first-use
  # allowlist). Re-renders rewrite the hook scripts, which invalidates prior
  # consent (the allowlist is mtime-pinned) — re-approve after every install.
  if [ "$HARNESS" = hermes ]; then
    printf 'install.sh: NEXT STEP — merge %s/hooks/hooks.yaml into %s/config.yaml\n' "$TARGET" "$TARGET" >&2
    printf '            (hooks: block + plugins.enabled), then approve the hooks on first\n' >&2
    printf '            use (TTY prompt or `hermes --accept-hooks`); re-approval is needed\n' >&2
    printf '            after every re-render. The agentic-os-hook-bridge plugin restores\n' >&2
    printf '            hook firing in the desktop app (its dashboard entrypoint does not\n' >&2
    printf '            register config.yaml shell hooks natively).\n' >&2
  fi
}

main
