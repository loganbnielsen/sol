---
id: FEAT-021
type: feature
severity: medium
source: docs/planning/POST_DOGFOOD_GAMEPLAN.md
branch: FEAT-021/deployment-plan-topics-migrations
worktree: /home/lbendtly/Code/sun-FEAT-021-deployment-plan-topics-migrations
---

Include Kafka topics and migrations in deployment plans.

**Depends on:** None.

**Problem:** Dogfood showed `sun deploy --emit-plan-to` serializes
`"topics": []` and `"migrations": []` even when the workspace defines event
contracts and SQL migration files. Operators cannot review event or schema
impact before applying a deployment.

**Goal:** Make the deployment plan complete enough for review, release
inspection, and hosted diagnostics.

**V1 decision:** This ticket is static workspace discovery only. It does not
connect to Kafka, the schema registry, or Postgres. The plan should say "this
workspace contains these topics and migration files," not "these topics exist in
the cluster" or "these migrations are pending."

**Remediation:**

1. Scan `events/` for `topic_name` declarations and include deterministic topic
   names in the deployment plan.
2. Scan `db/migrations/` for ordered migration files and include them in the
   deployment plan.
3. Keep the first pass static and filesystem-based. Pending/applied database
   state can be a follow-up when a database URL is available.
4. Add tests for topic discovery, migration discovery, deterministic ordering,
   and JSON serialization.
5. Update `pp_summary` so human-readable plans show topic and migration impact.

**Implementation notes:**

- Topic discovery may start with the generated workspace convention:
  `events/**.ml` files containing a literal `let topic_name = "..."`.
- Migration discovery should include `db/migrations/*.sql` sorted by filename.
- If discovery cannot parse a file, skip it and leave a warning path for a
  follow-up. Do not fail deploy on non-generated OCaml source in this ticket.

**Out of scope:**

- Checking whether topics already exist in Kafka.
- Checking schema compatibility or schema subjects.
- Checking whether migrations are pending/applied in a target database.
- Inferring consumer groups or ACLs.

**Acceptance criteria:**

- A generated workspace with a `Charged.topic_name` appears in `topics`.
- SQL files under `db/migrations/` appear in `migrations` in sorted order.
- Plan JSON remains deterministic and contains no secret values.
- The dogfood workspace no longer produces empty topic/migration arrays.
