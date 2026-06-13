# Personal Fork — Run the Framework as Your Own OS

For an operator who wants to **use** this framework as their daily operating
system rather than **maintain** it as a clean public template. You are a
*consumer*, not the upstream *maintainer* — and most of the repo's hygiene
machinery is the maintainer's, not yours.

## The two roles

- **Maintainer** (the upstream author): publishes a clean public repo. Runs the
  publish-hygiene gates — the cleanliness guard (`scripts/check-clean.{sh,ps1}`),
  the commit-identity allowlist, the harness-neutrality governance — to keep
  operator identity and private tracker IDs out of a tree that strangers clone.
- **Consumer** (you): runs the framework on your own machine, customizes it, and
  keeps your own memory, projects, and vault. The publish-hygiene gates exist to
  protect the *upstream public repo* — they have no bearing on a copy only you use.

## Three postures — pick one

### L0 — Just use it (simplest; works today)
Clone, run `bash scripts/bootstrap.sh`, use it. Never push anywhere. Update with
`git pull`. Every publish guard is dormant because the cleanliness guard runs only
in the maintainer's CI and pre-push — and you are doing neither.

### L1 — Private copy, clean upgrade path
Keep your own *private* repo with the upstream added as a remote
(`git remote add upstream <maintainer-repo>` → `git pull upstream main`). Put every
personal addition in the overlays + `local.env` + your own config-dir `skills/` so
upstream pulls stay conflict-free (see "the one rule" below). A private repo also
means you can bake your identity straight in if you prefer.

### L2 — Fork and own it
Edit `core/` directly and diverge. Upstream pulls become cherry-picks. The drift
gate and harness-neutrality rules are maintainer disciplines you can ignore — it
is your framework now.

## Everything in one folder (co-located operation)

By default the harness config dirs (`.claude`, `.codex`, `.hermes`) live under
your home directory. To run everything out of the framework folder instead — so
your skills, projects, short-term memory, and all harnesses are co-located — point
the config-dir variables at gitignored subdirs of the repo. In `local.env`:

```bash
# Set the framework folder once, then co-locate each harness's config dir under it.
AI_CONFIG_DIR="/path/to/MyAgenticOS"
CLAUDE_CONFIG_DIR="$AI_CONFIG_DIR/.claude"
CODEX_HOME="$AI_CONFIG_DIR/.codex"
HERMES_HOME="$AI_CONFIG_DIR/.hermes"
```

Then re-run `bash scripts/install.sh --harness claude` (repeat per harness). The
compiled config and your runtime state render into those dirs; `.gitignore`
already ignores those harness config dirs so they are never staged; and
`scripts/validate.sh` recognizes a config dir that **is** your configured target
as legitimate runtime state rather than a leak.

The resulting layout:

```
MyAgenticOS/                          ← AI_CONFIG_DIR (the framework folder)
├── core/  capabilities/  skills/     ← framework SOURCE (tracked)
├── CLAUDE_CONFIG_DIR                 ← gitignored: compiled output + projects + memory
├── CODEX_HOME                        ← gitignored
├── HERMES_HOME                       ← gitignored
└── local.env
```

(Each config-dir line is the gitignored target you pointed the matching variable
at — conventionally a dot-dir under the repo.)

**Co-locate into the dot-subdirs, never the repo root itself.** Pointing a config
dir at the repo root would collide with the repo's own `skills/` source and trip
the loose-file guard on `settings.json` / `config.toml`.

There is still a `source → compile → output` boundary: the repo's `skills/` is
neutral *source*; the rendered `skills/` under your config dir is *compiled
output*. You drop your own skills straight into the config-dir `skills/` (they are
preserved across re-installs), but you do not edit the *compiled* framework skills
in place — edit the source and re-run `install.sh`.

## Turn off the maintainer-only machinery

These protect the upstream public repo. As a consumer you do not need them:

- **Cleanliness CI** (`.github/workflows/acceptance-suite.yml` runs `check-clean`):
  if you push your copy to your own GitHub repo and enable Actions, this guard
  rejects exactly the personal identity you now want baked in (it flags home paths
  and emails even without the operator token secret). Delete that workflow, or do
  not gate merges on it, and leave `OPERATOR_PII_TOKENS` / `COMMIT_IDENTITY_ALLOWLIST`
  unset.
- **Harness-neutrality governance** (no local paths or identity in shared content):
  a publishing constraint. Your private copy can carry your paths and identity freely.
- **The drift gate** (`scripts/check-drift.sh`): keep this one — it catches
  hand-edits to compiled output, which is a real footgun regardless of who you are.
  It only bites if you hand-edit the installed config instead of editing source and
  re-running `install.sh`.

## Updating from upstream

- **Fork / clone + remote:** `git remote add upstream <maintainer-repo>` then
  `git pull upstream main`. Resolve the rare conflict; keeping customizations in
  overlays (below) makes conflicts rare.
- **Template-repo path:** if the maintainer published via GitHub's *template
  repository* feature, your copy is a clean-slate repo with no fork link — add
  `upstream` manually to pull improvements, or cherry-pick the commits you want.

You cannot maximize both *clean ownership* and *frictionless upgrades* at once:
a template repo gives you a clean slate but a manual update path; a fork gives you
trivial `git pull upstream main` but is structurally "a copy of theirs." Pick the
one that matches how closely you want to track upstream.

## The one rule that protects your upgrade path

**Add, don't edit.** Put your skills, rules, and identity in the overlays
(`SKILLS_OVERLAY_PATH`, `CODEX_RULES_OVERLAY_PATH`, `SOUL_IDENTITY_PATH`) +
`local.env` + your config-dir `skills/`. Touch shared `core/` only when you are
ready to stop pulling upstream. That single discipline is the difference between a
fork that keeps benefiting from upstream improvements and one frozen at clone-time.
