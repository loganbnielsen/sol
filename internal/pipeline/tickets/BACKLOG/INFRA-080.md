---
id: INFRA-080
type: bug
severity: low
title: Three harness verdict refinements Attempt 8 exposed (a class that can never verify absence, a soft-deleted role read as present, and a comment that broke its own printf)
source: GCP Attempt 8 (2026-09-25) — observed in the live run and its bundle
---

**Depends on:** None.

**Related:** `internal/qualification/gcp/live-qual.sh`,
`internal/qualification/gcp/test-live-qual.sh`, `docs/qualification/2026-09-25-gcp-attempt8.md`.

## A. `impersonator-binding` can never verify absence after a successful teardown

The class probes with `gcloud iam service-accounts get-iam-policy <sa>`. For a deleted service
account GCP answers:

```
ERROR: (gcloud.iam.service-accounts.get-iam-policy) PERMISSION_DENIED: Permission
'iam.serviceAccounts.getIamPolicy' denied on resource (or it may not exist).
```

The probe correctly refuses to read that as ABSENT (fail-closed), so **every** successful
teardown ends "teardown NOT verified" for this class — a postcondition that cannot be satisfied
by construction is not a postcondition. The binding is an IAM *policy* on an identity; the
identity's own absence is already covered by `service-account-provisioner`, so either ask a
question that can be answered after deletion, or state that this class is verified by the
identity's absence.

## B. `custom-role` should read GCP's `deleted: true` as absent

GCP soft-deletes custom roles: after Sol's destroy the role is gone from `iam roles list` but
present with `deleted: true` for the undelete window. The probe read it as PRESENT (a true
observation of a state the row does not mean), so a *clean* teardown was reported as residue.
Observed for Attempts 5, 6 and 8 (`sol_sol_qual_gcp_{5,6,8}_cluster_access`, all `deleted: true`).
Non-billable, but the verdict must say what it means: `deleted: true` is the provider's
"deleted", distinct from both PRESENT and UNKNOWN.

## C. `cloud_vars`' comment ends its own `printf`

```sh
  printf '%s\n' \
    "--var=base_domain=$BASE_DOMAIN" \
    # No create_dns_zone here: …
    "--var=provisioner_impersonators=[\"$IMPERSONATOR\"]"
```

The comment consumes the continuation, so the next line is executed as a command:
`--var=provisioner_impersonators=[…]: command not found`, and the var is dropped. **It did not
affect Attempt 8** — the plan transcript shows Sol passing
`-var=provisioner_impersonators=["user:…"]` from the target itself (a `sol_keys` field), which is
why the harness's own copy is redundant. Fix by **deleting the redundant line** (the harness must
not become a second source for a Sol-owned key), and note the same trap is invisible to the
suite because `destroy_vars` carries no comment.

## Acceptance criteria

- The `impersonator-binding` class either asks a question that can answer after deletion or is
  documented as covered by the identity's absence; a clean teardown verifies clean.
- The `custom-role` verdict distinguishes PRESENT / soft-deleted / UNKNOWN, with a regression
  test for each.
- `cloud_vars` emits its complete argument list (a test asserts the cloud invocation carries the
  target-derived variables it relies on — the impersonator arrives from the target, so the
  harness asserts *behaviour*, not the presence of its own duplicate).
- No product code changes.
