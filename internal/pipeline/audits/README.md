# Audit procedures

This directory contains reusable review procedures. An audit reads current code, documentation,
provider contracts, qualification matrices, and evidence; it does not own repository state.

| Procedure | Purpose |
| --- | --- |
| `AUDIT.md` | production readiness: security, runtime correctness, data integrity, infrastructure |
| `UX_AUDIT.md` | first-run experience and reproducibility |
| `DOCS_AUDIT.md` | documentation truth against implementation |
| `SCAFFOLD_AUDIT.md` | generated workspace/service contract |
| `STYLE_AUDIT.md` | OCaml style, type safety, and API design |
| `TYPE_AUDIT.md` | boundary parsing and abstract-type discipline |

A finding has no special audit lifecycle. Fix it in the current change when appropriate or file an
ordinary GitHub Issue with the observation and acceptance criteria. If an audit establishes or
falsifies a qualification claim, update the matrix that owns the claim and cite the evidence record.
If it finds stale documentation, edit the owning document.

Do not commit findings registries, status ledgers, dated audit reports, or a second work queue.
History belongs in Git and pull requests; current qualification state belongs in its owning matrix.
