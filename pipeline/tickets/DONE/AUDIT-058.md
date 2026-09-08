---
id: AUDIT-058
type: audit-finding
severity: high
source: codebase review 2026-06-14
branch: AUDIT-058/hosted-per-service-digests
worktree: /home/lbendtly/Code/sun-AUDIT-058-hosted-per-service-digests
---

Record hosted image digests per service instead of overwriting one release digest

**Depends on:** None.

**Description:** `cli/sun/bin/cmd_cloud.ml` builds and pushes every discovered service, but stores only one release-level digest. During the loop, each successful service build assigns:

```ocaml
last_digest := result.digest
```

After all builds pass, `update_release_digest` records only `!last_digest`, which is the digest from the last service processed.

**Impact:** A multi-service hosted release loses image provenance for every service except the last one. Release JSON and logs cannot reliably answer which exact image digest was deployed for `charge-svc` versus `notify-worker`, weakening rollback, auditability, and debugging.

**Remediation:**

1. Extend the registry model to store image refs and digests per service within a release.
2. Update both memory and Postgres registry implementations.
3. Include per-service image/digest data in `release_to_json`, release listing/details, and logs where appropriate.
4. Keep an aggregate release digest only if it is explicitly defined as a deterministic hash of all service digests.

**Acceptance criteria:**

- A release with two services records two distinct service digest entries.
- JSON output exposes each service's image and digest.
- The Postgres schema and in-memory registry have equivalent behavior.
- Tests fail if the implementation stores only the last service digest.

## Review — automated checks passed
Per-service image and digest fields added to release_service; update_service_digest replaces update_release_digest across registry, control plane, Postgres DDL, and cloud_deploy; tests confirm distinct per-service digests and JSON exposure; all 42 tests pass.
