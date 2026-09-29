# Targeted job-queue isolation audit — 2026-09-29

Audited clean canonical `main == origin/main` at `81b15e539b9a3353ff9510fe6d3663ba204e9f7c`, after PR #726 merged with green CI. No finding was implemented.

## Scope and reconciliation

Read the current roadmap, work summary, production-audit guidance, `sol-jobs` package contract and implementation, its Postgres tests, local Postgres setup, and the prior cross-claim and workspace migration tickets. BUG-088–090 are already filed in merged PR #726 and are not repeated. This is a targeted source audit, not a live database run.

## BUG-091 — jobs from separate workspaces can cross-claim in one database

**Status: Open. Severity: High. Category: Data Integrity / Domain Architecture.**

`Sol_jobs` uses the fixed `sol_jobs` table (`framework/ocaml/sol-jobs/lib/sol_jobs.ml:130`). `enqueue` inserts only `(kind, payload, run_at)` (`:253-269`); `claim_q` selects by pending status, kind, due time and lease (`:132-150`). Neither stores or filters workspace identity. `J.kinds` is application-defined and commonly generic, such as `send_email` in the package's own tests. Two workspaces using the same Postgres database and kind therefore claim from the same queue, even if they define different payloads or handlers. One may execute another workspace's side effect, or repeatedly fail decode and terminally fail its job.

The shared-database case is supported by Sol's local path: `platform/local/scripts/ensure-postgres.sh` starts one database (`sol_dev` by default), and `cmd_up.ml:28-35` supplies a fixed in-cluster `dev` URL when `POSTGRES_URL` is absent. The workspace-prefixed migration tracking table exists specifically because multiple workspaces can share a database (AUDIT-024). `test_sol_jobs_pg.ml:91-124` proves distinct kinds do not cross-claim within a table; it never runs two workspaces with the *same* kind. This is source/SQL evidence with a positive control, not a live claim reproduction.

**Remediation:** scope enqueue, claim and finalization by workspace identity, with a migration/table contract that preserves transactional enqueue and same-workspace multi-replica claims. The scope must come from the framework/app boundary rather than relying on application authors to invent globally unique `kind` strings.

## Candidates rejected and limits

- A `J.handle` exception escapes the job loop. The `JOB` interface requires a `result`, and a distinct high-severity outcome beyond app contract violation was not verified; no ticket filed.
- `sol-svc` request body and verified JWT paths were read; existing size, signature, issuer, audience, and temporal checks covered the suspected gaps. No ticket filed.

No database, Kubernetes, broker or provider state was mutated. The implementation ticket calls for a shared-database regression. No source code was changed.
