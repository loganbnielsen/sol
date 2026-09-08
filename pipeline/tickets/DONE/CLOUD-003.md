---
id: CLOUD-003
type: feature
severity: medium
source: product-planning-2026-06-10
branch: CLOUD-003/release-history
worktree: ../sun-CLOUD-003-release-history
---

Add release history and log model for hosted deploys.

**Depends on:** CLOUD-002.

**Problem:** After a hosted deploy succeeds, the user has no way to list past releases, inspect their status, or retrieve deploy logs. Debugging a failed deploy requires re-running it.

**Goal:** Give the user a `sun cloud releases` command that lists recent releases for a project, and a `sun cloud logs --release <id>` command that returns the deploy log for a specific release.

**Remediation:**

1. Add `GET /projects/{id}/releases` endpoint — returns a paginated list of release records (id, status, created_at, image_tag, environment).
2. Add `GET /projects/{id}/releases/{release_id}/logs` endpoint — returns deploy log lines as newline-delimited text.
3. Implement `sun cloud releases` CLI command: calls the releases list endpoint and prints a table.
4. Implement `sun cloud logs --release <id>` CLI command: streams log lines to stdout.
5. Populate stub log lines from the CLOUD-002 deploy flow so the command returns non-empty output.
6. Add tests for list-releases pagination and log retrieval.

**Out of scope:**

- Persistent log storage — in-memory log buffer per release is sufficient.
- Real-time log streaming (SSE/WebSocket) — polling or single-shot GET is fine.
- Log retention policies.

**Acceptance criteria:**

- `sun cloud releases` prints a table of recent deploys with id, status, image tag, and timestamp.
- `sun cloud logs --release <id>` returns the deploy log for a known release ID.
- An unknown release ID returns a clear error message.
- Tests cover list pagination and log fetch for known/unknown IDs.
