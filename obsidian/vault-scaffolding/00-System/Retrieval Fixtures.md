---
title: Retrieval Fixtures
tags:
  - memory-vault/system
  - memory-vault/retrieval
  - verification
---

# Retrieval Fixtures

A fixed set of queries used to measure **retrieval**: given a question, does the
vault's full-text baseline surface the note that actually answers it?

## How to run

```bash
bin/retrieval-evals.sh          # every fixture + every negative control
bin/retrieval-evals.sh --list   # print the parsed fixture set and stop
```

Each fixture asserts that `bin/vault-search.sh` surfaces the named note within
the top `Max` results for the given query and scope. The runner exits non-zero
on any miss. [[00-System/Health Check]] separately checks that every `Must
surface` path still exists — a fixture pointing at a renamed or deleted note is
a broken pointer, and a broken pointer nobody notices is how a green test suite
starts lying.

## These fixtures are a starting shape, not your fixture set

Every row below is **synthetic**: it queries the scaffolding notes this vault
shipped with, because on day one that is the entire corpus. They exist so the
instrument is wired, runnable, and green from the first commit — not because
they measure anything you care about.

**Replace them as the vault grows.** A fixture earns its place by encoding a
question you have actually asked and would ask again. Once you have real
projects, decisions, and lessons, retire the scaffolding rows one at a time and
point the set at your own corpus. A fixture set that still tests only the
starter notes after six months of real work is measuring the packaging, not the
contents.

**Rules for use:**

- A fixture names ONE note it must surface — the note a careful reader would
  actually cite, not merely a note that mentions the words.
- Queries are written the way a session would really search: short key phrases,
  not reverse-engineered from the target note's vocabulary. A fixture that only
  passes because it quotes its target verbatim measures nothing.
- **Positive control:** every class below has at least one fixture. A class with
  none is a measurement gap, not a clean bill of health.
- **Negative controls** are as load-bearing as the positives: an instrument that
  cannot report "not found" will always find something, and a search surface
  that always answers is indistinguishable from one that is guessing.

### The before/after re-phrase protocol

When a fixture starts failing, the honest first question is *did the corpus
move, or did the surface break?* Answer it before touching the row:

1. Run the query by hand at the current tree. Read what came back.
2. If a DIFFERENT note is now the right answer — the content moved, the topic
   split, a better note was written — **re-point** the fixture at the new
   target and record the move in the audit log below. The fixture caught a real
   corpus change; that is it working.
3. If the right note still exists and still answers the question but no longer
   matches, **re-phrase** the query to the words a session would now naturally
   type, and record the old and new phrasing.
4. Only if neither holds is it a defect in `bin/vault-search.sh`. Fix the
   baseline, not the fixture.

Never edit a query solely to make a red row go green. A fixture tuned to its
own failure is a fixture that has stopped measuring. If you cannot say which of
the three cases applies, the row stays red until you can.

### Why this note is excluded from the search surface

This note quotes every fixture query verbatim, so if it were searchable it would
match all of its own positives *and* both of its negative controls — the
controls would go green for entirely the wrong reason. `bin/vault-search.sh`
excludes this file by glob, and the exclusion lives THERE rather than in the
runner deliberately: if the runner filtered it afterwards, the eval would be
measuring a surface no caller ever sees, and a control could pass while a real
session asking the same question got a match. The runner probes for that
divergence on every run and dies if the two surfaces disagree.

## Fixtures

| # | Query | Scope | Max | Must surface | Class |
|---|---|---|---|---|---|
| R1 | promotion test | durable | 4 | `00-System/Fresh Start Policy.md` | policy-lookup |
| R2 | source of truth | durable | 4 | `00-System/Source of Truth.md` | policy-lookup |
| R3 | session summary | durable | 4 | `00-System/Wrap-Up Workflow.md` | workflow-lookup |
| R4 | ingest workflow | durable | 4 | `00-System/Ingest Workflow.md` | workflow-lookup |
| R5 | query workflow | durable | 4 | `00-System/Query Workflow.md` | workflow-lookup |
| R6 | broken wikilinks | durable | 4 | `00-System/Health Check.md` | verification |
| R7 | stale memory | durable | 4 | `00-System/Observability.md` | verification |
| R8 | goal run | durable | 4 | `00-System/Goal Run Standard.md` | standard-lookup |
| R9 | pantry | durable | 4 | `00-System/Data Readiness.md` | standard-lookup |
| R10 | lesson | durable | 4 | `04-Lessons/_index.md` | index-entry-point |
| R11 | vault map | durable | 4 | `90-Indexes/Vault Map.md` | index-entry-point |
| R12 | linear handshake | durable | 4 | `00-System/Linear Handshake.md` | cross-layer-handoff |

Classes cover the six shapes of question a fresh vault can be asked: policy
lookup (R1, R2), workflow lookup (R3, R4, R5), verification (R6, R7), standard
lookup (R8, R9), index entry point (R10, R11), and cross-layer handoff (R12).
Add your own classes as your corpus grows real ones — a class is only useful if
losing coverage of it would matter.

## Negative controls

Queries that MUST return no durable match. They prove the baseline can report
absence — the property a cached or frozen surface lacks, and the reason such a
surface can answer a question long after its evidence ran out without ever
signalling the gap.

| # | Query | Scope | Expected |
|---|---|---|---|
| N1 | zzzz-no-such-concept-in-this-vault | durable | no matches (exit 1) |
| N2 | kubernetes ingress controller | durable | no matches (exit 1) |
| N3 | quarterly revenue forecast spreadsheet | durable | no matches (exit 1) |

N1 is the pure sentinel — a token that cannot plausibly ever appear. N2 and N3
are the meaningful ones: plausible phrases from domains this vault has no notes
on. If either starts matching, either the vault grew a real note on the subject
(fine — retire the control and write a positive fixture instead) or the search
surface has loosened enough to return near-misses as answers, which is the
failure worth catching early. Replace them with plausible-but-absent phrases
from YOUR adjacent domains as the corpus fills in; a control that could never
match anything stops being a control.

## Known limits

- **Phrases are literal, not conceptual.** The baseline matches the words you
  type, in the order you type them. A hyphenation difference is enough to miss.
  Search short key phrases, try more than one phrasing, and start from the
  curated indexes ([[90-Indexes/Vault Map]], [[04-Lessons/_index]],
  [[03-Decisions/_index]]) when a concept could be worded several ways.
- **A green run is not evidence of replacement-level recall.** Every positive
  here uses a contiguous phrase present in its target, so the set measures
  lexical lookup. Paraphrase, synonym, and relationship fixtures are the honest
  next extension, and they will only be writable against a real corpus.
- **Ranking is by hit count, not relevance.** A long note that mentions a phrase
  in passing can outrank the short note that defines it. That is why fixtures
  declare a `Max` — the assertion is "in the top N", not "first".

## Stale-versus-current precedence

The rule that outranks any search result: **a dated source must surface its own
cutoff.** [[00-System/Recall Workflow]] states the general form — current source
notes outrank the archive, and the archive outranks any cached or derived
surface. A session log records what was believed at closeout;
[[90-Indexes/Session Index]] makes those records findable but does not promote
them to fact. When the archive and a current note disagree, the current note
wins and the disagreement is worth saying out loud.

## Audit log

Record every change to this set here — what moved, why, and whether the row was
re-pointed or re-phrased. A fixture set with no history is one nobody has had to
defend.

- Set created with R1–R12 and three negative controls against the scaffolding
  corpus, alongside `bin/vault-search.sh` (the deterministic full-text baseline)
  and `bin/retrieval-evals.sh` (the runner). All positives and all controls
  passed on creation. Every row is synthetic and expected to be replaced.
