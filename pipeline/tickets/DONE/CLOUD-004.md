---
id: CLOUD-004
type: feature
severity: high
source: docs/planning/POST_DOGFOOD_GAMEPLAN.md
branch: CLOUD-004/postgres-control-plane-registry
worktree: ../sun-CLOUD-004-postgres-control-plane-registry
---

Persist the hosted control-plane registry in Postgres.

**Depends on:** RELEASE-003.

**Problem:** The hosted project, environment, deploy, and release APIs have the
right product shape, but they still rely on local or in-memory registry state.
That makes the hosted lane impossible to operate across process restarts and
prevents account/environment isolation from being enforced consistently.

**Goal:** Replace the in-memory hosted registry with a durable Postgres-backed
control-plane store while preserving the existing hosted API and CLI behavior.

**Remediation:**

1. Find the hosted registry boundary used by `sun cloud` commands and hosted
   API handlers.
2. Add a Postgres-backed implementation for projects, environments, releases,
   and release logs.
3. Add migrations for the hosted control-plane schema.
4. Make the hosted executor select the Postgres implementation when a database
   URL is configured, with the current in-memory implementation retained only
   for tests or explicit local stub mode.
5. Add tests for persistence across process reinitialization.
6. Document the required control-plane database environment variable in the
   hosted development docs.

**Acceptance criteria:**

- Hosted projects and releases survive process restart in Postgres-backed mode.
- Existing `sun cloud` tests still pass.
- New tests prove create/list/get behavior against the persistent registry.
- In-memory mode remains available for fast local tests.
- Missing database configuration fails with a clear error outside explicit stub
  mode.

**Out of scope:**

- Authentication and tenant isolation.
- Real image builds.
- Billing and quota enforcement.
