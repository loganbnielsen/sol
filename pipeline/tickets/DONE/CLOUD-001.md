---
id: CLOUD-001
type: feature
severity: high
source: product-planning-2026-06-10
branch: CLOUD-001/project-registry
worktree: ../sun-CLOUD-001-project-registry
---

Add a hosted project registry and control-plane stub.

**Depends on:** None.

**Problem:** Sun has a `sun cloud deploy` path but no server-side model for what a "project" or "account" is. Before hosted deploys can return real release records, URLs, or logs, the control plane needs a minimal registry: workspace → project → environment → release.

**Goal:** Define and implement the control-plane data model that hosted deploy calls write into. This is the backbone that CLOUD-002 (deploy API) and CLOUD-003 (release history) build on.

**Remediation:**

1. Define the hosted data model: `Account`, `Project` (1:1 with a Sun workspace), `Environment` (production/staging/preview), `Release` (immutable record per deploy).
2. Implement an in-memory project registry sufficient for local end-to-end testing (no persistent store required in this ticket).
3. Define the HTTP API surface: `POST /projects`, `GET /projects/{id}`, `POST /projects/{id}/releases`.
4. Wire `sun cloud deploy` to call the registry stub instead of printing a placeholder response.
5. Add unit tests for the registry CRUD operations.

**Out of scope:**

- Persistent storage (database) for the registry — use an in-memory map.
- Auth/multi-tenancy — single implicit account is fine.
- URL assignment — that is FEAT-017.

**Acceptance criteria:**

- `sun cloud deploy` records a release in the in-memory registry.
- `GET /projects/{id}` returns project metadata and a list of release IDs.
- Unit tests cover create-project, create-release, and list-releases.
