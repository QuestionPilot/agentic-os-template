#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

printf 'agentic-os-template validation\n'
printf 'Repo: %s\n\n' "$repo_root"

# Harness-managed worktrees (.claude/worktrees/, and the parallel .codex/ and
# .agents/ paths if they ever exist) can legitimately contain .DS_Store from
# macOS Finder visits or unrelated test fixtures. <TEAM>-60 allowlisted the
# worktrees subtree in the forbidden-roots check; this scan does the same so
# `bash scripts/validate.sh` runs clean from main repo root all the way
# through. (<TEAM>-61.)
#
# Gitignored runtime-artifact dirs (cross-model-out/, .codegraph/) are pruned
# the same way. They hold driver-local per-run output that can never enter git,
# so a .DS_Store an operator's Finder dropped inside one is unrelated working
# state, not framework content. check-drift.sh prunes the same gitignored
# runtime set (<TEAM>-87 + <TEAM>-213); this scan and the secret grep below mirror it
# so a tree carrying real cross-model-review runs still validates clean. (<TEAM>-244.)
if find "$repo_root" -name .DS_Store \
    -not -path "$repo_root/.claude/worktrees/*" \
    -not -path "$repo_root/.codex/worktrees/*" \
    -not -path "$repo_root/.agents/worktrees/*" \
    -not -path "$repo_root/cross-model-out/*" \
    -not -path "$repo_root/.codegraph/*" \
    -print -quit | grep -q .; then
  printf 'FAIL .DS_Store files found\n' >&2
  find "$repo_root" -name .DS_Store \
    -not -path "$repo_root/.claude/worktrees/*" \
    -not -path "$repo_root/.codex/worktrees/*" \
    -not -path "$repo_root/.agents/worktrees/*" \
    -not -path "$repo_root/cross-model-out/*" \
    -not -path "$repo_root/.codegraph/*" >&2
  exit 1
fi
printf 'PASS no .DS_Store files\n'

# Embedded .git dirs: prune the root .git (huge, expected) plus the gitignored
# runtime dirs (cross-model-out/, .codegraph/) — a cross-model run that captured
# output from a cloned repo, or a codegraph index, can leave a nested .git there
# that is driver-local, never committable framework content. (<TEAM>-244 extends
# the <TEAM>-61 prune set, mirroring check-drift's gitignored-runtime exclusion.)
if find "$repo_root" -path "$repo_root/.git" -prune -o -name .git -type d \
    -not -path "$repo_root/cross-model-out/*" \
    -not -path "$repo_root/.codegraph/*" \
    -print -quit | grep -q .; then
  printf 'FAIL embedded .git directories found\n' >&2
  find "$repo_root" -path "$repo_root/.git" -prune -o -name .git -type d \
    -not -path "$repo_root/cross-model-out/*" \
    -not -path "$repo_root/.codegraph/*" \
    -print >&2
  exit 1
fi
printf 'PASS no embedded .git directories\n'

# Flat-reject: loose files / dirs that would only land here through hand-edit
# or a misconfigured tool. None are harness-managed at repo root.
for forbidden in \
  "$repo_root/.env" "$repo_root/auth.json" \
  "$repo_root/config.toml" "$repo_root/settings.json" \
  "$repo_root/vault" "$repo_root/codex"; do
  if [ -e "$forbidden" ]; then
    printf 'FAIL forbidden local or legacy artifact present: %s\n' "$forbidden" >&2
    exit 1
  fi
done

# Recognize a deliberately CO-LOCATED harness config dir in the loop below: when
# the operator points a harness's config-dir variable at a directory under the
# repo root (e.g. CLAUDE_CONFIG_DIR=$repo_root/.claude — running every harness
# out of the framework folder), that directory holds the harness's own compiled
# output + runtime state. It is gitignored and never committable, so it is out of
# scope for this leak guard, exactly like the cross-model-out/ / .codegraph/ /
# worktrees/ runtime dirs the scans above already prune. Resolve each configured
# target to a physical path: environment first, then a sourced local.env
# (install.sh / bootstrap.sh read local.env the same way). In the maintainer
# default (~/.claude etc.) and in CI (temp-dir config) none of these equal
# $repo_root/.<harness>, so the reject below still fires on a genuine leak.
cfg_claude="${CLAUDE_CONFIG_DIR:-}"
cfg_codex="${CODEX_HOME:-}"
cfg_hermes="${HERMES_HOME:-}"
if [ -f "$repo_root/local.env" ]; then
  # Source in an isolated subshell (stdin closed) so a side effect, unset-var
  # reference, or stray read in local.env can neither abort this run (set -e),
  # hang it, nor pollute its environment. Only the resolved path is captured.
  if [ -z "$cfg_claude" ]; then
    cfg_claude="$( set +eu; . "$repo_root/local.env" >/dev/null 2>&1 </dev/null; printf '%s' "${CLAUDE_CONFIG_DIR:-}" )"
  fi
  if [ -z "$cfg_codex" ]; then
    cfg_codex="$( set +eu; . "$repo_root/local.env" >/dev/null 2>&1 </dev/null; printf '%s' "${CODEX_HOME:-}" )"
  fi
  if [ -z "$cfg_hermes" ]; then
    cfg_hermes="$( set +eu; . "$repo_root/local.env" >/dev/null 2>&1 </dev/null; printf '%s' "${HERMES_HOME:-}" )"
  fi
fi
# Physical path of a configured config dir ('' when unset or nonexistent).
# ALWAYS returns 0: a non-zero status here would abort validate.sh under
# `set -e` whenever a config var is unset or its dir is absent (the common
# maintainer / CI case, where none of these dirs live at the repo root anyway).
_phys_dir() {
  if [ -n "${1:-}" ]; then
    ( cd "$1" 2>/dev/null && pwd -P ) || true
  fi
  return 0
}
cfg_claude_p="$(_phys_dir "$cfg_claude")"
cfg_codex_p="$(_phys_dir "$cfg_codex")"
cfg_hermes_p="$(_phys_dir "$cfg_hermes")"

# Harness-config dirs (.claude/, .codex/, .hermes/, .agents/) at agentic-os-template repo root
# may contain ONLY framework-development workflow state:
#   worktrees/             — operator's parallel-branch workspaces when
#                           working on agentic-os-template PRs (Claude Code's
#                           EnterWorktree default destination)
#   settings.local.json    — operator-local permission tweaks for the dev
#                           session
#
# Everything else is operator state and belongs in $CLAUDE_CONFIG_DIR (or
# $CODEX_HOME for .codex/) — including per-project CLAUDE.md, settings.json,
# skills/, commands/, hooks/, agents/, plugin caches, MCP tool drop-ins.
# The allowlist is intentionally narrow: any addition requires a conscious
# framework-content-vs-operator-state decision. See <TEAM>-70 + <TEAM>-76.
#
# skills/ is rejected with a security-flavored message (precheck above the
# leaked-find below) because it's the auto-load attack surface from <TEAM>-67
# finding #8 (reference_clone_time_claude_skills): a .claude/skills/
# subtree present in Claude Code's cwd is auto-loaded into the session
# without prompting. Letting it pass validation would silently weaken
# that defense.
for harness_dir in "$repo_root/.claude" "$repo_root/.codex" "$repo_root/.hermes" "$repo_root/.agents"; do
  [ -e "$harness_dir" ] || continue
  if [ ! -d "$harness_dir" ]; then
    printf 'FAIL forbidden harness-config artifact at repo root (not a directory): %s\n' "$harness_dir" >&2
    exit 1
  fi
  # Co-located config target: when this repo-root harness dir IS the operator's
  # configured CLAUDE_CONFIG_DIR / CODEX_HOME / HERMES_HOME, its contents are the
  # harness's own gitignored output + state, not a leaked hand-edit — recognize
  # it and skip the reject. The match is by physical path, so a stray .claude/
  # when the config dir lives elsewhere (the maintainer default) still falls
  # through to the finding-#8 + hand-edit rejects below. (.agents has no config
  # variable, so it never matches and is always guarded.)
  case "$harness_dir" in
    */.claude) _cfg_phys="$cfg_claude_p" ;;
    */.codex)  _cfg_phys="$cfg_codex_p" ;;
    */.hermes) _cfg_phys="$cfg_hermes_p" ;;
    *)         _cfg_phys="" ;;
  esac
  if [ -n "$_cfg_phys" ]; then
    _hd_phys="$(cd "$harness_dir" 2>/dev/null && pwd -P)" || _hd_phys=""
    if [ -n "$_hd_phys" ] && [ "$_hd_phys" = "$_cfg_phys" ]; then
      printf 'PASS co-located harness config dir recognized (out of leak-guard scope): %s\n' "$harness_dir"
      continue
    fi
  fi
  # Security precheck — skills/ at a framework repo root is the auto-load
  # attack surface from <TEAM>-67 finding #8: a .claude/skills/ subtree present
  # in Claude Code's cwd is silently loaded into the session without
  # prompting. Fires before the generic hand-edit branch so the operator
  # sees the security framing.
  if [ -e "$harness_dir/skills" ]; then
    printf 'FAIL security: %s/skills/ at repo root would auto-load into Claude Code sessions\n' "$harness_dir" >&2
    printf '       per <TEAM>-67 finding #8 — skills belong in $CLAUDE_CONFIG_DIR/skills/, never in a framework repo root.\n' >&2
    exit 1
  fi
  # List immediate children (hidden included) outside the allowlist.
  # find's native `! -name` negation avoids a grep pipeline and the `|| true`
  # exit-status mask the earlier pipe-to-grep form required (F-4 cross-model
  # review refactor, Gemini).
  leaked="$(find "$harness_dir" -mindepth 1 -maxdepth 1 \
    ! -name "worktrees" \
    ! -name "settings.local.json" \
    2>/dev/null)"
  if [ -n "$leaked" ]; then
    printf 'FAIL hand-edited harness config at repo root — move to $CLAUDE_CONFIG_DIR / $CODEX_HOME:\n' >&2
    printf '%s\n' "$leaked" | sed 's/^/       /' >&2
    exit 1
  fi
done
printf 'PASS forbidden local and legacy artifacts absent\n'

if ! command -v grep >/dev/null 2>&1; then
  printf 'FAIL grep unavailable; cannot run secret scan\n' >&2
  exit 1
fi
# Secret-pattern scan over the COMMITTABLE set. Enumerate `git ls-files --cached
# --others --exclude-standard` (tracked PLUS untracked-not-gitignored files)
# instead of a raw `grep -r` filesystem walk — mirroring check-drift.sh's <TEAM>-213
# enumeration. This is the root fix the <TEAM>-244 anchored post-filter deferred:
# gitignored runtime artifacts (cross-model-out/, .codegraph/, worktrees/, *.log,
# .mcp.json, the harness .claude/.codex/.agents/ dirs) are pruned by
# --exclude-standard, so a per-run log quoting a key-shaped string can no longer
# false-trip the scan AND every new tool's runtime dir is out of scope
# automatically — no per-dir --exclude maintenance trap. Conversely a TRACKED
# file is ALWAYS scanned even when its NAME matches a gitignore rule (a
# force-added daemon.log / .mcp.json): a committed secret is the only secret a
# leak guard must catch. README.md (documented example key shapes) is the single
# tracked exclusion; .git is never listed by ls-files.
#
# A plain-copy staging/export tree has no .git (so no gitignored runtime state) —
# fall back to the pre-<TEAM>-246 filesystem walk + repo-root-anchored post-filter so
# the scan still runs there. Same dual-path contract as check-drift.sh's
# assert_absent. The pattern is interpolated (not a heredoc literal) and is
# self-non-matching by construction — the `[` after each prefix breaks the
# character class — so validate.sh's own source never self-trips when scanned.
secret_pattern='gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(sk|pk)_live_[A-Za-z0-9]{20,}'

# Git-worktree detection: TOPLEVEL-EQUALITY, not `--is-inside-work-tree`.
# is-inside walks ancestors, so a staging tree nested under an unrelated parent
# repo would take the git path and `ls-files -- .` (relative to the untracked
# staging dir) return EMPTY — the entire leak scan would silently pass. Take the
# git path only when --show-toplevel resolves to repo_root itself. The git call
# is the `if` CONDITION so set -e is suspended (rev-parse exits 128 outside a
# repo). Physical paths (pwd -P) are compared so a /var↔/private symlink never
# misclassifies. (Mirror of check-drift.sh.)
_secret_is_git=0
if _secret_tl="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_secret_tl" ]; then
  _secret_tl_phys="$(cd "$_secret_tl" 2>/dev/null && pwd -P)" || _secret_tl_phys=""
  _secret_rr_phys="$(cd "$repo_root" 2>/dev/null && pwd -P)" || _secret_rr_phys=""
  if [ -n "$_secret_tl_phys" ] && [ "$_secret_tl_phys" = "$_secret_rr_phys" ]; then
    _secret_is_git=1
  fi
fi
unset _secret_tl _secret_tl_phys _secret_rr_phys

secret_hits=""
secret_status=1
if [ "$_secret_is_git" -eq 1 ]; then
  # Committable set, repo-relative pathspec "." (repo_root contains a space, so
  # never pass it as a pathspec). core.quotePath=false: emit non-ASCII names raw
  # so they ARE scanned; a control-char name stays git-quoted (leading ") → fail
  # closed rather than scanning a non-existent path. git failure FAILs the scan
  # rather than yielding an empty list that reads as "no hits → pass".
  set +e
  secret_files_raw="$(git -C "$repo_root" -c core.quotePath=false ls-files --cached --others --exclude-standard -- .)"
  secret_ls_status=$?
  set -e
  if [ "$secret_ls_status" -ne 0 ]; then
    printf 'FAIL secret scan: git ls-files enumeration errored (exit %s); not treating as clean\n' "$secret_ls_status" >&2
    exit 1
  fi
  secret_absfiles=()
  while IFS= read -r secret_f; do
    [ -n "$secret_f" ] || continue
    case "$secret_f" in
      '"'*)
        printf 'FAIL secret scan: cannot safely scan git-quoted path (control char in filename): %s\n' "$secret_f" >&2
        exit 1 ;;
    esac
    # Root README.md (documented example key shapes) is the single tracked
    # exclusion — ROOT-EXACT, not basename: a nested docs/README.md or
    # package README.md carrying a real token must still be scanned.
    [ "$secret_f" = "README.md" ] && continue
    secret_absfiles+=("$repo_root/$secret_f")
  done <<< "$secret_files_raw"
  if [ "${#secret_absfiles[@]}" -gt 0 ]; then
    set +e
    secret_hits="$(grep -EHn -e "$secret_pattern" -- "${secret_absfiles[@]}")"
    secret_status=$?
    set -e
  fi
else
  # Non-git fallback: filesystem walk + repo-root-anchored post-filter
  # (pre-<TEAM>-246 behavior). grep --exclude-dir matches by NAME, which would
  # over-prune any dir named worktrees/cross-model-out anywhere; the anchored
  # post-filter drops only the TOP-LEVEL harness/runtime dirs so a nested
  # same-named dir is still scanned. README.md is NOT excluded at the grep
  # level (--exclude is basename-only, which would blind nested READMEs); the
  # ROOT-EXACT README exception is applied by the post-filter below.
  set +e
  secret_hits_raw="$(grep -rEHn --exclude-dir=.git -e "$secret_pattern" "$repo_root")"
  secret_status=$?
  set -e
  if [ -n "$secret_hits_raw" ]; then
    # Escape ERE metachars in repo_root before interpolating into the filter
    # regex so unusual checkout paths (with `[`, `+`, `(`, etc.) don't under- or
    # over-match the anchored prefix. bash parameter expansion, no sed maze.
    repo_root_re="${repo_root//\\/\\\\}"
    repo_root_re="${repo_root_re//./\\.}"
    repo_root_re="${repo_root_re//[/\\[}"
    repo_root_re="${repo_root_re//]/\\]}"
    repo_root_re="${repo_root_re//+/\\+}"
    repo_root_re="${repo_root_re//\*/\\*}"
    repo_root_re="${repo_root_re//\?/\\?}"
    repo_root_re="${repo_root_re//(/\\(}"
    repo_root_re="${repo_root_re//)/\\)}"
    repo_root_re="${repo_root_re//\^/\\^}"
    repo_root_re="${repo_root_re//\$/\\\$}"
    repo_root_re="${repo_root_re//|/\\|}"
    # `{` `}` are ERE interval metachars: an unescaped checkout path like
    # /tmp/a{1} would make `a{1}` mean "one a" and the anchor would mis-match,
    # dropping the wrong lines (or keeping the root README's). Escape them too so
    # the repo-root prefix is matched literally (<TEAM>-248; pre-existing for the
    # dir exclusions, now also load-bearing for the README anchor below).
    repo_root_re="${repo_root_re//\{/\\{}"
    repo_root_re="${repo_root_re//\}/\\}}"
    # Drop the top-level harness/runtime dirs AND the ROOT-EXACT README.md
    # (its `…/README.md:` line prefix, anchored at repo root) — a nested
    # README's `…/sub/README.md:` line does not match and is still reported.
    secret_hits="$(printf '%s\n' "$secret_hits_raw" | grep -vE \
      "^${repo_root_re}/((\.(claude|codex|agents)/worktrees|cross-model-out|\.codegraph)/|README\.md:)" || true)"
  fi
fi

if [ -n "$secret_hits" ]; then
  printf 'FAIL likely secret pattern found\n' >&2
  printf '%s\n' "$secret_hits" >&2
  exit 1
fi
if [ "$secret_status" -gt 1 ]; then
  printf 'FAIL secret scan errored (grep exit %s); not treating as pass\n' "$secret_status" >&2
  exit 1
fi
printf 'PASS repository secret pattern scan\n'

# Capability-spec header completeness (compiler input for the harness build).
check_capabilities() {
  local cap_dir="$repo_root/capabilities"
  if [ ! -d "$cap_dir" ]; then
    printf 'FAIL capabilities/ directory missing\n' >&2
    exit 1
  fi

  local found=0 file base fm
  for file in "$cap_dir"/*.md; do
    [ -e "$file" ] || continue
    base="$(basename "$file" .md)"
    [ "$base" = "README" ] && continue
    found=$((found + 1))

    if [ "$(head -1 "$file")" != "---" ]; then
      printf 'FAIL capability %s: missing YAML frontmatter (no opening ---)\n' "$base" >&2
      exit 1
    fi
    fm="$(awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$file")"
    if [ -z "$fm" ]; then
      printf 'FAIL capability %s: empty or unterminated frontmatter\n' "$base" >&2
      exit 1
    fi

    fm_get() { printf '%s\n' "$fm" | grep -E "^$1:[[:space:]]*" | head -1 | sed -E "s/^$1:[[:space:]]*//"; }

    local key
    for key in name summary triggers verification harnesses kind; do
      if ! printf '%s\n' "$fm" | grep -qE "^$key:[[:space:]]*[^[:space:]]"; then
        printf 'FAIL capability %s: missing or empty required header key: %s\n' "$base" "$key" >&2
        exit 1
      fi
    done

    local v_name; v_name="$(fm_get name)"
    if [ "$v_name" != "$base" ]; then
      printf 'FAIL capability %s: header name "%s" does not match filename\n' "$base" "$v_name" >&2
      exit 1
    fi

    local v_kind; v_kind="$(fm_get kind)"
    if [ "$v_kind" != "native" ] && [ "$v_kind" != "vendored" ]; then
      printf 'FAIL capability %s: kind must be native or vendored (got "%s")\n' "$base" "$v_kind" >&2
      exit 1
    fi

    for key in triggers harnesses; do
      local lv; lv="$(fm_get "$key")"
      if ! printf '%s' "$lv" | grep -qE '^\[[^][]*[^][[:space:]][^][]*\]$'; then
        printf 'FAIL capability %s: %s must be a non-empty [list] (got "%s")\n' "$base" "$key" "$lv" >&2
        exit 1
      fi
    done

    local v_ver; v_ver="$(fm_get verification)"
    if [ "$v_ver" != "none" ] && [ ! -f "$repo_root/verification/$v_ver.md" ]; then
      printf 'FAIL capability %s: verification gate "%s" not found in verification/\n' "$base" "$v_ver" >&2
      exit 1
    fi

    local harness_list h; harness_list="$(fm_get harnesses | tr -d '[]' | tr ',' ' ')"
    for h in $harness_list; do
      if [ ! -d "$repo_root/harnesses/$h" ]; then
        printf 'FAIL capability %s: listed harness "%s" has no harnesses/%s/ adapter\n' "$base" "$h" "$h" >&2
        exit 1
      fi
    done

    if [ "$v_kind" = "vendored" ]; then
      for key in source version install; do
        if ! printf '%s\n' "$fm" | grep -qE "^$key:[[:space:]]*[^[:space:]]"; then
          printf 'FAIL capability %s: vendored capability missing required key: %s\n' "$base" "$key" >&2
          exit 1
        fi
      done
    fi
  done

  if [ "$found" -eq 0 ]; then
    printf 'FAIL capabilities/ contains no capability specs\n' >&2
    exit 1
  fi
  printf 'PASS capability headers complete (%s specs)\n' "$found"
}
check_capabilities

# Lifecycle frontmatter convention: every durable on-disk artifact in
# the named in-scope paths must carry `lifecycle: <one of five values>` in its
# YAML frontmatter. Canonical vocabulary + scope + scaffolds: core/lifecycle.md.
#
# In-scope paths (mirrored in tests/lifecycle.test.sh):
#   docs/plans/*.md
#   docs/superpowers/plans/*.md
#   docs/superpowers/specs/*.md
#   capabilities/*.md (except README.md)
#   harnesses/{claude,codex}/capabilities/*.md
#
# Valid values: experimental | reviewed | shipped | superseded | sunset.
# No aliases. Validated against the literal alternation below.
#
# Frontmatter parsing matches check_capabilities (above): opening --- on line 1,
# block terminates at the next /^---[[:space:]]*$/ line. An empty body between
# the fences is rejected as malformed.
check_lifecycle() {
  local valid_re='^lifecycle:[[:space:]]+(experimental|reviewed|shipped|superseded|sunset)[[:space:]]*$'
  local found=0 rel file base fm fm_out fm_closed
  # Use git ls-files (matches tests/links.test.sh) so dotfile sentinels
  # injected by tests/lifecycle.test.sh are scanned too. Bash's default `*.md`
  # glob skips dotfiles, which would silently exclude `.test-t83-*.md`
  # fixtures and false-PASS the negative tests.
  #
  # In-scope path predicates: docs/plans/*.md OR
  # docs/<subdir>/plans/*.md OR docs/<subdir>/specs/*.md OR
  # capabilities/*.md (except README) OR harnesses/<h>/capabilities/*.md.
  # Filter via case at scan time (cheaper than enumerating dirs).
  if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'PASS lifecycle frontmatter convention (skipped — not a git checkout)\n'
    return 0
  fi
  while IFS= read -r rel; do
    # In-scope path predicates: covers both root-level `docs/plans/` /
    # `docs/specs/` and any nested `docs/<subdir>/plans/` / `docs/<subdir>/specs/`.
    # The `docs/*/plans/*.md` form uses shell `case` semantics where `*` matches
    # `/` — so deeper paths like `docs/a/b/plans/c.md` would also match.
    # This is intentional: any future nested layout still gets enforcement.
    case "$rel" in
      docs/plans/*.md) ;;
      docs/specs/*.md) ;;
      docs/*/plans/*.md) ;;
      docs/*/specs/*.md) ;;
      capabilities/*.md) ;;
      harnesses/*/capabilities/*.md) ;;
      *) continue ;;
    esac
    file="$repo_root/$rel"
    [ -e "$file" ] || continue
    base="$(basename "$file" .md)"
    # README mirrors check_capabilities exclusion — applies to ANY in-scope
    # path's README.md (capabilities/, docs/plans/, harnesses/*/capabilities/,
    # etc.). A directory README is the introduction-doc, not the
    # lifecycle-tracked artifact. Documented in core/lifecycle.md applicability.
    [ "$base" = "README" ] && continue
    found=$((found + 1))

    if [ "$(head -1 "$file")" != "---" ]; then
      printf 'FAIL lifecycle %s: missing YAML frontmatter (no opening ---)\n' "$rel" >&2
      exit 1
    fi
    # Walk the body and verify the frontmatter terminates with a closing ---.
    # awk emits both the captured frontmatter and a sentinel line CLOSED=<0|1>
    # so we can distinguish "terminated frontmatter" from "EOF-with-no-close".
    # check_capabilities (above) doesn't do this — it tolerates unterminated
    # frontmatter — but lifecycle.test.sh's negative-case assertion (test 5)
    # requires the stricter check.
    fm_out="$(awk 'BEGIN{closed=0} NR==1{next} /^---[[:space:]]*$/{closed=1; exit} {print} END{print "__CLOSED__=" closed}' "$file")"
    fm_closed="$(printf '%s\n' "$fm_out" | tail -1)"
    fm="$(printf '%s\n' "$fm_out" | sed '$d')"
    if [ "$fm_closed" != "__CLOSED__=1" ]; then
      printf 'FAIL lifecycle %s: unterminated YAML frontmatter (no closing ---)\n' "$rel" >&2
      exit 1
    fi
    if [ -z "$fm" ]; then
      printf 'FAIL lifecycle %s: empty frontmatter block\n' "$rel" >&2
      exit 1
    fi

    if ! printf '%s\n' "$fm" | grep -qE "$valid_re"; then
      printf 'FAIL lifecycle %s: missing or invalid lifecycle: value\n' "$rel" >&2
      printf '       expected one of: experimental | reviewed | shipped | superseded | sunset\n' >&2
      exit 1
    fi
  done < <(git -C "$repo_root" ls-files)

  if [ "$found" -eq 0 ]; then
    # Not necessarily an error — repo may have no in-scope artifacts — but log
    # a soft notice so a future refactor that accidentally moves all artifacts
    # out of the in-scope paths gets flagged in CI output.
    printf 'PASS lifecycle frontmatter convention (0 in-scope artifacts)\n'
    return 0
  fi
  printf 'PASS lifecycle frontmatter convention (%s in-scope artifacts)\n' "$found"
}
check_lifecycle

# local.env (machine paths consumed by install.sh) must be gitignored.
check_local_env_gitignored() {
  local gi="$repo_root/.gitignore"
  if [ ! -f "$gi" ]; then
    printf 'FAIL .gitignore missing; cannot confirm local.env is ignored\n' >&2
    exit 1
  fi
  if ! grep -qxE '/?local\.env' "$gi"; then
    printf 'FAIL .gitignore does not ignore local.env (machine secrets/paths must not be committed)\n' >&2
    exit 1
  fi
  if [ -f "$repo_root/local.env" ] && git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    if ! git -C "$repo_root" check-ignore -q local.env 2>/dev/null; then
      printf 'FAIL local.env exists and is NOT ignored by git\n' >&2
      exit 1
    fi
  fi
  printf 'PASS local.env is gitignored\n'
}
check_local_env_gitignored

# <TEAM>-90: removed check_lineark_on_path. The framework no longer hard-fails
# on missing operator-installed tools (lineark / codegraph / agy / superpowers).
# validate.sh now checks framework internal consistency only; bootstrap.sh
# --check checks operator setup health advisorily. See core/operating-system.md
# §Composition layers.

# Every harness listed by any capability must ship an adapter.md, not just a dir.
check_harness_adapters() {
  local hdir="$repo_root/harnesses" h found=0
  if [ ! -d "$hdir" ]; then
    printf 'FAIL harnesses/ directory missing\n' >&2
    exit 1
  fi
  for h in "$hdir"/*/; do
    [ -e "$h" ] || continue
    found=$((found + 1))
    if [ ! -f "$h/adapter.md" ]; then
      printf 'FAIL harness %s has no adapter.md\n' "$(basename "$h")" >&2
      exit 1
    fi
  done
  if [ "$found" -eq 0 ]; then
    printf 'FAIL harnesses/ contains no harness directories\n' >&2
    exit 1
  fi
  printf 'PASS every harness has an adapter.md\n'
}
check_harness_adapters

# Internal markdown link integrity (<TEAM>-53 C7 + <TEAM>-63 fence/inline-code parser).
#
# Scans every tracked *.md outside the vendored allowlist for markdown links
# of the form [text](relative/path) — skipping CommonMark fenced code blocks,
# inline-code spans, external schemes (http, https, mailto, ftp), pure anchors
# (#section), and absolute paths (/foo, //host). Each surviving target is
# resolved relative to the containing .md's own directory and must exist on
# disk.
#
# Allowlist:
#   - harnesses/*/vendored/** — per <TEAM>-42 vendored snapshots are immutable,
#     so broken links inside them point to upstream-only artifacts (editing
#     would create drift from upstream). <TEAM>-75 removed all 4 vendored
#     snapshots from the framework — agentic-os-template now authors zero vendored
#     capabilities. The
#     allowlist is preserved for forward-compat with future Tier 3
#     re-introduction per <TEAM>-55 closure; it is a no-op today.
#
# (<TEAM>-63 removed the docs/plans/** allowlist that <TEAM>-53 originally added.
# The old allowlist was a workaround for the naive `/^```/` fence toggle —
# plans use nested triple-backticks inside outer 4-backtick fences plus
# inline-code link syntax, both of which the new awk parser handles per
# CommonMark. Plans are now tracked content and should have resolving links.
# Tradeoff acknowledged: plans are historical documents — if a referenced
# target is renamed/deleted in a future PR, that PR must also update the
# plan's links (or narrow this allowlist to the affected plan with a TODO).
# Cross-model review of this PR raised this concern; the path forward is
# narrow-on-demand rather than blanket-historical-exemption.)
#
# Parser scope and documented limitations (each pinned by a test in
# tests/links.test.sh):
#   - Fence parser is CommonMark-aware: tracks fence character (` or ~) AND
#     length (>=3), enforces homogeneous-character closing, allows up to 3
#     leading spaces (CommonMark indented-fence rule). Patterns avoid the
#     POSIX-optional {n,m} interval quantifier so they work under stripped-
#     down awks (mawk without --re-interval, BusyBox awk).
#   - Inline-code stripping uses three longest-first gsub passes (triple,
#     double, single backtick spans). Spans whose content includes a
#     backtick run SHORTER than the delimiter pass through unstripped — a
#     known edge case; if the framework docs ever use that form, swap in a
#     state-machine inline-code parser.
#   - Reference-style links [text][ref] + [ref]: target are NOT tracked.
#     Only inline [text](target) is checked.
#   - Escaped parens in link destinations ([x](foo\(bar\).md)) are extracted
#     truncated at the first unescaped ). A future enhancement could parse
#     balanced/escaped parens.
check_internal_links() {
  if ! command -v git >/dev/null 2>&1; then
    printf 'FAIL git unavailable; cannot enumerate tracked markdown files\n' >&2
    exit 1
  fi
  if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'PASS internal markdown links (skipped — not a git checkout)\n'
    return 0
  fi

  # <TEAM>-88: honor ${AWK:-awk} so tests can swap engines (gawk vs BSD awk vs
  # mawk) to verify the fence parser is portable. Default `awk` resolves to
  # whatever the host provides (BSD on macOS, mawk or gawk on most Linux).
  # tests/links.test.sh re-runs the suite with AWK=gawk on macOS when gawk
  # is on PATH so BSD-vs-GNU regressions are caught locally before CI.
  local awk_bin="${AWK:-awk}"
  local fail=0 file rel target abs_target file_dir body links
  while IFS= read -r file; do
    # Vendored snapshots are immutable per <TEAM>-42 — broken refs inside them
    # are upstream debt, not actionable here.
    case "$file" in
      harnesses/*/vendored/*) continue ;;
    esac

    # CommonMark-aware fence + inline-code stripping (<TEAM>-63 F-2 + F-3,
    # hardened by cross-model review; <TEAM>-88 GNU-awk portability fix):
    #
    #   Fence handling — tracks character (` vs ~) AND length (>=3). The
    #   opening regex enforces a homogeneous fence character via the
    #   ("````*"|"~~~~*") alternation; the closing regex enforces the same
    #   plus "fence chars only + optional whitespace". Length is counted
    #   by a manual scan of consecutive same-character chars after match,
    #   so mixed-char tails (a backtick run followed by tildes) cannot
    #   inflate the fence length. Up to 3 leading spaces allowed
    #   (CommonMark indented-fence rule). The whole grammar avoids the
    #   POSIX-optional {n,m} quantifier — written as repeated `?` and
    #   trailing `*` so it works under any POSIX awk including stripped
    #   busybox/mawk builds.
    #
    #   <TEAM>-88: the alternation was originally written `("```\`*"|"~~~~*")`
    #   with a `\`` escape before the 4th backtick. BSD awk treats `\`` as
    #   a redundant escape on a non-special char (so the pattern matched
    #   "3+ backticks"), but POSIX ERE leaves backslash-before-non-special
    #   implementation-defined — GNU gawk's regex engine parses `\\\`` as
    #   "literal backslash + literal backtick" (two atoms; `*` applies to
    #   only the second), making `\\\`*` require a literal backslash in the
    #   input that real markdown fences never contain. The result: GNU awk
    #   either failed to OPEN 4-backtick fences (treating their content as
    #   prose, leaking false-positive link extractions) or failed to CLOSE
    #   them (depending on gawk version), producing 12+ false-positive
    #   "broken internal link" errors on Linux CI runs. Dropping the `\\`
    #   escape removes the ambiguity — every POSIX awk parses `````*` the
    #   same way (3 mandatory backticks + 0-or-more trailing backticks =
    #   "3+ backticks").
    #
    #   Inline-code — outside fences, strip backtick spans in longest-
    #   first order (triple, double, single). CommonMark allows multi-
    #   backtick delimiters used precisely so the content can contain
    #   backticks of OTHER lengths; the longest-first pass order means
    #   double-backtick spans are stripped before the single-backtick
    #   pass can match their delimiter pairs.
    # <TEAM>-88: force LC_ALL=C on the awk invocation. With LANG/LC_CTYPE blank
    # (as happens in some macOS subshells and certain container envs), GNU
    # gawk's regex engine falls back to a broken state where simple gsub
    # patterns like /`[^`]+`/ silently fail to match. Setting LC_ALL=C
    # forces deterministic ASCII byte handling — required by the inline-
    # code stripper (`...`) and unaffected by the multibyte content in any
    # markdown body we're parsing. Verified identical-output under BSD awk,
    # mawk, and gawk on the <TEAM>-53 + <TEAM>-74 plan files.
    body="$(LC_ALL=C "$awk_bin" '
      BEGIN { in_fence = 0; fence_char = ""; fence_len = 0 }
      {
        if (in_fence == 0) {
          # Opening fence: 0-3 leading spaces, then 3+ same-char fence chars.
          # The alternation ("````*"|"~~~~*") enforces homogeneous char at
          # the regex level; the manual scan below also enforces it on the
          # length count. The redundant `\`` escape inside the backtick
          # alternative was dropped per <TEAM>-88 (see header comment) so GNU
          # awk and BSD awk produce identical fence-detection behavior.
          if (match($0, /^[ ]?[ ]?[ ]?(````*|~~~~*)/)) {
            tmp = $0
            sub(/^[ ]?[ ]?[ ]?/, "", tmp)
            fence_char = substr(tmp, 1, 1)
            fence_len = 0
            while (substr(tmp, fence_len + 1, 1) == fence_char) {
              fence_len++
            }
            in_fence = 1
            next
          }
          # Not opening: strip inline-code spans longest-first, then print
          line = $0
          gsub(/```[^`]+```/, "", line)
          gsub(/``[^`]+``/, "", line)
          gsub(/`[^`]+`/, "", line)
          print line
        } else {
          # Inside fence: only a homogeneous-char fence line (3+ chars of
          # the same kind, optional trailing whitespace) of length >= the
          # opening can close. Outer regex enforces homogeneous + whitespace
          # tail; manual scan validates length.
          if (match($0, /^[ ]?[ ]?[ ]?(````*|~~~~*)[ \t]*$/)) {
            tmp = $0
            sub(/^[ ]?[ ]?[ ]?/, "", tmp)
            close_char = substr(tmp, 1, 1)
            close_len = 0
            while (substr(tmp, close_len + 1, 1) == close_char) {
              close_len++
            }
            if (close_char == fence_char && close_len >= fence_len) {
              in_fence = 0
              next
            }
          }
          # Otherwise: fence content, skip
          next
        }
      }
    ' "$repo_root/$file")"

    # Extract every [text](target). Wrap with || true so a file with no
    # markdown links does not trigger pipefail (grep exit 1 on no-match).
    links="$(printf '%s\n' "$body" | grep -oE '\]\([^)]+\)' || true)"
    [ -z "$links" ] && continue

    file_dir="$(dirname "$file")"
    while IFS= read -r rel; do
      # Strip the literal "](" prefix and ")" suffix from the match.
      rel="${rel#\]\(}"
      rel="${rel%\)}"
      # Strip anchor (#frag), query (?q), and any optional Markdown link
      # title  (path "title"  /  path 'title').
      target="${rel%%#*}"
      target="${target%%\?*}"
      target="${target%% \"*}"
      target="${target%% \'*}"
      [ -z "$target" ] && continue
      # Skip external schemes and absolute filesystem paths.
      #
      # <TEAM>-105: also skip `../../<github-platform-segment>` prefixes. These
      # markdown links (e.g. `[issue tracker](../../issues)`) resolve at
      # GitHub-render time via relative-URL routing on github.com, NOT on
      # the local filesystem. Treating them as local relatives produces
      # spurious "broken internal link" failures (see <TEAM>-96 case study +
      # [[feedback_github_relative_links_trip_validate]]).
      #
      # Scope is intentionally narrow — only the canonical GitHub-platform
      # path segments (issues / wiki / pulls + pull / releases / tree / blob
      # / labels / milestones / commits + commit / discussions). Both the
      # plural (list view) and singular (detail view) forms are recognized
      # where GitHub uses them: `/pulls` lists all PRs, `/pull/123` is a
      # specific PR; `/commits` lists branch history, `/commit/<sha>` is a
      # specific commit (caught by adversarial review 2026-05-27). A bare
      # `../` or `../something-else` is still checked as a normal relative
      # path so the gate keeps catching real broken links.
      #
      # Trade-off (documented adversarial finding 2026-05-27): the
      # skip-list is prefix-based, not path-normalized. From a deeply
      # nested file, `../../issues/X` lexically resolves to `<repo>/issues/X`
      # — a hypothetical real local file with that path would now be
      # silently skipped. We accept this because the <TEAM>-105 convention
      # treats `../../<github-platform-segment>` as an opaque GitHub-render
      # reference regardless of where the link lives in the tree (matches
      # the <TEAM>-96 SECURITY.md case study + how operators write the
      # convention). Validating GitHub-render-time URLs is out of scope
      # (same as for `https://...` links).
      case "$target" in
        http://*|https://*|mailto:*|ftp://*|file://*|//*|/*) continue ;;
        ../../issues|../../issues/*) continue ;;
        ../../wiki|../../wiki/*) continue ;;
        ../../pulls|../../pulls/*) continue ;;
        ../../pull|../../pull/*) continue ;;
        ../../releases|../../releases/*) continue ;;
        ../../tree|../../tree/*) continue ;;
        ../../blob|../../blob/*) continue ;;
        ../../labels|../../labels/*) continue ;;
        ../../milestones|../../milestones/*) continue ;;
        ../../commits|../../commits/*) continue ;;
        ../../commit|../../commit/*) continue ;;
        ../../discussions|../../discussions/*) continue ;;
      esac
      abs_target="$repo_root/$file_dir/$target"
      if [ ! -e "$abs_target" ]; then
        printf 'FAIL broken internal link in %s -> %s\n' "$file" "$target" >&2
        fail=1
      fi
    done <<< "$links"
  done < <(git -C "$repo_root" ls-files '*.md')

  if [ "$fail" -eq 1 ]; then
    exit 1
  fi
  printf 'PASS internal markdown links resolve\n'
}
check_internal_links

"$repo_root/scripts/check-drift.sh"

printf '\nPASS agentic-os-template validation complete\n'
