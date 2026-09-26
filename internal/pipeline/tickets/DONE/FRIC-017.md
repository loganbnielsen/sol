---
id: FRIC-017
type: dogfood-finding
severity: blocker
source: pipeline/dogfood/RUN_2026-09-13.md
---

**Depends on:** None.

Docker 29.x cannot drive k3d v5.6.0 — k3d's embedded Docker client is API 1.43, Docker 29 removed everything below 1.44

**Description:** `sol local infra up` fails in 0.05s on a current Ubuntu 22.04 host:

```
ERRO Failed Cluster Preparation: failed to create cluster network: docker failed to list networks:
  Error response from daemon: client version 1.43 is too old. Minimum supported API version is 1.44
```

Docker Engine 29.0 removed support for API versions below 1.44; k3d v5.6.0's vendored Docker client caps at 1.43 and does not negotiate up. `internal/pipeline/dogfood/DOGFOOD.md`'s version table lists "Docker 29.x" and "k3d v5.6.0" as a tested pair, and k3d v5.6.0 is additionally pinned in `.github/workflows/ci.yml:171`.

**Impact:** Blocks substrate provisioning entirely on any host with Docker ≥ 29 — which is what current `jammy-updates` ships (`docker.io 29.1.3`). The failure is immediate and the message is accurate but doesn't suggest a fix.

**Remediation:** Pick one and make it the documented/tested path: (a) bump the pinned k3d to a release whose Docker client speaks ≥ 1.44 (and update `DOGFOOD.md` + `ci.yml` together); (b) pin/document Docker < 29 for local dogfood; or (c) set `DOCKER_API_VERSION=1.44` automatically whenever `sol local infra up` shells out to k3d, with a comment explaining the constraint. Whatever is chosen, update the version table so it doesn't claim a combination that fails.

Related: FRIC-009 (k3d/helm/docker versions are hand-synced between DOGFOOD.md and ci.yml).

## Completion notes

- Fixed in `cli/sol/bin/cmd_local.ml`: a `k3d` wrapper sets `DOCKER_API_VERSION` to the daemon's `MinAPIVersion` whenever that exceeds k3d 5.6.0's 1.43 client floor, applied to all five k3d call sites.
- Verified live with `DOCKER_API_VERSION` unset: raw `k3d cluster get sol-local` still fails with "client version 1.43 is too old", while `sol local status` succeeds and reports both domains healthy.
- No app-author-facing surface changed (internal substrate plumbing), so no example/demo update applies.
