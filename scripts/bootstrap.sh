#!/usr/bin/env bash
# bootstrap.sh — sets up a fresh macOS machine for the agentic OS.
#
# Usage: bootstrap.sh [--harness <name>] [--check] [--dry-run]
#                     [--claude-config-dir <dir>] [--vault-dir <dir>]
#                     [--codex-home <dir>] [-h|--help]
#
#   --harness <name>         target harness: claude, codex (repeatable; default: claude)
#   --check                  read-only — detect requirements, report, exit non-zero on failures
#   --dry-run                print mutations without executing them
#   --claude-config-dir <dir>  override CLAUDE_CONFIG_DIR (takes precedence over local.env)
#   --vault-dir <dir>          override OBSIDIAN_VAULT_PATH
#   --codex-home <dir>         override CODEX_HOME
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HARNESSES=()
CHECK=0
DRY_RUN=0
OPT_CLAUDE_CONFIG_DIR=""
OPT_VAULT_DIR=""
OPT_CODEX_HOME=""

die()  { printf 'bootstrap.sh: ERROR: %s\n' "$1" >&2; exit 1; }
warn() { printf 'bootstrap.sh: WARNING: %s\n' "$1" >&2; }
info() { printf 'bootstrap.sh: %s\n' "$1"; }

# would_mutate <desc> — returns 0 (skip mutation) in --check/--dry-run modes.
# In --dry-run prints the description; in --check is silent.
would_mutate() {
  if [ "$CHECK" -eq 1 ]; then return 0; fi
  if [ "$DRY_RUN" -eq 1 ]; then info "DRY-RUN: $1"; return 0; fi
  return 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --harness)           HARNESSES+=("${2:?--harness needs a value}"); shift 2 ;;
    --check)             CHECK=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --claude-config-dir) OPT_CLAUDE_CONFIG_DIR="${2:?--claude-config-dir needs a value}"; shift 2 ;;
    --vault-dir)         OPT_VAULT_DIR="${2:?--vault-dir needs a value}"; shift 2 ;;
    --codex-home)        OPT_CODEX_HOME="${2:?--codex-home needs a value}"; shift 2 ;;
    -h|--help)           grep -E '^#' "$0" | head -12 | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'bootstrap.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ "${#HARNESSES[@]}" -eq 0 ] && HARNESSES=("claude")

# cli_min_version <name> — returns the pinned minimum, or "presence" for any version.
cli_min_version() {
  case "$1" in
    codex)     echo "0.132.0" ;;
    gh)        echo "2.40.0" ;;
    jq)        echo "1.6.0" ;;
    rg)        echo "13.0.0" ;;
    *)         echo "" ;;
  esac
}

# get_cli_version <name> — extract the semver-ish number from --version output.
# Prints nothing (not empty-string) if the CLI is absent or unparseable.
get_cli_version() {
  local out
  case "$1" in
    jq)   out="$(jq --version 2>/dev/null | sed 's/^jq-//')" ;;
    *)    out="$("$1" --version 2>/dev/null || true)" ;;
  esac
  printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# version_ge v1 v2 — returns 0 if v1 >= v2 (dot-separated numerics).
version_ge() {
  local v1 v2
  v1="$(printf '%s' "$1" | grep -oE '^[0-9]+(\.[0-9]+)*' | head -1)"
  v2="$(printf '%s' "$2" | grep -oE '^[0-9]+(\.[0-9]+)*' | head -1)"
  [ -z "$v1" ] && return 1
  [ -z "$v2" ] && return 0
  awk -v a="$v1" -v b="$v2" 'BEGIN {
    n=split(a,A,"."); m=split(b,B,".")
    for (i=1;i<=3;i++) {
      x=(i<=n)?A[i]+0:0; y=(i<=m)?B[i]+0:0
      if (x>y){print 1;exit} if (x<y){print 0;exit}
    }
    print 1
  }' | grep -q 1
}

# check_clis — verify each required CLI is present and meets the version minimum.
# Exits 0 if all pass; exits 1 if any hard requirement fails.
# Sets global MISSING_CLIS and OUTDATED_CLIS (newline-separated).
MISSING_CLIS=""
OUTDATED_CLIS=""

check_clis() {
  # The framework-REQUIRED CLI set is codex, gh, jq, rg (4). The framework wires
  # no operator tools, so nothing else belongs in this hard-requirement loop — a
  # fresh machine bootstraps with just these four. (Keep this list in lockstep
  # with the entrypoint prose in CLAUDE.md/AGENTS.md per the inventory-coupling rule.)
  local name min got rc=0
  for name in codex gh jq rg; do
    min="$(cli_min_version "$name")"
    if ! command -v "$name" >/dev/null 2>&1; then
      warn "$name: not found (required)"
      MISSING_CLIS="${MISSING_CLIS}${name}"$'\n'
      rc=1
    elif [ "$min" = "presence" ]; then
      info "$name: present (presence-only)"
    else
      got="$(get_cli_version "$name")"
      if version_ge "${got:-0}" "$min"; then
        info "$name: ${got:-unknown} >= $min"
      else
        warn "$name: ${got:-unknown} < $min (need $min)"
        OUTDATED_CLIS="${OUTDATED_CLIS}${name} (has ${got:-unknown}, need $min)"$'\n'
        rc=1
      fi
    fi
  done
  return $rc
}

# check_auth — check auth/key readiness. Warnings only; non-fatal.
# Returns 1 if any auth check fails (so main() can decide whether to block).
check_auth() {
  local rc=0
  # gh auth
  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      info "gh: authenticated"
    else
      warn "gh: not authenticated — run: gh auth login"
      rc=1
    fi
  fi
  return $rc
}
# install_clis — install any missing or outdated CLIs via Homebrew (macOS).
# Relies on MISSING_CLIS and OUTDATED_CLIS set by check_clis.
# In --dry-run: prints brew/npm commands without running them.
install_clis() {
  # Build a combined list of CLI names needing installation.
  local need="" name
  while IFS= read -r name; do
    [ -n "$name" ] && need="${need}${name%%[[:space:]]*}"$'\n'
  done <<< "${MISSING_CLIS}${OUTDATED_CLIS}"
  [ -z "$(printf '%s' "$need" | tr -d '[:space:]')" ] && return 0

  # Homebrew formula for standard CLIs.
  cli_brew_formula() {
    case "$1" in
      gh) echo "gh" ;;
      jq) echo "jq" ;;
      rg) echo "ripgrep" ;;
      *)  echo "" ;;
    esac
  }

  # npm package for node-installed CLIs. Package names verified 2026-05-22
  # against the global npm install on the reference machine (<TEAM>-40 Task 4.1).
  cli_npm_pkg() {
    case "$1" in
      codex)     echo "@openai/codex" ;;
      *)         echo "" ;;
    esac
  }

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    local formula pkg
    formula="$(cli_brew_formula "$name")"
    pkg="$(cli_npm_pkg "$name")"
    if [ -n "$formula" ]; then
      if would_mutate "brew install $formula"; then continue; fi
      command -v brew >/dev/null 2>&1 || die "Homebrew not found — install from https://brew.sh"
      brew install "$formula"
    elif [ -n "$pkg" ]; then
      if would_mutate "npm install -g $pkg"; then continue; fi
      command -v npm >/dev/null 2>&1 || die "npm not found — install Node.js from https://nodejs.org"
      npm install -g "$pkg"
    else
      warn "$name: no automated install method — install manually, then re-run bootstrap."
    fi
  done <<< "$need"
}
# set_config_dir_env <dir> — idempotently export CLAUDE_CONFIG_DIR in ~/.zshenv.
# Removes any existing CLAUDE_CONFIG_DIR line then appends the canonical form.
set_config_dir_env() {
  local config_dir="${1:-}"
  [ -n "$config_dir" ] || { warn "CLAUDE_CONFIG_DIR not set — skipping ~/.zshenv write"; return 0; }
  local zshenv="$HOME/.zshenv"
  # Already correct?
  local export_line
  export_line="$(printf 'export CLAUDE_CONFIG_DIR=%q' "$config_dir")"
  if grep -qxF "$export_line" "$zshenv" 2>/dev/null; then
    info "CLAUDE_CONFIG_DIR already set in $zshenv"
    return 0
  fi
  would_mutate "write '$export_line' to $zshenv" && return 0
  local tmp; tmp="$(mktemp)"
  # Remove any existing CLAUDE_CONFIG_DIR line, then append.
  if [ -f "$zshenv" ]; then
    grep -vE "^(export )?CLAUDE_CONFIG_DIR=" "$zshenv" > "$tmp" || true
  fi
  printf '%s\n' "$export_line" >> "$tmp"
  mv "$tmp" "$zshenv"
  info "Set CLAUDE_CONFIG_DIR in $zshenv"
}
# seed_local_env — create local.env from the template if it does not exist.
# In non-interactive mode (tests), values come from env vars / --flags.
seed_local_env() {
  local local_env="$repo_root/local.env"
  local tmpl="$repo_root/templates/local.env.example"
  if [ -f "$local_env" ]; then
    info "local.env already exists — skipping template copy."
    return 0
  fi
  would_mutate "copy $tmpl → $local_env" && return 0
  [ -f "$tmpl" ] || die "Template not found: $tmpl"
  cp "$tmpl" "$local_env"
  info "Created $local_env from template."
  info "Next: fill in the required values in $local_env"
  info "  CLAUDE_CONFIG_DIR     — path to your claude-config directory"
  info "  CODEX_HOME            — path to your codex config (~/.codex)"
  info "  OBSIDIAN_VAULT_PATH   — path to your Obsidian vault"
  if [ -t 0 ]; then
    printf 'bootstrap.sh: Edit %s now, then press Enter to continue: ' "$local_env"
    read -r _
  else
    info "(non-interactive mode — fill in $local_env then re-run bootstrap.)"
  fi
}
# persist_local_env_values — write the in-memory resolved values back into
# local.env so the install children read correct values when they re-source it.
#
# <TEAM>-133: bootstrap seeds local.env from a template whose value lines are EMPTY,
# then install.sh re-sources that file — clobbering the in-memory values that came
# from --flags / the environment. `--out` covers only the build TARGET; install.sh
# ALSO substitutes OBSIDIAN_VAULT_PATH (and, for --harness codex, CODEX_HOME) from
# the re-sourced local.env and dies on the empty-placeholder gate. There is no
# install.sh flag for the vault path, so the only complete fix is to materialise
# the resolved values into local.env itself. Idempotent: replaces each KEY= line
# in place (or appends if absent). Quotes via printf %q so paths with spaces / &
# round-trip when install.sh sources the file. Only writes keys with a value.
persist_local_env_values() {
  local local_env="$repo_root/local.env"
  [ -f "$local_env" ] || return 0
  would_mutate "write resolved values into $local_env" && return 0
  local key val tmp wrote
  for key in CLAUDE_CONFIG_DIR CODEX_HOME OBSIDIAN_VAULT_PATH; do
    eval "val=\"\${$key:-}\""
    [ -n "$val" ] || continue
    tmp="$(mktemp)"
    wrote=0
    # Replace an existing (possibly empty) KEY= line; remove `export ` prefix
    # variants too so we don't end up with duplicate declarations.
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "${key}="*|"export ${key}="*)
          if [ "$wrote" -eq 0 ]; then
            printf '%s=%q\n' "$key" "$val" >> "$tmp"
            wrote=1
          fi
          ;;
        *) printf '%s\n' "$line" >> "$tmp" ;;
      esac
    done < "$local_env"
    [ "$wrote" -eq 0 ] && printf '%s=%q\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$local_env"
  done
}
# run_install — run install.sh for each harness.
#
# <TEAM>-133: pass the in-memory resolved build target as `--out` to each child.
# bootstrap seeds local.env from a template whose CLAUDE_CONFIG_DIR / CODEX_HOME
# lines are EMPTY, then install.sh re-sources that seeded local.env. Without
# `--out`, the child sees the empty value and dies at install.sh:90 — even though
# bootstrap holds the correct target in memory (from a --flag, the environment,
# or a pre-filled local.env). `--out` takes precedence over the per-harness env
# var inside install.sh, so forwarding it makes the first-run install succeed.
run_install() {
  local h target
  for h in "${HARNESSES[@]}"; do
    case "$h" in
      claude) target="${CLAUDE_CONFIG_DIR:-}" ;;
      codex)  target="${CODEX_HOME:-}" ;;
      *)      target="" ;;
    esac
    local out_args=()
    [ -n "$target" ] && out_args=(--out "$target")
    info "Running install.sh --harness $h${target:+ --out $target} ..."
    would_mutate "bash $repo_root/scripts/install.sh --harness $h${target:+ --out $target}" && continue
    # macOS ships bash 3.2 where "${arr[@]}" on an empty array under `set -u`
    # raises "unbound variable"; the `+`-expansion guard is the portable idiom.
    bash "$repo_root/scripts/install.sh" --harness "$h" "${out_args[@]+"${out_args[@]}"}" \
      || die "install.sh failed for harness $h"
  done
}

# smoke_test — validate.sh + confirm generated output + sync-conflict check.
smoke_test() {
  info "Running smoke tests..."
  bash "$repo_root/scripts/validate.sh" || die "validate.sh failed"
  local h target ok=0
  for h in "${HARNESSES[@]}"; do
    case "$h" in
      claude) target="${CLAUDE_CONFIG_DIR:-}" ;;
      codex)  target="${CODEX_HOME:-}" ;;
    esac
    if [ -z "$target" ]; then
      warn "harness $h: target dir unknown — skipping output check"
    elif [ -f "$target/CLAUDE.md" ] || [ -f "$target/AGENTS.md" ]; then
      info "harness $h: entrypoint present in $target"
    else
      warn "harness $h: entrypoint not found in $target — run install.sh"
      ok=1
    fi
  done
  # Detect Google Drive sync-conflict files in the vault.
  if [ -n "${OBSIDIAN_VAULT_PATH:-}" ] && [ -d "${OBSIDIAN_VAULT_PATH}" ]; then
    local conflicts
    conflicts="$(find "$OBSIDIAN_VAULT_PATH" -name "*.sync-conflict*" 2>/dev/null | head -5 || true)"
    if [ -n "$conflicts" ]; then
      warn "Google Drive sync-conflict files detected — resolve before relying on vault context:"
      printf '%s\n' "$conflicts" >&2
    fi
  fi
  [ "$ok" -eq 0 ] && info "Smoke tests passed."
  return $ok
}

# print_auth_checklist — manual steps to complete after bootstrap.
print_auth_checklist() {
  printf '\n=========================================\n'
  printf ' Manual auth steps (complete after setup)\n'
  printf '=========================================\n'
  printf '  1. gh auth login         — GitHub CLI authentication\n'
  printf '  2. codex login           — Codex CLI authentication\n'
  printf '  3. MCP connectors        — connect operator-local servers as needed\n'
  printf '\nDone. Reload your shell: source ~/.zshenv\n\n'
}

main() {
  info "bootstrap.sh — agentic OS machine setup"
  info "Harnesses: ${HARNESSES[*]}"
  [ "$CHECK" -eq 1 ] && info "(check mode — no mutations)"
  [ "$DRY_RUN" -eq 1 ] && info "(dry-run mode — mutations printed only)"

  # Load local.env if present (machine may be partially set up).
  local local_env="$repo_root/local.env"
  if [ -f "$local_env" ]; then
    set -a; . "$local_env"; set +a
  fi
  # CLI-override flags take precedence over local.env.
  [ -n "$OPT_CLAUDE_CONFIG_DIR" ] && CLAUDE_CONFIG_DIR="$OPT_CLAUDE_CONFIG_DIR"
  [ -n "$OPT_VAULT_DIR" ]         && OBSIDIAN_VAULT_PATH="$OPT_VAULT_DIR"
  [ -n "$OPT_CODEX_HOME" ]        && CODEX_HOME="$OPT_CODEX_HOME"

  local exit_code=0
  check_clis || exit_code=1
  check_auth || true   # auth failures are warnings, not hard errors

  if [ "$CHECK" -eq 1 ]; then
    [ "$exit_code" -eq 0 ] && info "All checks passed." \
                             || info "Some checks failed — see warnings above."
    return "$exit_code"
  fi

  install_clis
  seed_local_env
  # <TEAM>-133: materialise the resolved values (from --flags or the environment,
  # merged above at lines 376-378) into the freshly seeded local.env BEFORE the
  # reload below — otherwise `set -a; . local.env` re-sources the template's
  # EMPTY value lines and clobbers any environment-inherited CLAUDE_CONFIG_DIR /
  # OBSIDIAN_VAULT_PATH / CODEX_HOME, leaving install.sh nothing to substitute.
  persist_local_env_values
  # Reload local.env now that it exists (seed may have created it).
  if [ -f "$local_env" ]; then set -a; . "$local_env"; set +a; fi
  [ -n "$OPT_CLAUDE_CONFIG_DIR" ] && CLAUDE_CONFIG_DIR="$OPT_CLAUDE_CONFIG_DIR"
  [ -n "$OPT_VAULT_DIR" ]         && OBSIDIAN_VAULT_PATH="$OPT_VAULT_DIR"
  [ -n "$OPT_CODEX_HOME" ]        && CODEX_HOME="$OPT_CODEX_HOME"
  # Persist CLAUDE_CONFIG_DIR only after local.env is seeded + reloaded, so a
  # value that exists only in the freshly seeded local.env still reaches ~/.zshenv.
  set_config_dir_env "${CLAUDE_CONFIG_DIR:-}"
  run_install
  smoke_test
  print_auth_checklist
}

main

