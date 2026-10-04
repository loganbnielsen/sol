# The audit activity

This directory holds **the definitions of Sol's audit passes** — nothing else. An audit is an
*activity*: it reads the code, the provider contracts, the matrices and the run records, and it
produces work. It keeps no state of its own.

## The rulebooks

One per pass. Each is the checklist the pass works through, and each is read in full by the
skill that runs it (`.agents/skills/<name>/SKILL.md`).

| Rulebook | Skill | What it checks |
|---|---|---|
| `AUDIT.md` | `/audit` | production readiness: security, runtime correctness, data integrity, infrastructure synthesis |
| `UX_AUDIT.md` | `/ux-audit` | the first-run experience: docs gate and reproduction gate |
| `DOCS_AUDIT.md` | `/docs-audit` | documentation truth: every claim matches implementation |
| `SCAFFOLD_AUDIT.md` | `/scaffold-audit` | what `sol new` generates |
| `STYLE_AUDIT.md` | `/style-audit` | OCaml style, type safety, API design |
| `TYPE_AUDIT.md` | *(run directly)* | one rule: parse at the boundary, keep the abstract type in the middle |
| `STYLE_AUDIT_FINDINGS.md` | *(reference)* | the finding shapes `STYLE_AUDIT.md` and `TYPE_AUDIT.md` produce |

## What a pass produces

Exactly three things, each landing in the home that already owns it:

1. **A ticket** (`internal/pipeline/tickets/`) for anything actionable. The ticket carries its
   evidence inline — the verbatim observation, the mechanism, the acceptance criteria — so it
   justifies itself instead of pointing at a registry.
2. **A row verdict** in the matrix that owns the claim (`internal/qualification/<provider>/…`, or
   `ALPHA_CAMPAIGN.md` for the alpha surface), with its evidence class and a pointer to the run
   record. Only a pass that established something *behaviourally* may strengthen a row.
3. **A documentation edit** when the finding is that the product behaves a certain way and
   nothing states it (`docs/`).

A pass that finds nothing actionable produces no files at all. That is a valid result.

## What a pass must not produce

- **No findings registry.** A durable statement about qualification state belongs on the row it
  concerns, in the ticket it became, or in the decision it produced. A second store with its own
  lifecycle (classification, state, supersession) duplicates the matrix and drifts from it.
- **No status ledger.** "What does Sol know" is a read of the matrices' verdicts plus the ticket
  queue; a hand-maintained summary cannot stay truthful — the last one held two tables that
  contradicted its own later sections.
- **No report kept as state.** A pass may write a report for its own use; if one is committed it
  is a document, and nothing reads it as state. A *contract* a pass produces — a capability
  inventory, a parity matrix — is not a report: it moves to its permanent home
  (`internal/specs/`, `docs/reference/`).

## Evidence classes (kept — this is the discipline)

`STATIC`, `MECHANISM`, `BEHAVIOURAL`: what the evidence *is*, never how confident someone feels.
A row may not be strengthened past the class its evidence supports, and an unobserved row is
`NOT RUN`, never "probably fine". `internal/qualification/README.md` and the matrices carry the
same vocabulary.

## Historical IDs

`FND-NNNN` ids belonged to the findings registry this activity used to keep. The registry is gone;
its content lives where the model puts it:

- findings that were actionable are now **tickets**, keeping their ids — `FND-0063`…`FND-0079` are
  in `internal/pipeline/tickets/BACKLOG/`;
- findings already carried by a ticket, a decision or a matrix row are gone from the tree, and
  their ids remain as historical citations;
- any `FND-NNNN` in a ticket or a commit message resolves through git:
  `git log --diff-filter=A -- 'internal/pipeline/audits/findings/FND-NNNN*'`.
