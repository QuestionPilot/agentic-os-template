# Code Change Verification

Use for source-code changes, scripts, tests, or behavior changes.

## Proof

- Run the smallest targeted tests for the changed behavior.
- Non-trivial logic (a branch, a loop, a parser, a money or security path) leaves at least one runnable check behind — the smallest thing that fails if the logic breaks (an assert-based self-check or one small test file, no new frameworks). A floor, not a ceiling: never reduce existing coverage to it. Trivial one-liners need none.
- Run type, lint, format, or shell syntax checks when relevant.
- Run a smoke test if the code has runtime behavior.
- Inspect failures directly before claiming completion.
- When the change is a fix, follow `../playbooks/root-cause-debugging.md`: demonstrate the root cause before editing and ship a regression test that would have caught the bug.
- Decide whether independent review is warranted by risk.

## Review cuts

Two cheap, mechanical passes to run on the diff before opening a PR:

- **Git hygiene.** Every runtime-artifact path the change writes — open-for-write, `>`/`>>`, `mkdir`, `touch`, logs, caches, lockfiles, generated output — must be matched by a `.gitignore` rule. An unignored artifact path lets an auto-committer or a tree-walking scanner pick up runtime files and self-pollute (the failure class behind the framework's own scanner-vs-gitignore fixes).
- **Delete more than you add.** Run a deletion pass on the diff — one line per finding, `file:line: <tag> <what>. <replacement>.`, closing with `net: -N lines`. Tags: `delete:` (dead or speculative code → nothing replaces it), `stdlib:` (hand-rolled what the standard library ships → name it), `native:` (a dependency doing what the platform already does → name the feature), `yagni:` (a one-implementation abstraction, config nobody sets, a layer with one caller → inline it), `shrink:` (same logic, fewer lines → show the shorter form). A net +500-line diff with fewer than ~50 deletions is the loud prompt to run it — additive-only growth is how a codebase bloats, and boring-over-clever is the posture.
  - **Never cut the floor.** A deletion pass never removes, without explicit approval: input validation at trust boundaries, error handling that prevents data loss, security, accessibility, the calibration real hardware needs, existing regression coverage, the one check non-trivial logic must leave behind, public or back-compat contracts, or behavior the system already promises. Leanness is less code, never a flimsier result.

## Pre-PR

For changes inside this repository, run `make verify` from the repo root — runs the acceptance suite (`tests/run.sh`) when present, then `scripts/validate.sh` and `scripts/check-drift.sh --manifest "$CLAUDE_CONFIG_DIR"` in sequence, failing fast on first non-zero exit.

## Closeout

State changed-surface proof, skipped checks, independent review decision, and residual risk.

A green verdict belongs to the artifact state it ran on — name that state (commit or digest) with the verdict. Any later change to the artifact needs fresh proof. A run that follows a failure names which earlier failure it supersedes, and it supersedes only a failure on a check it re-ran green.
