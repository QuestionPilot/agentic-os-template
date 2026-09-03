#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# jqr — jq -r with CRLF normalization. A Windows-built jq emits \r\n line
# endings; a trailing \r embedded in a hash or key silently fails every
# string comparison downstream (manifest "want" values, managed-subdir
# grep -qxF membership tests). Values never legitimately contain \r here.
jqr() { jq -r "$@" | tr -d '\r'; }

# --- arg parse: --cure-soft-drift is optional + position-insensitive --------
# The flag opts into soft-drift auto-cure. When set, a drift case
# limited to settings.json's user-preference keys (theme, effortLevel, outputStyle, switchModelsOnFlag,
# agentPushNotifEnabled, inputNeededNotifEnabled, tui, key
# reordering inside enabledPlugins/extraKnownMarketplaces) triggers a
# transparent re-render via install.sh instead of erroring. ANY drift outside
# that envelope still errors as before — default behavior is unchanged.
CURE_SOFT_DRIFT=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cure-soft-drift) CURE_SOFT_DRIFT=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
# Restore positional args minus the flag(s) we consumed.
set -- "${ARGS[@]+"${ARGS[@]}"}"

# --auto: resolve EVERY harness render home (env var first, then local.env as
# data) and run the --manifest gate against each home that has a rendered
# manifest. <TEAM>-394: `make drift` previously checked only $CLAUDE_CONFIG_DIR
# while the codex entrypoint told its operator $CODEX_HOME was covered — a
# false cross-harness promise. Skips are LOUD (one line per harness) so an
# unresolvable home is visible, never silently green. Exit: 1 if any checked
# home drifts; 0 otherwise — including the fresh-clone case where nothing is
# resolvable yet (same degrade contract as the old Makefile presence-guard).
if [ "${1:-}" = "--auto" ]; then
  # _cd_localenv_get <path> <key> — read one KEY=VALUE from local.env as DATA
  # (never sourced; a hostile or malformed local.env cannot execute). Same
  # parser as scripts/self-audit.sh::_sa_localenv_get: strips an optional
  # `export `, one matching outer quote pair, backslash escapes; last
  # assignment wins. No $VAR expansion — a self-referencing value resolves
  # literally and lands in the loud no-manifest skip path below.
  _cd_localenv_get() {
    local path="$1" key="$2" line t v f l inner result=""
    [ -f "$path" ] || { printf '%s' ""; return 0; }
    while IFS= read -r line || [ -n "$line" ]; do
      t="${line#"${line%%[![:space:]]*}"}"
      t="${t%"${t##*[![:space:]]}"}"
      [ -z "$t" ] && continue
      case "$t" in '#'*) continue ;; esac
      case "$t" in
        export[[:space:]]*) t="${t#export}"; t="${t#"${t%%[![:space:]]*}"}" ;;
      esac
      case "$t" in
        "$key="*) v="${t#"$key="}" ;;
        *) continue ;;
      esac
      if [ "${#v}" -ge 2 ]; then
        f="${v:0:1}"; l="${v:$(( ${#v} - 1 )):1}"
        if { [ "$f" = '"' ] && [ "$l" = '"' ]; } || { [ "$f" = "'" ] && [ "$l" = "'" ]; }; then
          inner=$(( ${#v} - 2 )); v="${v:1:$inner}"
        else
          case "$v" in
            *'\'*) v="$(printf '%s' "$v" | sed -E 's/\\(.)/\1/g')" ;;
          esac
        fi
      fi
      result="$v"
    done < "$path"
    printf '%s' "$result"
  }

  # AI_CONFIG_LOCAL_ENV: same fixture-override convention as install.sh, so
  # tests can point --auto at a synthetic local.env instead of the operator's.
  auto_localenv="${AI_CONFIG_LOCAL_ENV:-$repo_root/local.env}"
  auto_failed=0
  # "agents" is the codex pass's .agents co-render (install.sh corender_agents),
  # not a harness of its own — but it has a manifest and hand-edits to it are
  # drift like any other render, so it runs the same gate.
  for auto_pair in "claude:CLAUDE_CONFIG_DIR" "codex:CODEX_HOME" "hermes:HERMES_HOME" "cursor:CURSOR_CONFIG_DIR" "agents:AGENTS_DIR"; do
    auto_harness="${auto_pair%%:*}"; auto_var="${auto_pair#*:}"
    auto_dir="${!auto_var:-}"
    auto_src="env"
    if [ -z "$auto_dir" ] && [ -f "$auto_localenv" ]; then
      auto_dir="$(_cd_localenv_get "$auto_localenv" "$auto_var")"
      auto_src="local.env"
    fi
    if [ -z "$auto_dir" ]; then
      printf 'check-drift --auto: %s (%s) not set; skipping\n' "$auto_harness" "$auto_var"
      continue
    fi
    # A RESOLVED home always runs the gate — no missing-manifest skip. The old
    # Makefile recipe FAILED when CLAUDE_CONFIG_DIR was set but the manifest
    # was gone (a deleted manifest is a hand-edit form); a skip here would be
    # the fail-open hole the panel flagged: a broken render silently passing
    # `make drift`. Only an UNRESOLVED home (fresh clone, harness never
    # configured) skips.
    printf 'check-drift --auto: checking %s render at %s (via %s)\n' \
      "$auto_harness" "$auto_dir" "$auto_src"
    # Self-invoke keeps --manifest the single source of truth for the gate
    # itself; --cure-soft-drift passes through unchanged.
    if [ "$CURE_SOFT_DRIFT" -eq 1 ]; then
      bash "${BASH_SOURCE[0]}" --cure-soft-drift --manifest "$auto_dir" || auto_failed=1
    else
      bash "${BASH_SOURCE[0]}" --manifest "$auto_dir" || auto_failed=1
    fi
  done
  exit "$auto_failed"
fi

# --manifest <target-dir>: verify a built target against its .build-manifest.json.
# Used by install.sh's drift detection and the acceptance suite. When this mode
# is selected the script does only the manifest check and exits.
if [ "${1:-}" = "--manifest" ]; then
  target="${2:?--manifest needs a target directory}"
  manifest="$target/.build-manifest.json"
  if [ ! -f "$manifest" ]; then
    printf 'FAIL no .build-manifest.json in %s\n' "$target" >&2
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'FAIL jq unavailable; cannot verify build manifest\n' >&2
    exit 1
  fi
  # Hash via stdin: a filename containing backslashes (Windows-style target
  # dirs) flips GNU coreutils into escaped-filename mode, prefixing the output
  # line with '\' and corrupting the extracted hash.
  sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1" | cut -d' ' -f1
    else printf 'FAIL no sha256 tool found\n' >&2; exit 1; fi
  }
  # <TEAM>-106 soft-drift detection: track which files drifted (instead of just a
  # boolean), so the post-loop classifier can decide whether the drift envelope
  # is "soft" (only settings.json + only user-preference keys) and curable via
  # install.sh re-render.
  drift=0
  DRIFTED_FILES=()
  while IFS=$'\t' read -r rel want; do
    [ -n "$rel" ] || continue
    if [ ! -f "$target/$rel" ]; then
      printf 'FAIL manifest drift: generated file missing: %s\n' "$rel" >&2
      drift=1
      DRIFTED_FILES+=("$rel")
      continue
    fi
    got="$(sha256 "$target/$rel")"
    if [ "$got" != "$want" ]; then
      printf 'FAIL manifest drift: %s was hand-edited\n' "$rel" >&2
      drift=1
      DRIFTED_FILES+=("$rel")
    fi
  done < <(jqr '.generated | to_entries[] | "\(.key)\t\(.value)"' "$manifest")
  # Extra-file detection: a file in the generated tree (hooks/, settings.json)
  # or in a manifest-managed skills/<name>/ or plugins/<name>/ subdir that the
  # manifest does not list is drift. Unmanaged skills/<name>/ and plugins/<name>/
  # subdirs are operator-local (**Shape C** skills, operator-added plugins) per
  # <TEAM>-55's three-shape model (formalized in <TEAM>-68) — install.sh's
  # per-subdir swap preserves them through re-renders, and their files are
  # intentionally not in the manifest. Both skills/ and plugins/ are per-subdir
  # managed trees (install.sh PER_SUBDIR_PATHS), so each gets the same exemption:
  # compute the manifest-managed subdir set per category, then exempt all others.
  managed_skills="$(jqr '.generated | keys[] | select(startswith("skills/")) | split("/")[1]' "$manifest" 2>/dev/null | sort -u)"
  managed_plugins="$(jqr '.generated | keys[] | select(startswith("plugins/")) | split("/")[1]' "$manifest" 2>/dev/null | sort -u)"
  # plugins/ is scanned ONLY when the manifest declares it a managed tree (i.e.
  # hermes, whose build produces plugins/agentic-os-hook-bridge/). For claude/
  # codex, plugins/ is NOT framework-managed — Claude Code's app owns ~/.claude/
  # plugins/ (it writes plugins/known_marketplaces.json and similar app state
  # there), so scanning it would mis-flag app state as drift. skills/ + hooks/
  # are managed by every harness, so they are always scanned.
  scan_roots=("$target/skills" "$target/hooks")
  [ -n "$managed_plugins" ] && scan_roots+=("$target/plugins")
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    rel="${f#"$target"/}"
    # The exemption is only for SUBDIR-structured Shape C content
    # (`skills/<name>/...`). Files placed directly under skills/ (no subdir,
    # e.g. `skills/rogue.md`) stay subject to the manifest gate — Codex F-2
    # in the <TEAM>-68 review.
    case "$rel" in
      # Python bytecode cache is a RUNTIME artifact, never a manifest input: the
      # build copies plugin .py SOURCE, and the interpreter writes
      # __pycache__/*.pyc the first time the plugin is imported (e.g. the
      # agentic-os-hook-bridge plugin firing in a live Hermes session). The
      # manifest can never list it, so without this exemption the extra-file scan
      # FAILs the moment a profile runs once. Scope the exemption TIGHTLY to the
      # __pycache__/ tree: under Python 3 all derived bytecode (incl. optimized
      # .opt-N.pyc) lands there, so a loose *.pyc dropped directly in a managed
      # tree is anomalous and SHOULD still flag — a suffix-only exemption would
      # blind the gate to any unmanifested file merely named *.pyc.
      */__pycache__/*) continue ;;
      # Hermes writes its own skill-bookkeeping files directly into the
      # managed skills/ tree at runtime — app-written state, not a hand edit
      # (same class as the app-written settings.json keys absorbed into the
      # soft-drift allowlist). The bundled-manifest is the catalog; the curator
      # and usage tracker write the rest. Exempt them by exact name (a blanket
      # skills/.* glob would weaken the F-2 gate that catches skills/.rogue).
      skills/.bundled_manifest|skills/.curator_state|skills/.usage.json|skills/.usage.json.lock) continue ;;
      skills/*/*)
        sub="${rel#skills/}"; sub="${sub%%/*}"
        # here-string, not `printf … | grep -qxF`: under pipefail an early grep
        # match can SIGPIPE the printf and false-flip the test, wrongly skipping
        # a managed entry's drift check.
        grep -qxF "$sub" <<<"$managed_skills" || continue
        ;;
      plugins/*/*)
        sub="${rel#plugins/}"; sub="${sub%%/*}"
        grep -qxF "$sub" <<<"$managed_plugins" || continue
        ;;
    esac
    if ! jq -e --arg k "$rel" '.generated | has($k)' "$manifest" >/dev/null 2>&1; then
      printf 'FAIL manifest drift: untracked file in generated tree: %s\n' "$rel" >&2
      drift=1
      DRIFTED_FILES+=("untracked:$rel")
    fi
  done < <(find "${scan_roots[@]}" -type f 2>/dev/null; [ -f "$target/settings.json" ] && printf '%s\n' "$target/settings.json")
  if [ "$drift" -ne 0 ]; then
    # Operator hint, never a write: when settings.json is among the drifted files
    # and the cure was not requested, name the one-line cure so the soft-drift
    # case (app-written user-preference keys) is not re-diagnosed from scratch
    # every session. `--auto` (what `make verify` runs) stays read-only by design.
    if [ "$CURE_SOFT_DRIFT" -ne 1 ]; then
      for _d in "${DRIFTED_FILES[@]}"; do
        if [ "$_d" = "settings.json" ]; then
          printf 'NOTE if the only differences are app-written user-preference keys (theme, effortLevel, outputStyle, switchModelsOnFlag, tui, notification flags), cure without re-diagnosing — from the framework root: bash scripts/check-drift.sh --cure-soft-drift --manifest "%s"\n' "$target" >&2
          break
        fi
      done
    fi
    # <TEAM>-106 soft-drift auto-cure (opt-in via --cure-soft-drift).
    #
    # Soft-drift envelope: the SINGLE drifted file is settings.json AND every
    # top-level-key difference between the current settings.json and a freshly
    # re-rendered canonical copy is in the soft-key allowlist OR is just
    # key-reordering within tolerated objects.
    #
    # Why: Claude Code's app process strips `theme` / `effortLevel`, writes the
    # notification preferences `agentPushNotifEnabled` / `inputNeededNotifEnabled`
    # and the TUI mode preference `tui` on its own, and reorders
    # `enabledPlugins` / `extraKnownMarketplaces` between renders, so every
    # session opens with a drift trip even though the framework content hasn't
    # changed. Operator's pre-dispatch baseline currently pays a 3-step
    # diagnose-then-cure cost on every fresh session (this issue). The flag
    # collapses it to 1 step by transparently re-rendering when (and ONLY when)
    # the drift fits the known-soft envelope.
    #
    # Default behavior unchanged: without --cure-soft-drift, ANY drift still
    # fails as before — this branch is dead code on the default path.
    #
    # Safety gates (any failure = fall through to the existing error path):
    #   1. The flag must be set.
    #   2. Exactly one drifted entry, and that entry is `settings.json`.
    #   3. settings.json on disk parses as JSON.
    #   4. install.sh must be resolved from the MAIN repo (not the current
    #      worktree if one); install.sh substitutes @@AI_CONFIG_DIR@@ with
    #      $repo_root, so calling the worktree's install.sh would bake the
    #      worktree path into rendered hooks and the operator's hooks die
    #      when the worktree is removed on PR merge.
    #   5. The manifest records a `harness` field (so we know which template
    #      to re-render against).
    #   6. The structural diff against a freshly built canonical copy hits
    #      only soft keys.
    if [ "$CURE_SOFT_DRIFT" -eq 1 ] && \
       [ "${#DRIFTED_FILES[@]}" -eq 1 ] && \
       [ "${DRIFTED_FILES[0]}" = "settings.json" ] && \
       [ -f "$target/settings.json" ] && \
       jq empty "$target/settings.json" >/dev/null 2>&1; then
      # Gate 4: resolve install.sh from the main repo when we're in a linked
      # worktree, NOT from the worktree itself. install.sh substitutes
      # @@AI_CONFIG_DIR@@ with its own $repo_root, so calling the worktree's
      # install.sh would bake the worktree path into rendered hooks — and the
      # worktree disappears on PR merge, killing the operator's hooks.
      #
      # Detection via git metadata, NOT pathname shape: `git worktree add
      # /tmp/foo` creates a worktree at /tmp/foo with no `worktrees/` segment.
      # A reliable test is comparing `git rev-parse --show-toplevel` against
      # the parent of `git rev-parse --git-common-dir`. A linked worktree has
      # toplevel != common_dir_parent; the main checkout has toplevel ==
      # common_dir_parent. (Codex confirmation finding #2.)
      install_script="$repo_root/scripts/install.sh"
      if command -v git >/dev/null 2>&1; then
        # Adversarial finding A-4: canonicalize paths via `pwd -P` so
        # symlinks resolve to physical paths. Without -P, a symlinked checkout
        # could compare unequal strings for the same physical dir.
        toplevel="$(cd "$repo_root" && git rev-parse --show-toplevel 2>/dev/null | xargs -I{} sh -c 'cd "$1" 2>/dev/null && pwd -P' sh {} || true)"
        common_dir="$(cd "$repo_root" && git rev-parse --git-common-dir 2>/dev/null || true)"
        if [ -n "$toplevel" ] && [ -n "$common_dir" ]; then
          # --git-common-dir returns either an absolute path or a path
          # relative to the worktree's CWD. Normalize to absolute physical.
          case "$common_dir" in
            /*) common_dir="$(cd "$common_dir" 2>/dev/null && pwd -P || true)" ;;
            *)  common_dir="$(cd "$repo_root" && cd "$common_dir" 2>/dev/null && pwd -P || true)" ;;
          esac
          if [ -n "$common_dir" ]; then
            # common_dir is `<main>/.git` — its parent is the main repo root.
            main_root="$(cd "$common_dir/.." 2>/dev/null && pwd -P || true)"
            if [ -n "$main_root" ] && [ "$toplevel" != "$main_root" ]; then
              # toplevel != main_root → we're in a linked worktree (regardless
              # of path shape). Use main_root's install.sh.
              if [ -f "$main_root/scripts/install.sh" ]; then
                install_script="$main_root/scripts/install.sh"
              else
                # Main repo's install.sh is missing — refuse cure rather than
                # silently fall back to the worktree's install.sh, which would
                # bake worktree paths into rendered hooks.
                printf 'NOTE soft-drift envelope matched but cure refused: in linked worktree (%s)\n' "$repo_root" >&2
                printf '     and main repo install.sh not found at %s/scripts/install.sh\n' "$main_root" >&2
                printf '     Re-run from main: cd %s && bash scripts/install.sh --harness <h>\n' "$main_root" >&2
                exit 1
              fi
            fi
          fi
        fi
      fi
      # Gate 5: read the harness from the manifest AND validate it against
      # the target's actual generated-file shape. (Codex adversarial finding
      # A-1: a forged manifest with harness="claude" against a Codex-shaped
      # target could trigger install.sh to render Claude artifacts into a
      # Codex dir, leaving stale Codex entrypoints behind extra-file detection
      # doesn't catch.) The shape signal: claude has settings.json + CLAUDE.md;
      # codex has hooks.json + AGENTS.md.
      harness="$(jqr '.harness // empty' "$manifest")"
      if [ -z "$harness" ]; then
        printf 'NOTE soft-drift envelope matched but cure refused: manifest has no harness field\n' >&2
        exit 1
      fi
      case "$harness" in
        claude)
          # Claude harness must have settings.json AND CLAUDE.md AND not
          # have AGENTS.md / hooks.json (avoid the harness-confusion attack).
          if [ ! -f "$target/settings.json" ] || [ ! -f "$target/CLAUDE.md" ]; then
            printf 'NOTE soft-drift envelope matched but cure refused: manifest claims claude but target lacks settings.json/CLAUDE.md\n' >&2
            exit 1
          fi
          if [ -f "$target/AGENTS.md" ] || [ -f "$target/hooks.json" ]; then
            printf 'NOTE soft-drift envelope matched but cure refused: manifest claims claude but target also has codex artifacts (AGENTS.md/hooks.json)\n' >&2
            exit 1
          fi
          ;;
        codex)
          # Codex harness manages settings.json? No — line 121-126 of
          # install.sh: codex MANAGED_PATHS is "skills hooks hooks.json
          # AGENTS.md .build-manifest.json". So if drift hit settings.json
          # for a codex manifest, that's already structurally wrong — the
          # codex install never writes settings.json. Refuse.
          printf 'NOTE soft-drift envelope matched but cure refused: settings.json drift but manifest claims codex (codex does not manage settings.json)\n' >&2
          exit 1
          ;;
        *)
          printf 'NOTE soft-drift envelope matched but cure refused: unknown harness in manifest: %s\n' "$harness" >&2
          exit 1
          ;;
      esac
      # Adversarial finding A-3 (duplicate-key defense): jq's parser silently
      # de-dupes duplicate object keys (last-wins). A malicious settings.json
      # with duplicate `hooks` keys could pass the classifier (because jq
      # sees only the canonical value) while a different parser (or future
      # framework consumer) sees the malicious one. Use python3 to detect
      # raw duplicate keys at parse time — refuses the cure if any are
      # present. python3 is available everywhere bash is; degrade to a skip
      # if absent (defense-in-depth, not blocker).
      if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c '
import json, sys
def hook(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        sys.exit(1)
    return dict(pairs)
with open(sys.argv[1]) as f:
    json.load(f, object_pairs_hook=hook)
' "$target/settings.json" >/dev/null 2>&1; then
          printf 'NOTE soft-drift envelope matched but cure refused: settings.json contains duplicate object keys (rejected per A-3 adversarial defense)\n' >&2
          exit 1
        fi
      fi
      # Adversarial finding A-2 (TOCTOU race): capture the hash of
      # settings.json BEFORE the destructive cure runs, then re-check it
      # immediately before. A concurrent process that writes real drift
      # between classification and cure must be detected.
      pre_cure_settings_hash="$(sha256 "$target/settings.json")"
      pre_cure_manifest_hash="$(sha256 "$manifest")"
      # Gate 6: structural diff. Build a canonical copy via install.sh
      # --build-only to a tmp dir, then compare each top-level key in the
      # current settings.json against the canonical. Any key whose value
      # differs MUST be in the soft-key allowlist; any key present in one but
      # not the other MUST also be in the allowlist.
      #
      # Soft-key allowlist (top-level): theme, effortLevel, outputStyle,
      # switchModelsOnFlag, plus the app-written notification preferences
      # agentPushNotifEnabled and inputNeededNotifEnabled plus the app-written
      # TUI mode preference tui. Every entry is an
      # operator/app-written PREFERENCE the framework has no opinion on — a
      # value the harness app writes into settings.json on its own must be
      # curable, or the drift gate refuses on a key the operator never touched. PLUS we tolerate
      # any RE-ORDERING (but not value change) inside `enabledPlugins` and
      # `extraKnownMarketplaces` — install.sh's `jq` serialization may emit a
      # different key order than the harness app's pretty-printer.
      tmp_out="$(mktemp -d)"
      trap 'rm -rf "$tmp_out"' EXIT
      # Run install.sh --build-only to render a canonical settings.json.
      # install.sh bakes its `--out <dir>` into hook command paths
      # (settings.json hooks.* entries' command = $TARGET/hooks/$script). To
      # make the canonical build's hook paths match what the LIVE target
      # contains, pass `--out "$target"`: --build-only does NOT swap files
      # into the target (install.sh exits before the swap loop), so this is
      # safe — the build artifact lands at $target/.install-build.XXXXXX/
      # and gets cleaned by install.sh's EXIT trap.
      # Build the canonical baseline OPINION-FREE: AI_CONFIG_SKIP_PRESERVE_LIVE
      # suppresses generate_settings' preserve-live overlay so the classifier
      # compares against base, not a copy of the (possibly drifted) live
      # settings.json. Without this, an operator/attacker enabledPlugins or
      # agentPushNotifEnabled value-change would self-match canonical and be
      # silently cured instead of flagged as the non-soft drift it is.
      tmp_build="$(AI_CONFIG_SKIP_PRESERVE_LIVE=1 "$install_script" --harness "$harness" --out "$target" --build-only 2>/dev/null || true)"
      if [ -z "$tmp_build" ] || [ ! -f "$tmp_build/settings.json" ]; then
        printf 'NOTE soft-drift envelope matched but cure refused: canonical settings.json not built\n' >&2
        exit 1
      fi
      # install.sh --build-only leaves the build dir on disk (trap is cleared
      # before exit so the operator can inspect it). Schedule our own cleanup.
      trap 'rm -rf "$tmp_build" "$tmp_out"' EXIT
      # Type-shape preflight (Codex confirmation finding #1 — fail-closed on
      # any non-object top-level shape). Without this, downstream `keys` calls
      # in the reorder-tolerant branch can error out (e.g. `enabledPlugins`
      # mutated to a string), and our `2>/dev/null || true` swallowing the
      # error would collapse to empty-non-soft-keys = soft envelope matched =
      # cure proceeds. That would mask real drift. Refuse cure if either file
      # is not a JSON object OR if any reorder-tolerant key is present with a
      # non-object value.
      if ! jq -e 'type == "object"' "$target/settings.json" >/dev/null 2>&1; then
        printf 'NOTE soft-drift envelope NOT matched: current settings.json is not a JSON object\n' >&2
        exit 1
      fi
      if ! jq -e 'type == "object"' "$tmp_build/settings.json" >/dev/null 2>&1; then
        printf 'NOTE soft-drift envelope matched but cure refused: canonical settings.json is not a JSON object\n' >&2
        exit 1
      fi
      # Reorder-tolerant fields: if present, must be objects in both files.
      # Catches the type-change attack: e.g. enabledPlugins mutated to a string
      # or array would otherwise pass through jq's reorder-tolerant branch
      # with a `string has no keys` runtime error swallowed by 2>/dev/null.
      for reord_key in enabledPlugins extraKnownMarketplaces; do
        for shape_file in "$target/settings.json" "$tmp_build/settings.json"; do
          # If the key is absent, fine. If present, must be an object.
          if jq -e --arg k "$reord_key" 'has($k)' "$shape_file" >/dev/null 2>&1; then
            if ! jq -e --arg k "$reord_key" '.[$k] | type == "object"' "$shape_file" >/dev/null 2>&1; then
              printf 'NOTE soft-drift envelope NOT matched: %s is not an object in %s\n' \
                "$reord_key" "$shape_file" >&2
              exit 1
            fi
          fi
        done
      done
      # Compute the soft-key allowlist as a JSON array for jq.
      soft_keys='["theme","effortLevel","outputStyle","switchModelsOnFlag","agentPushNotifEnabled","inputNeededNotifEnabled","tui"]'
      reorder_tolerant='["enabledPlugins","extraKnownMarketplaces"]'
      # jq script: for each top-level key in the union of both objects,
      # categorize. Output the set of NON-soft drifted keys; empty = soft.
      # jq -n: take null as the input doc; --slurpfile reads each file into a
      # variable as a one-element array (per jq manual). Without -n, jq waits
      # for stdin and the expression operates on null — every key gets equal
      # treatment, no non-soft keys surface, and the cure runs
      # unconditionally. Critical safety: -n is REQUIRED.
      #
      # Capture jq's exit code explicitly — any non-zero (including runtime
      # type errors despite the preflight above) must be treated as
      # cure-refused, NOT silently as "no non-soft keys differ". (Codex
      # confirmation finding #1.)
      set +e
      non_soft_keys="$(jq -nr --slurpfile cur "$target/settings.json" \
                               --slurpfile can "$tmp_build/settings.json" \
                               --argjson soft "$soft_keys" \
                               --argjson reord "$reorder_tolerant" \
        '
          ($cur[0] // {}) as $C
        | ($can[0] // {}) as $K
        | ($C | keys) + ($K | keys) | unique
        | map(select(
              . as $k
            | ($C[$k] != $K[$k])
            | . and (
                # If both present and reorder-tolerant, compare normalized keys.
                ($C | has($k)) and ($K | has($k)) and ($reord | index($k))
                | if . then
                    ($C[$k] | keys | sort) != ($K[$k] | keys | sort)
                    or any(($C[$k] | keys[]); $C[$k][.] != $K[$k][.])
                  else true end
              )
          ))
        | map(select((. as $k | $soft | index($k)) | not))
        | .[]
        ' 2>/dev/null)"
      jq_status=$?
      set -e
      if [ "$jq_status" -ne 0 ]; then
        printf 'NOTE soft-drift envelope matched but cure refused: jq classifier errored (exit %s)\n' "$jq_status" >&2
        exit 1
      fi
      if [ -n "$non_soft_keys" ]; then
        printf 'NOTE soft-drift envelope NOT matched: non-soft keys differ: %s\n' \
          "$(printf '%s' "$non_soft_keys" | tr '\n' ' ')" >&2
        exit 1
      fi
      # Adversarial finding A-2 (TOCTOU race): re-check the captured hashes
      # immediately before the destructive cure. If settings.json or the
      # manifest changed between classification and cure, a concurrent
      # process may have introduced real drift; refuse and let the next
      # check-drift run re-classify.
      if [ "$(sha256 "$target/settings.json")" != "$pre_cure_settings_hash" ]; then
        printf 'NOTE soft-drift envelope matched but cure refused: settings.json changed between classification and cure (TOCTOU)\n' >&2
        exit 1
      fi
      if [ "$(sha256 "$manifest")" != "$pre_cure_manifest_hash" ]; then
        printf 'NOTE soft-drift envelope matched but cure refused: manifest changed between classification and cure (TOCTOU)\n' >&2
        exit 1
      fi
      # Envelope matched. Re-render in place to canonicalize. Pass --out
      # explicitly to ensure the re-render hits the SAME target dir the caller
      # asked about (covering the edge case where the caller's target differs
      # from local.env's CLAUDE_CONFIG_DIR/CODEX_HOME).
      printf 'INFO soft-drift detected on settings.json (only user-preference keys); curing via install.sh --harness %s\n' "$harness" >&2
      if ! "$install_script" --harness "$harness" --out "$target" >/dev/null 2>&1; then
        printf 'FAIL soft-drift cure: install.sh re-render failed\n' >&2
        exit 1
      fi
      # Re-verify post-cure. Re-run the manifest check from scratch via the
      # main repo's check-drift.sh (avoids re-entering this whole block + uses
      # the canonical script).
      check_drift_for_verify="$(dirname "$install_script")/check-drift.sh"
      if ! bash "$check_drift_for_verify" --manifest "$target" >/dev/null 2>&1; then
        printf 'FAIL soft-drift cure: post-cure drift check still fails\n' >&2
        exit 1
      fi
      printf 'PASS soft-drift cured; manifest now matches canonical render\n'
      exit 0
    fi
    exit 1
  fi
  printf 'PASS no manifest drift in %s\n' "$target"
  exit 0
fi

if ! command -v grep >/dev/null 2>&1; then
  printf 'FAIL grep unavailable; cannot run drift checks\n' >&2
  exit 1
fi

# <TEAM>-213: choose the enumeration mode ONCE. In a git work tree, scan the
# COMMITTABLE set (skips gitignored runtime artifacts — the fix). OUTSIDE a git
# work tree — e.g. a leak scan run against a plain-copy staging/export tree, which
# has no .git and therefore no gitignored runtime state — fall back to the
# pre-<TEAM>-213 `grep -r` filesystem walk so those scans still run.
#
# Detection uses TOPLEVEL-EQUALITY, not `--is-inside-work-tree` (Codex adversarial
# F1): is-inside walks ANCESTORS, so a plain-copy staging tree that happens to sit
# under some unrelated parent repo would report inside-work-tree=true, then
# `git ls-files -- .` (relative to that untracked staging dir) returns EMPTY and
# the ENTIRE leak scan silently passes — the cardinal sin for a leak guard. We
# only take the git path when `rev-parse --show-toplevel` resolves to repo_root
# itself (true for the live repo and for linked worktrees; false for a staging
# tree nested under an ancestor repo → correct fallback). Physical paths (`pwd
# -P`) are compared so a /var↔/private symlink never misclassifies the live repo.
_IS_GIT_WORKTREE=0
_q213_toplevel=""
# The git call is the `if` CONDITION (not a bare assignment) so `set -e` is
# suspended for it: outside a repo `rev-parse` exits 128, which a plain
# `var="$(git …)"` assignment would let errexit abort the whole script on —
# never reaching the non-git fallback. (Portable-bash errexit trap.)
if _q213_toplevel="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_q213_toplevel" ]; then
  _q213_tl_phys="$(cd "$_q213_toplevel" 2>/dev/null && pwd -P)" || _q213_tl_phys=""
  _q213_rr_phys="$(cd "$repo_root" 2>/dev/null && pwd -P)" || _q213_rr_phys=""
  if [ -n "$_q213_tl_phys" ] && [ "$_q213_tl_phys" = "$_q213_rr_phys" ]; then
    _IS_GIT_WORKTREE=1
  elif [ -n "$_q213_tl_phys" ] && [ "$_q213_toplevel" -ef "$repo_root" ]; then
    # MSYS mount aliasing: under Git Bash a mount-table entry (e.g. /tmp →
    # the Windows per-user temp dir) gives the SAME directory two physical
    # spellings — `cd` to git's Windows-style toplevel resolves through the
    # mount (`pwd -P` → /tmp/…) while the POSIX-spelled repo_root does not
    # (→ /c/…), so the string compare above fails for the live repo and the
    # scan silently degraded to the fs-walk, reading gitignored files. `-ef`
    # (device+inode same-file test) is spelling-independent; a staging tree
    # nested under an unrelated parent repo is a DIFFERENT directory from
    # that parent's toplevel, so -ef stays false and the intended fallback
    # for plain-copy trees is preserved.
    _IS_GIT_WORKTREE=1
  fi
fi
unset _q213_toplevel _q213_tl_phys _q213_rr_phys

# The non-git fallback below is legitimate ONLY for a plain-copy staging/export
# tree, which by definition has no .git. If .git EXISTS at repo_root (dir or
# linked-worktree file) and detection still refused the git path, something is
# wrong (rev-parse refusal — e.g. safe.directory/ownership — or an unhandled
# path-aliasing quirk). Silently widening the scan to gitignored runtime files
# produces false FAILs and, worse, hides that the committable-set contract was
# never applied — fail LOUDLY instead.
if [ "$_IS_GIT_WORKTREE" -eq 0 ] && { [ -e "$repo_root/.git" ] || [ -L "$repo_root/.git" ]; }; then
  # -L alongside -e: `test -e` FOLLOWS symlinks, so a dangling .git symlink
  # (broken target, unmounted volume) would read as "no .git" and silently
  # re-enter the fs-walk — the -L probe sees the link entry itself. (Panel
  # finding, GPT + Gemini convergent.)
  printf 'FAIL git worktree detection: %s/.git exists but git enumeration was not selected\n' "$repo_root" >&2
  printf '     (git rev-parse failed, or toplevel did not match / could not be resolved — check safe.directory/ownership).\n' >&2
  printf '     Refusing to silently fall back to the filesystem walk over gitignored runtime files.\n' >&2
  exit 1
fi

# <TEAM>-213: the broad content scans enumerate "committable" repository content
# (`git ls-files --cached --others --exclude-standard`) — tracked files PLUS
# untracked-but-not-gitignored files — instead of a raw `grep -r` filesystem
# walk. The walk descended into GITIGNORED runtime artifacts (codegraph's
# `.codegraph/daemon.log`, `*.log`, `.mcp.json`, `cross-model-out/`, the harness
# `.claude/.codex/.agents/` dirs), so a personal absolute path inside one of them
# false-tripped the machine-path scan and cascaded into ~25 baseline tests; every
# new tool's runtime dir also had to be hand-added to the `--exclude-dir` list — a
# maintenance trap. `--exclude-standard` prunes all gitignored paths up front, so
# a file that can never enter git is out of scope by definition, while tracked +
# untracked-not-ignored content — exactly what CAN be committed — is still
# scanned. The `--exclude`/`--exclude-dir` flags below remain meaningful for
# TRACKED self-referential files (check-drift.sh, drift.test.sh) and the
# tracked `plans/` dir; entries that named gitignored
# paths are now redundant but kept as documented defense-in-depth.
#
# Newline-delimited (NOT `git ls-files -z`): keeps the bash/PS twins structurally
# identical (embedded NUL is fragile to parse in PowerShell) and is safe here
# because the framework tree has no embedded-newline filenames (git would quote
# such a path via core.quotePath, so it would not match the path filters anyway).
# Submodule note: ls-files lists only a submodule's gitlink, not its internals —
# correct for "parent-repo committable content"; agentic-os-template has no submodules.
# ARG_MAX: ~200 short tracked paths (a single grep invocation, ≈10 KB argv ≪
# ARG_MAX) — kept as one grep so the 0/1/>1 tri-state survives (xargs would
# collapse grep's exit-1 "no match" into an error).

# Only a clean "no match" is a pass. A missing or erroring scanner must FAIL,
# never silently pass (the prior rg-based version silent-passed when rg was
# absent; <TEAM>-213 adds the same fail-closed contract to git enumeration). Accepts
# the same `-i`, `-e <pat>`, `--exclude=<basename>`, `--exclude-dir=<dir>`,
# <root...> vocabulary the call sites already use.
assert_absent() {
  local label="$1"; shift

  # Non-git tree (e.g. a plain-copy staging/export tree): no gitignored runtime
  # state exists, so the pre-<TEAM>-213 filesystem walk is correct + complete.
  # Behavior here is byte-identical to the original assert_absent.
  if [ "$_IS_GIT_WORKTREE" -eq 0 ]; then
    local hits status
    set +e
    hits="$(grep -rEn --exclude-dir=.git "$@")"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
      printf 'FAIL %s\n' "$label" >&2
      printf '%s\n' "$hits" >&2
      exit 1
    elif [ "$status" -gt 1 ]; then
      printf 'FAIL %s scan errored (grep exit %s); not treating as pass\n' "$label" "$status" >&2
      exit 1
    fi
    return 0
  fi

  local pattern=""
  local -a gopts=() excl_files=() excl_dirs=() roots=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -i)              gopts+=("-i"); shift ;;
      -e)              pattern="$2"; shift 2 ;;
      --exclude=*)     excl_files+=("${1#--exclude=}"); shift ;;
      --exclude-dir=*) excl_dirs+=("${1#--exclude-dir=}"); shift ;;
      *)               roots+=("$1"); shift ;;
    esac
  done

  # Roots arrive absolute ($repo_root or $repo_root/<subdir>). Convert to
  # repo-relative pathspecs so the absolute repo path — which contains a space
  # (".../Claude - Local/...") — never reaches git as a pathspec; subdir names
  # have no spaces. "." scans the whole repo.
  local -a relroots=()
  local r rel
  for r in "${roots[@]+"${roots[@]}"}"; do
    if [ "$r" = "$repo_root" ]; then rel="."; else rel="${r#"$repo_root"/}"; fi
    relroots+=("$rel")
  done

  # Enumerate committable files. Captured via command substitution (process
  # substitution would lose git's exit status); git failure FAILs the scan rather
  # than silently yielding an empty list that reads as "no hits → pass". This runs
  # at top-level script scope (assert_absent is called there), so `exit` aborts
  # the whole script — do NOT move this into a `$(...)`-called helper, where exit
  # would only kill the subshell.
  # core.quotePath=false: emit non-ASCII filenames raw so they are scanned, not
  # C-quoted into a non-existent path (Codex adversarial F2). Control-char names
  # (e.g. newline) are still quoted by git; bash then greps a non-existent operand
  # and exits >1 → fail-closed (the PS twin guards the quoted form explicitly).
  local files_raw status
  set +e
  files_raw="$(git -C "$repo_root" -c core.quotePath=false ls-files --cached --others --exclude-standard -- "${relroots[@]+"${relroots[@]}"}")"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    printf 'FAIL %s: git ls-files enumeration errored (exit %s); not treating as clean\n' "$label" "$status" >&2
    exit 1
  fi

  # Apply the basename / dir-component excludes, then build absolute paths for
  # grep (absolute keeps the FAIL output format identical to the prior `grep -r`
  # and to the PS twin's FullName).
  local -a absfiles=()
  local f base d x skip
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="${f##*/}"
    skip=0
    for x in "${excl_files[@]+"${excl_files[@]}"}"; do
      if [ "$base" = "$x" ]; then skip=1; break; fi
    done
    [ "$skip" -eq 1 ] && continue
    for d in "${excl_dirs[@]+"${excl_dirs[@]}"}"; do
      case "/$f/" in */"$d"/*) skip=1; break ;; esac
    done
    [ "$skip" -eq 1 ] && continue
    absfiles+=("$repo_root/$f")
  done <<< "$files_raw"

  # No committable files under these roots → nothing can leak → pass.
  [ "${#absfiles[@]}" -eq 0 ] && return 0

  local hits gstatus
  set +e
  hits="$(grep -En "${gopts[@]+"${gopts[@]}"}" -e "$pattern" -- "${absfiles[@]}")"
  gstatus=$?
  set -e
  if [ "$gstatus" -eq 0 ]; then
    printf 'FAIL %s\n' "$label" >&2
    printf '%s\n' "$hits" >&2
    exit 1
  elif [ "$gstatus" -gt 1 ]; then
    printf 'FAIL %s scan errored (grep exit %s); not treating as pass\n' "$label" "$gstatus" >&2
    exit 1
  fi
}

required_core=(
  "core/operating-system.md"
  "core/self-improvement.md"
  "core/memory-model.md"
  "core/verification.md"
  "core/tool-use.md"
)

required_playbooks=(
  "playbooks/harness-entrypoints.md"
  "playbooks/data-readiness-map.md"
  "playbooks/goal-run.md"
)

required_verification=(
  "verification/process-memory.md"
  "verification/data-readiness.md"
)

required_dirs=(
  "verification"
)

for path in "${required_core[@]}"; do
  if [ ! -f "$repo_root/$path" ]; then
    printf 'FAIL missing required core file: %s\n' "$path" >&2
    exit 1
  fi
done

for path in "${required_dirs[@]}"; do
  if [ ! -d "$repo_root/$path" ]; then
    printf 'FAIL missing required directory: %s\n' "$path" >&2
    exit 1
  fi
done

for path in "${required_playbooks[@]}"; do
  if [ ! -f "$repo_root/$path" ]; then
    printf 'FAIL missing required playbook: %s\n' "$path" >&2
    exit 1
  fi
done

for path in "${required_verification[@]}"; do
  if [ ! -f "$repo_root/$path" ]; then
    printf 'FAIL missing required verification file: %s\n' "$path" >&2
    exit 1
  fi
done

for entrypoint in AGENTS.md CLAUDE.md; do
  if [ ! -f "$repo_root/$entrypoint" ]; then
    printf 'FAIL missing harness entrypoint: %s\n' "$entrypoint" >&2
    exit 1
  fi
  if ! grep -q 'README\.md' "$repo_root/$entrypoint"; then
    printf 'FAIL harness entrypoint %s does not reference README.md\n' "$entrypoint" >&2
    exit 1
  fi
  if ! grep -q 'core/' "$repo_root/$entrypoint"; then
    printf 'FAIL harness entrypoint %s does not reference core/\n' "$entrypoint" >&2
    exit 1
  fi
done

# The Windows arm matches a drive-letter home path (C:\Users\…), mirroring the
# /Users/ and /home/ intent. It must NOT be a bare `[A-Za-z]:\\` — that flags
# every `:\` in regex code (e.g. vendored JS snapshots are full of `:\s`).
# Excluded entries (applied to every broad-repo scan below):
#   --exclude=local.env     gitignored, machine-local by design.
#   --exclude=check-drift.sh self-referential (the script names the patterns).
#   --exclude=.git          worktree gitlink file (a regular file, not the .git
#                           directory) holds an absolute `gitdir:` path — false
#                           positive when running inside a linked worktree.
#   --exclude=.mcp.json     per-project MCP config; operator-installed MCP
#                           servers may write absolute `command:` paths here
#                           (PATH-hijack mitigation pattern). Gitignored,
#                           machine-local — parallel to local.env, just for
#                           a different operator-managed tool. (<TEAM>-90: the
#                           historical example was codegraph, unwired from
#                           the framework; the exclusion stays — any
#                           operator-installed MCP follows the same pattern.)
#   --exclude-dir=.claude,
#   --exclude-dir=.codex,
#   --exclude-dir=.agents   harness-local state (worktrees, settings.local.json,
#                           plugin caches). All three are gitignored harness-
#                           config dirs at repo root (parallel to <TEAM>-60's
#                           forbidden-roots loop in validate.sh). Adding all
#                           three keeps the drift gate harness-agnostic.
#   --exclude-dir=cross-model-out
#                           runtime artifact dir for cross-model-review skill
#                           outputs (per-run subdirs with codex-review.md,
#                           gemini-review.md, reconciled.md, log.md ledger).
#                           Codex CLI prepends a `workdir: <abs-path>` header
#                           on every `codex exec` capture; without this prune
#                           that header trips the path scan when validate.sh
#                           runs from a worktree where a run was captured.
#                           Gitignored (parallel to .codegraph/), driver-local,
#                           never framework content. (<TEAM>-87.)
#
# <TEAM>-52 H6: the path scan no longer blanket-excludes docs/plans/. Tracked
# plans must use portable paths — env-var placeholders ($AI_CONFIG_DIR,
# $CLAUDE_CONFIG_DIR, $CODEX_HOME, $CROSS_MODEL_OUT_DIR) or generic shorthand
# (<project-key>) — not concrete personal paths. If a future plan
# legitimately needs to quote a path REGEX pattern (e.g. documenting "/Users/"
# as a scanner input), add `--exclude=<filename>.md` to THIS scan call, NOT a
# blanket dir exclusion. The operator-naming denylist scan below keeps
# --exclude-dir=plans because plans may quote a closed project name
# in historical record. `--exclude=drift.test.sh` mirrors the <TEAM>-51
# operator-naming pattern — the test file deliberately injects sentinel paths to
# prove this scan fires. `check-machine-paths.{sh,ps1}` + `machine-paths.test.{sh,ps1}`
# are excluded on the same principle as check-drift/check-clean self-exclude: a
# machine-path scanner quotes the very home-path shapes it hunts for (in its doc +
# its fixtures), so scanning it self-trips. The scanner still runs over every other
# file, and its own hermetic tests prove it fires.
# <TEAM>-66 C-1: tighten the local-path pattern from a bare substring match
# (`/Users/`, `/home/`, `[A-Za-z]:\Users`) to a class-shape match that
# requires a real username segment. Catches the same operator-leak class
# without false-positiving on lone `/Users/` tokens that may appear in
# regex code or prose. Matches:
#   /Users/<user>/            macOS home (`<user>` = 1+ non-slash chars)
#   /home/<user>/             Linux home
#   [A-Za-z]:\Users\<user>\   Windows home
# `.claude/worktrees/<branch>/.git` gitlink files legitimately contain
# `/Users/<operator>/` inside the worktree's absolute gitdir path; they're
# pruned by `--exclude-dir=.claude` (etc.) above. The <TEAM>-66 C-1 negative
# test in tests/drift.test.sh pins that prune behavior.
assert_absent 'machine-specific absolute path found in repository content' \
  --exclude=check-drift.sh --exclude=check-drift.ps1 \
  --exclude=local.env --exclude=.git \
  --exclude=.mcp.json \
  --exclude=drift.test.sh \
  --exclude=drift.test.ps1 \
  --exclude=2026-05-22-t-50-windows-native-port.md \
  --exclude=scripts-ps-parity.test.sh \
  --exclude=check-clean.sh \
  --exclude=check-clean.ps1 \
  --exclude=check-machine-paths.sh \
  --exclude=check-machine-paths.ps1 \
  --exclude=machine-paths.test.sh \
  --exclude=machine-paths.test.ps1 \
  --exclude-dir=.claude --exclude-dir=.codex --exclude-dir=.agents \
  --exclude-dir=cross-model-out \
  -e '/(Users|home)/[^/]+/?|[A-Za-z]:\\Users\\[^\\]+\\?' "$repo_root"

# <TEAM>-51 / <TEAM>-146: operator-PRIVATE personal-naming denylist. The scan lives in
# a separate sourced fragment (scripts/lib/operator-naming-check.sh) that the
# public-snapshot ship-set denylist EXCLUDES — so the public template never
# ships the operator handle literal, while the private repo still runs the
# check. Source it CONDITIONALLY: run if present, skip silently if absent (a
# public-template user has no operator handle to defend against, so the check is
# correctly vestigial there). The fragment relies on `assert_absent` + `repo_root`
# being in scope, which they are at this point.
_operator_naming_check="$(dirname "${BASH_SOURCE[0]}")/lib/operator-naming-check.sh"
if [ -f "$_operator_naming_check" ]; then
  # shellcheck source=scripts/lib/operator-naming-check.sh
  . "$_operator_naming_check"
  operator_naming_check
fi
unset _operator_naming_check

assert_absent 'device-dependent review lane found in baseline skills catalog' \
  -i -e 'local[- ]brain|three[- ]brain' "$repo_root/skills"

# Harness-agnostic guard: shared dirs carry no single-harness tool/hook/plugin
# names or harness-specific paths. Symmetric AGENTS.md/CLAUDE.md mentions are NOT
# denied; harness-entrypoints.md is the one playbook allowed to discuss setup.
# The trailing alternation groups are the Hermes token set (hook event names, the
# Hermes home dir, Hermes-specific tool names) and then the Cursor token set
# (its config dir, its camelCase hook event names, and its CLI config filename)
# — harnesses/hermes/ and harnesses/cursor/ are the only homes
# for those, same rule as the Claude/Codex tokens before them. `preToolUse` etc.
# are spelled here in Cursor's camelCase; the PascalCase Claude/Codex spellings
# are already denied above, and the two are distinct literals.
assert_absent 'single-harness token found in shared framework content' \
  --exclude=harness-entrypoints.md \
  -e 'WebFetch|WebSearch|TodoWrite|NotebookEdit|PreToolUse|PostToolUse|SessionStart|UserPromptSubmit|[Ss]uperpowers|\.claude/|\.codex/|\.agents/|on_session_start|on_session_end|pre_tool_call|post_tool_call|pre_llm_call|\.hermes/|SOUL\.md|skill_manage|delegate_task|\.cursor/|preToolUse|postToolUse|sessionStart|sessionEnd|beforeShellExecution|afterFileEdit|cli-config\.json' \
  "$repo_root/core" "$repo_root/playbooks" "$repo_root/verification" \
  "$repo_root/skills" "$repo_root/capabilities" "$repo_root/linear" "$repo_root/obsidian"

printf 'PASS drift and portability checks\n'
