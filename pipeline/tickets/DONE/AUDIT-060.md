---
id: AUDIT-060
type: audit-finding
severity: high
source: codebase review 2026-06-14
branch: AUDIT-060/workspace-scan-ignore-vendor
worktree: /home/lbendtly/Code/sun-AUDIT-060-workspace-scan-ignore-vendor
---

Prevent workspace infra scanning from following `vendor/` framework sources

**Depends on:** None.

**Description:** `cli/sun/lib/sun_cli_workspace.ml` recursively scans every non-dot directory under the workspace and marks infra requirements when any `dune` file contains library names such as `kafka_eio_service`, `sun_storage`, `obs_eio_loki`, or `obs_eio_prometheus`. Generated workspaces also create `vendor/framework` and `vendor/integrations` symlinks to Sun source. The scanner does not skip `vendor/`, `_build/`, or symlinked framework directories.

**Impact:** A workspace can be detected as requiring Kafka, Postgres, Loki, and Prometheus because the vendored Sun framework source contains those libraries, even when the user’s actual app does not. That makes `sun dev up` provision unnecessary infrastructure, slows onboarding, and hides the true dependency shape of the workspace.

**Remediation:**

1. Restrict infra scanning to application-owned paths such as `app/`, `lib/`, `events/`, and `test/`, or explicitly skip `vendor/`, `_build/`, `.git/`, and generated build contexts.
2. Avoid following symlinked directories unless they are part of the workspace app surface.
3. Add tests with a minimal workspace plus a `vendor/integrations` symlink or fixture containing Kafka/Postgres dune files.
4. Prefer parsing dune stanzas for workspace service dependencies when practical, rather than raw recursive substring scanning.

**Acceptance criteria:**

- A minimal workspace with only a public HTTP service and `vendor/` links does not require Kafka/Postgres/Loki/Prometheus.
- A workspace whose actual service dune files reference those libraries still detects the correct infra.
- `sun dev up` provisions only infra required by workspace code, not by vendored framework source.
- Tests cover skipped directories and symlinked vendor paths.

## Review — automated checks passed
Workspace scan correctly skips vendor/, _build/, symlinked dirs, and .git/; build and all 27 tests pass; project/tickets/ untouched; no shell injection in production code; (wrapped false) preserved.
