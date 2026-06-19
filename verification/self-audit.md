# Self-Audit Verification

Use for changes to the self-audit capability, its scoring script, or the rubric
the script encodes.

## Proof

- `bash scripts/self-audit.sh` runs against the current repo and produces a
  scorecard with no scripting errors, valid JSON under `--json`, and a non-
  empty top-gaps section if any pillar deducted.
- The five pillar scores are each in `[0, 20]`; the total is the sum.
- Pillar rubric changes are accompanied by fixture-based test changes in the
  acceptance suite's `tests/self-audit.test.sh` (positive + negative case per
  pillar).
- Graceful-degradation notes are emitted in the "Skipped surfaces" section
  when any of `lineark`, `OBSIDIAN_VAULT_PATH`, or `$CLAUDE_CONFIG_DIR/projects`
  is absent — the script never hard-fails on a missing operator surface.
- The capability never auto-remediates. The harness realizations'
  `allowed-tools` deliberately exclude `Write`/`Edit` so the model can't
  edit framework files while interpreting a scorecard. The script writes
  only when the caller passes `--save <path>` explicitly; that opt-in is
  the only file-mutating shell-out, and the destination is the caller's
  choice (operator's checkout, not Linear or the vault).
- Where the upstream acceptance suite is present, `bash tests/run.sh` includes
  the self-audit test file and passes.

## Closeout

State what the rubric changed, how the new behavior was tested against
fixtures, and whether independent review (e.g. a cross-model critic) was used. If the
rubric tightened (gaps newly surfaced that previously scored as PASS), name
each newly-surfaced class so a future operator-local audit run isn't
surprised by a score drop with no PR context.
