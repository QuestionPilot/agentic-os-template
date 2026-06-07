# Skills Registry

The framework ships **only the OS spine** — three homegrown, self-improving
capabilities. They live in `capabilities/` and `install.sh` installs them into the
operator's harness config dir:

| Capability | Purpose | Body |
| --- | --- | --- |
| Session Agent | Auto-fires at session start to orient (memory + tracker + vault + reconcile), then routes the prompt to the smallest useful capability chain | `@@AI_CONFIG_DIR@@/capabilities/session-agent.md` |
| Closeout | Walks the end-of-session questions, classifies each lesson, routes it to its source of truth | `@@AI_CONFIG_DIR@@/capabilities/closeout.md` |
| Self-Audit | Scores the framework on its leverage-weighted pillars and surfaces the top gaps | `@@AI_CONFIG_DIR@@/capabilities/self-audit.md` |

## Baseline Rule

The shipped surface stays spine-only. Tool and app skills — docs lookups, browser
automation, design front doors, database/CLI helpers, web research — are
**operator-local**: they live in the operator's own harness config, not in this
repository. This mirrors how the active-work tracker (`linear/linear-setup.md`) and
durable-knowledge vault (`obsidian/`) are documented as contracts but never
auto-installed. The general CLI-over-MCP preference lives in
[`../core/tool-use.md`](../core/tool-use.md).

Add a capability to the shipped spine only when it is broadly useful, clearly
triggered, easy to verify, self-improving, and not better represented as a
playbook, script, harness note, or verification recipe. For how to design and
author a skill well, see [`skill-authoring.md`](skill-authoring.md).
