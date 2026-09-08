---
id: FRIC-013
type: dogfood-finding
severity: medium
source: project/dogfood/RUN_2026-09-07_AWS.md (DOGFOOD-011, first real AWS dogfood run)
branch: FRIC-013/secret-path-filter
worktree: ../sun-FRIC-013-secret-path-filter
pr: https://github.com/loganbnielsen/sol/pull/144
---

**Depends on:** None.

`sol secret set`/`list`/`delete` iterate over every filesystem-discovered service in the workspace with no path/target filter, unlike `sol up` and `sol deploy` which both accept an optional service-path positional.

**Description:** During DOGFOOD-011, `sol secret set --env=customer_cloud --value=... POSTGRES_URL` failed with `Error from server (NotFound): ... namespaces "pluto-demo-ts" not found` — the command tried to write the secret into every namespace for every service `sol_cli_manifest.discover_services` finds on disk (`app/<domain>/<name>_{svc,worker,fn}/` with a Dockerfile), including a service (`examples/pluto/app/demo_ts/`, the FEAT-033 TypeScript spike) that was never deployed and has no corresponding namespace. `sol up`/`sol deploy` both take an optional `PATH` argument to scope to one service; `sol secret` has no equivalent.

**Impact:** Anyone whose workspace has a service they haven't deployed yet (a very normal state — mid-development, a spike, a not-yet-launched feature) cannot set *any* secret for *any other* service without first working around the undeployed one. The only workaround found was physically moving the undeployed service's directory out of the workspace tree for the duration of the command — not something a real user would discover on their own, and destructive-feeling for what should be a routine operation.

**Remediation:** Add the same optional `PATH` positional `sol up`/`sol deploy` already support to `sol secret set`/`list`/`delete`, using the identical `discover_services ~filter_path` mechanism those commands already call. Scope to just the requested service(s) rather than every discovered service, matching the existing filter semantics (exact directory match or basename match).

## Review — automated checks passed
discover_namespaces correctly reuses discover_services (same mechanism sol up/sol deploy use) with domain dedup; Cmdliner PATH positional wiring for set/delete/list mirrors existing conventions and renders correctly; build clean, diff scoped, docs updated. Noted (non-blocking): sol secret now hard-exits if app/ is missing, matching sol up/sol deploy's existing behavior instead of silently no-op'ing.
