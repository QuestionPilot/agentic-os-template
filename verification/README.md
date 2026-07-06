# Verification Recipes

Use these recipes to choose the smallest proof pattern that actually verifies the changed surface.

Project-local scripts and current user instructions remain the source of truth. These recipes are framework defaults, not daily logs.

**Recipes, not enforced gates.** These are honor-system *recipes* — proof patterns you choose and run by judgment. Most are not mechanically enforced; only a few checks actually block (for example, `make verify` and the CI cleanliness scan). Where a capability's routing says "name the verification gate," it means *pick the matching recipe here* — "gate" denotes the routing step, not an automated block.

## Recipes

| Work type | Recipe |
| --- | --- |
| Documentation or framework rules | `docs-framework.md` |
| Code changes | `code-change.md` |
| UI or browser-visible work | `ui-browser.md` |
| Deploy or live publish | `deploy-live.md` |
| Auth, billing, permissions, or secrets | `high-risk.md` |
| Toolchain or capability freshness | `tool-freshness.md` |
| Memory, process, or SOP changes | `process-memory.md` |
| Data-readiness maps or silver platter summaries | `data-readiness.md` |
| Repeated accuracy or readiness checks | `audit-systems.md` |
| Framework self-audit runs (the `self-audit` spine capability) | `self-audit.md` |

## Rule

Run the lightest recipe that proves the work. Add stronger proof when the blast radius includes production, money, auth, permissions, user data, or high-visibility user experience.

When a recurring workstream keeps relying on the same manual checklist, consider turning the stable parts into a read-only audit script. Audits should improve accuracy and retrieval, not become ceremony.
