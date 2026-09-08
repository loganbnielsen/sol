# DOGFOOD-004: Operations Loop
**Date:** 2026-06-11  
**Tester:** Claude Sonnet 4.6 (automated dogfood pass)  
**Branch:** DOGFOOD-004/ops-loop

---

## Environment

- OS: Linux 6.6.87.2-microsoft-standard-WSL2 (Ubuntu)
- k3d `sun-local` cluster with both services deployed (from DOGFOOD-003)
- Workspace under test: `/tmp/dogfood-test/dogfood_acme`

---

## Steps Executed

| Step | Command | Result |
|------|---------|--------|
| 1 | `sun secret set --env dev API_KEY --value sk-test-abc123` | "secret set in 2 namespace(s)" ✓ |
| 2 | `sun secret list --env dev` | Shows `API_KEY` (key only, no value) ✓ |
| 3 | `sun secret delete --env dev API_KEY` | "secret deleted from 2 namespace(s)" ✓ |
| 4 | `sun migrate status` | Shows `1 notifications (pending)` ✓ |
| 5 | `sun migrate apply` | "Done." ✓ |
| 6 | `sun logs comms/notify_worker --no-follow` | Shows retry messages only (see F2) |
| 7 | Introduce compile-error bad deploy (`exit 1` in main.ml) | `dune build failed` before image — build gate ✓ |
| 8 | Introduce runtime bad deploy (`Sys.getenv` of missing var) | Pods not restarted (see F3) |
| 9 | `sun rollback comms/notify_worker` | "rolled back" ✓ |
| 10 | `sun rollback app/comms/notify_worker` | "No services found in app/" (see F1) |
| 11 | `sun rollback` (all services) | comms ✓, payments fails (see F4) |

---

## Findings

### F1 — MINOR: Path format inconsistency between `sun up` and `sun rollback`

`sun up` requires the `app/` prefix: `sun up app/payments/charge_svc`.  
`sun rollback` requires no prefix: `sun rollback payments/charge_svc`.

If a user follows the `sun up` path format for rollback, they get a confusing error: `No services found in app/ with a Dockerfile`. Nothing in the help text or error message explains the format difference.

**Suggested improvement:** Either normalize path format across all commands (remove the `app/` prefix requirement everywhere), or add an example to the help text and improve the error message.

### F2 — MINOR: `sun logs` shows only stdout/stderr; Loki logs not surfaced

Already recorded in DOGFOOD-003/F1. Same finding applies here.

### F3 — MODERATE: Bad deploy (runtime crash) not detectable when using fixed image tag

`sun up` with a fixed tag (`dev`) deploys new code by building a new image and pushing to the registry. However, pods are only restarted when the Kubernetes pod spec template changes. The pod spec template's `sun.dev/config-hash` annotation is computed from the ConfigMap only — not from secrets and not from the image content. When code changes but no ConfigMap entry changes, the annotation stays the same, no rolling update is triggered, and pods continue running the old binary.

Consequence: for iterative development with `sun up`, a developer's code change is NOT deployed unless the ConfigMap changes. The command reports success ("deployment successfully rolled out") but the running pod has old code. This creates a false confidence gap.

**Existing workaround:** Use `sun dev run` for local development iteration (no in-cluster required). For CI/CD, use unique image tags per build (`sun up --tag <git-sha>`).

**Suggested improvement:** Document explicitly in `sun up` output when no pod restart was triggered: "no pod restart required (config unchanged)". This reduces false confidence.

### F4 — MINOR: `sun rollback` exits 1 on partial failure

`sun rollback` (no argument) rolled back notify-worker successfully but failed on
charge-svc ("no rollout history found"). The overall exit code was 1, and the
success message for notify-worker was printed before the error for charge-svc.
The UX is correct (each service reported individually) but the partial-success
exit code may confuse scripts.

**Acceptable as documented.** The error message "no rollout history found" is clear.

---

## What Passed

- `sun secret set` stores secrets in k8s Secret resources in each service namespace.
- `sun secret list` returns keys only — no values printed. Satisfies "secrets materialized without printing values."
- `sun secret delete` removes the key from all namespaces.
- `sun migrate status` correctly reports pending vs applied migrations per migration file.
- `sun migrate apply` applies pending migrations idempotently; second run reports no-op.
- Compile-time errors are caught by the `sun up` build step before any image is built or deployed. Bad code cannot reach the cluster if it doesn't compile.
- `sun rollback comms/notify_worker` (correct path format) completed successfully and waited for rollout.
- Error messages from rollback failures are actionable ("no rollout history found").

---

## Acceptance Criteria Status

| Criterion | Status |
|-----------|--------|
| Secrets are materialized without printing values | **Pass** |
| Migrations apply once and report status clearly | **Pass** |
| Logs are discoverable from the CLI | **Partial** (F2 — Loki-only logs not surfaced) |
| Rollback behavior is functional or explicitly bounded | **Pass with caveat** (F1 path format, F4 partial failure) |
