# Migration ordering for `production-single-region` (AUDIT-069)

A production deployment must not roll application code out against a
known-incompatible database migration state. The deployable revision defines the
schema it expects; the deploy verifies that expectation against the authoritative
migration record before it moves any workload.

## The contract

```
required (db/migrations in this revision)  ⊆  applied (schema_migrations)
```

- **Required** is every `.sql` file in the workspace's `db/migrations`
  directory except `*.down.sql` (a rollback companion, not a migration). The file
  name carries the version (`001_create_orders.sql`).
- **Each version must be unique.** The tracking table records versions only, so of
  two files that share one, the second would be skipped forever once the first is
  applied. `sol migrate` and the deploy gate therefore refuse such a directory and
  name both files. Two branches that each add "the next" number produce exactly
  this; renumber one of them (BUG-041).
- **Applied** is what the workspace's tracking table
  (`sol_<workspace>_schema_migrations`, the table `sol migrate` writes) reports.
- Sol keeps **no second record** of "which migrations matter". A declaration in
  the target or `sol.yml` would let `db/migrations`, the deployment record and
  `schema_migrations` disagree about the schema.

The accepted consequence, stated plainly: **adding a file to `db/migrations` is
a declaration that the migration is a prerequisite for deploying that revision.**
A migration that is not meant to be applied yet should not be part of the
deployable revision's migration set yet.

The `-- sol:disposition expand|contract` header (DEC-018/FEAT-066) is *not* used
here. It answers a different question — whether a migration blocks rolling
*back* to an older release — and an expand migration is still required for code
that was written after it.

## Ordering

```
static preflight            (offline: renders the plan, checks profile guarantees)
live migration verification (read-only, in-cluster)
workload mutation           (the actual apply)
```

Verification happens **after** the static preflight and **before** the first
cluster mutation, so an unsatisfied prerequisite stops the deploy before
anything changes.

## How it is verified

A short-lived Kubernetes Job runs `sol migrate status --json`, which only reads
`schema_migrations` — it never applies a migration. The Job and its ConfigMap
are removed whether the check succeeds or fails. This reuses the same in-cluster
execution model as `sol migrate apply` (`FRIC-012`), so an operator never needs
direct database reachability:

- **Satisfied** — every required version is present; the deploy continues.
- **Unsatisfied** — the deploy fails and names the missing migrations plus the
  action: `sol migrate apply <target>`, then deploy again.
- **Unavailable** (the Job cannot run, the DB cannot be queried, the table
  cannot be read) — the deploy **fails closed**. It never substitutes a cached
  Sol-side record or assumes the schema is compatible.

## `--dry-run` and `--emit-to`

Both are side-effect free: they create no Job and no other cluster object. The
deploy reports the migration prerequisite as **not verified** — never as
established — and points at the command that verifies it. Dry-run exists to
render and check what *can* be checked offline; making it mutate the cluster
merely to prove a prerequisite would defeat it.

## Scope

- The check applies when a production profile is selected (`production-single-region`).
  A dev/local deploy makes no release-safety claim and is not checked.
- A workspace with no `db/migrations` requires nothing.
- Sol does **not** apply migrations as part of `sol deploy`. Applying is
  `sol migrate apply`; the deploy only verifies.
- No schema introspection: the tracking table is the only source.

## What the offline tests prove (and what they do not)

Offline tests prove the pure comparison and the encoding: `required ⊆ applied`,
version parsing, refusal of an unnumbered migration file, and the JSON
round-trip the deploy Job and the deploy path share. They also pin the
surrounding release-safety semantics that already existed: a failed deployment
attempt is never a recorded release (`test_deployment_attempt.ml`), rollback
verifies the live workload set before moving the pointer (`test_rollback.ml`),
and the same desired content yields the same release identity
(`test_release_id.ml`).

They do **not** prove the live behavior. HARDEN-002 must exercise, against a real
cluster and database: a deploy with migrations applied (succeeds), a deploy with
a required migration missing (fails before workload mutation with the
`sol migrate` instruction), an unreachable database (fails closed), and
`--dry-run` (succeeds, creates nothing).
