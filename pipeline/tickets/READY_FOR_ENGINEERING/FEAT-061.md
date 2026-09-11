---
id: FEAT-061
type: feature
severity: medium
source: FEAT-059 review, 2026-09-11 — destination and scope are separate axes, and only one is modelled
---

**Depends on:** None.

Deployment scope is a first-class concept, separate from the destination.

**Related:** FEAT-059 (destination), DEC-018 (rollback), FEAT-050 (digest-pinned artifacts), DEC-016.

## Problem

Two independent decisions are currently collapsed into one string.

**Where** a deploy goes is being fixed by FEAT-059 (the target resolves to a cluster context). **What** it touches is decided by `filter_path` — a path string threaded through `discover_services ~filter_path` into the plan and the apply (`cmd_up.ml`, `Sol_cli_factory.run`). So:

- **Scope has no name.** There is no type saying "this release is `charge-svc`" versus "this release is the workspace"; there is a filter that happens to select services by path. `deployment_scope` appears nowhere in the codebase.
- **Scope is a path, not an identity.** `sol deploy charge-svc --env prod` cannot mean what a human expects it to mean; selection is by source path, so the unit of deployment is a filesystem layout rather than a named thing.
- **Nothing states what a release *is*.** That matters beyond convenience:
  - **Rollback** (DEC-018) has to restore "a release". Rolling back a service and rolling back a workspace are different operations with different blast radius, and today there is no vocabulary to distinguish them.
  - **Digest-pinned artifacts** (FEAT-050) pin an image per service, but a release is a set of manifests plus configuration. If a release has no defined scope, its identity is ambiguous — which is exactly the ambiguity rollback cannot tolerate.
  - **The platform** (DEC-019) needs to answer "what was deployed, and to where" for a push-triggered deploy; a path filter is not a durable answer.

## Proposed shape

Keep the axes distinct, in the types:

```ocaml
type destination =
  { context : string
  ; kubeconfig : string option
  }

type deployment_scope =
  | Service of service
  | Worker of worker
  | Function of fn
  | Workspace
```

The command then chooses both independently — `deploy (scope = Service charge, destination = prod)` — which is what makes this true:

> Deploy exactly `charge-svc` to exactly the cluster the `prod` target represents.

and, importantly, the reverse: changing destinations must not change what gets deployed, and selecting a service must not change which cluster it lands on.

**Boundary:** destination resolution belongs at the Kubernetes seam (`sol_cli_kubectl`); scope resolution belongs above it, in discovery and the plan. Neither should learn about the other — a kubectl helper that knows which service is being deployed has already conflated them.

## Acceptance criteria

- Scope is a modelled value, naming the unit being deployed (service, worker, function, workspace), not a path string.
- Selecting a scope does not affect the resolved destination, and resolving a destination does not affect the scope: a test for each direction.
- The chosen scope is recorded with the deployment and is visible in the emitted plan, so "what was deployed" has an answer that survives the command.
- Requesting a scope that does not exist fails closed, naming what was asked for and what is available.
- Workspace scope remains available and remains the default where it is today.

## Notes

Not a prerequisite for FEAT-059 — destinations can be made explicit while scope stays a filter. But it is a prerequisite for a coherent answer to DEC-018, and the vocabulary is easier to introduce before the platform depends on the current one.
