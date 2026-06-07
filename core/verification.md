# Verification

Verification should prove the changed surface, not create performative confidence.

## Minimum Standard

Before meaningful closeout:

- run the smallest relevant local or remote check
- inspect decisive output
- name any skipped check and why
- classify residual risk

## Verification Types

| Work type | Useful proof |
| --- | --- |
| documentation or operating rules | lint, link check, drift check, review against governance |
| code changes | targeted tests, type checks, lint, smoke test |
| UI changes | browser check, screenshots when visual quality matters, accessibility pass when relevant |
| deploy or publish | live smoke, deployed version proof, rollback awareness |
| security, auth, billing, permissions | independent review plus end-to-end proof where possible |
| memory or process changes | retrieval path, closeout classification, drift check |
| toolchain or capability changes | current-version check, install/change proof, non-interactive smoke test |

For detailed framework recipes, use `verification/README.md`.

## Independent Review

Use independent review when risk or ambiguity warrants it. Treat external model output as advice, not proof. The primary agent remains responsible for verification.

## Audit Creation

When the same readiness or stale-state question recurs, prefer a small read-only audit over repeated manual memory. Good audits check required files, parseable config, links or indexes, secret/artifact absence, source-of-truth boundaries, and tool availability where relevant. They should print clear `PASS`, `WARN`, and `FAIL` lines with a summary.

Do not turn every checklist into a script. Create audits when the check is repeatable, non-destructive, and likely to prevent real misses across future agents or machines. Use `verification/audit-systems.md` for the default pattern.

## Check Integrity

A check that cannot run must fail, never pass. Deterministic checks and audits must be portable and fail-closed:

- Do not depend on tools that exist only as an interactive-shell convenience or a harness-provided shim. Use baseline POSIX tools, or detect the dependency and `FAIL` with a clear message.
- Treat a missing or erroring scanner as `FAIL`, not `PASS`. A silently skipped security or drift scan is worse than a loud failure.
- Prove a new or changed check actually fails on a real violation, not only that it passes when clean.
