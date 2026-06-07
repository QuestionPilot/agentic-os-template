---
title: Data Readiness
tags:
  - memory-vault/system
  - agentic-os/data-readiness
---

# Data Readiness

Data readiness is the back-of-house layer that makes the Agentic OS useful.

The rule is simple: agents should spend their context on synthesis and decisions, not on dragging raw exports, PDFs, transcripts, screenshots, and JSON through every session.

## Pantry, Prep, Plate

Use this map before building agents, automations, or dashboards.

| Layer | Meaning | Memory location |
|---|---|---|
| Pantry | Raw systems, files, APIs, exports, transcripts, source folders | [[20-Raw/sources]] |
| Prep | Deterministic summaries, tables, briefs, converted markdown, "silver platter" files | [[50-Outputs/README|Outputs]] |
| Plate | Human-facing briefs, recommendations, decisions, reports, Linear-ready actions | [[50-Outputs/README|Outputs]], Linear, [[03-Decisions/_index]] |

## Silver Platter Rule

A silver platter is a concise, source-derived summary that gives the agent the numbers, themes, or source cuts it needs before it reasons.

Use prepared outputs when:

- the raw source is too large for repeated reading
- the source is messy or non-markdown
- the question recurs weekly or monthly
- the source is regulated, client-specific, matter-specific, or project-specific
- the agent would otherwise spend most of the run retrieving instead of analyzing

## Readiness Audit

For each project or area, identify:

- pantry sources: systems, files, APIs, Drive folders, exports, transcripts
- access method: manual export, CLI, API, connector, browser, or local file
- prep artifact: summary table, weekly brief, converted markdown, or source index
- plate output: brief, decision, report, Linear issue, or project action
- approval gate: who reviews human-facing or business-critical outputs
- boundary: what data must not cross project, client, matter, patient, or tenant lines

## Critical Path

Do not create a specialist agent until the data path is clear:

1. Source exists.
2. Source is listed in [[20-Raw/sources]] or the source system is named.
3. Raw material is converted or summarized.
4. Silver platter has a consumer.
5. Output has an approval gate when needed.
6. Repeated work is eligible for Linear, a playbook, a script, or an automation.

## Regulated Or Sensitive Data

Sensitive data needs namespacing before automation.

- Keep raw sensitive sources out of public or shared repos.
- Store only safe summaries in Memory unless the user explicitly approves otherwise.
- Namespace by project, client, matter, patient, provider, account, or location when cross-contamination would matter.
- Prefer aggregate prepared outputs when the agent does not need raw details.

## Dashboard Rule

Do not build a dashboard first. Build the pantry/prep/plate map, prove the prepared outputs are useful, then visualize what is already working.
