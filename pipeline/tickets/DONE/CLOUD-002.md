---
id: CLOUD-002
type: feature
severity: high
source: product-planning-2026-06-10
branch: CLOUD-002/deploy-api-contract
worktree: ../sun-CLOUD-002-deploy-api-contract
---

Define and implement the hosted deploy API contract.

**Depends on:** CLOUD-001.

**Problem:** `sun cloud deploy` has a CLI path but no defined API contract for what the hosted control plane accepts and returns. Without a stable contract, the CLI output is a stub and the user cannot inspect or script deploys.

**Goal:** Ship a versioned HTTP API that the `sun cloud deploy` CLI calls, with a response shape that includes release ID, status, timestamp, and (once FEAT-017 is complete) a default URL.

**Remediation:**

1. Define the `POST /projects/{id}/releases` request body: image tag, environment, workspace name, service list.
2. Define the response body: `release_id`, `status` (queued | building | live | failed), `created_at`, `services` list with per-service status.
3. Implement the endpoint in the control-plane stub (backed by the CLOUD-001 registry).
4. Update `sun cloud deploy` to print the structured release response to stdout (JSON with `--output json`, human-readable default).
5. Add contract tests: a well-formed deploy request returns a release record with all required fields.

**Out of scope:**

- Async build/deploy pipeline — `status: live` can be returned immediately for the stub.
- Default URL in the response — that arrives with FEAT-017.

**Acceptance criteria:**

- `sun cloud deploy` prints a human-readable release summary including release ID, status, and per-service rows.
- `sun cloud deploy --output json` prints a valid JSON release record.
- Contract tests cover the request/response shape.
