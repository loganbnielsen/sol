---
id: FEAT-004
type: feature
severity: high
source: PRODUCT_ARCHITECTURE.md
branch: FEAT-004/manifest-render-from-plan
worktree: /home/lbendtly/Code/sun-FEAT-004-manifest-render-from-plan
---

Refactor manifest rendering to consume `Deployment_plan.service_spec`.

**Depends on:** FEAT-003.

**Problem:** `Sun_cli_manifest.render` currently accepts a discovered service plus separately computed namespace, k8s name, image, and TOML data. That lets each command decide core deployment identity on its own. As deployment modes grow, the renderer should consume a resolved plan instead of raw workspace discovery.

**Goal:** Make Kubernetes YAML rendering an executor over a deployment plan service spec.

**Remediation:**

1. Change manifest rendering so the primary render function accepts a resolved `Deployment_plan.service_spec`.
2. Move namespace, k8s name, image, primitive, config, secrets, and schedule reads out of command modules and into the plan construction path.
3. Keep compatibility helpers if needed while migrating callers.
4. Update `cmd_up.ml` and `cmd_deploy.ml` to build a plan first, then render services from the plan.
5. Keep `apply` and `emit_to_dir` behavior unchanged.
6. Add regression tests or golden checks showing dry-run YAML stays stable for `Svc`, `Worker`, and `Fn`.

**Out of scope:**

- Changing manifest shape.
- Adding environment files.
- Adding new deploy targets.
- Changing local build/push behavior.

**Acceptance criteria:**

- `sun up --dry-run` emits the same resource names and images as before.
- `sun deploy --dry-run` emits the same resource names and images as before.
- `sun deploy --emit-to` still writes one `<namespace>-<name>.yaml` file per service.
- Command modules no longer compute Kubernetes namespace/name/image independently except for build-only image push details in `sun up`.

**Decisions:**

- `sun up --dry-run` continues to show the host-push image (`localhost:5000`). That is what actually gets pushed during `sun up`, so dry-run output should match the real action.

## Review — automated checks passed
Manifest rendering correctly refactored to consume service_spec from the deployment plan; cmd_up and cmd_deploy build a plan before rendering; namespace/k8s_name/image computation is consolidated in of_services; regression tests covering Svc, Worker, Fn, and parity with legacy render all pass; build is clean.
