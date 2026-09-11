---
id: AUDIT-052
type: audit-finding
severity: medium
source: codebase review 2026-06-14
branch: AUDIT-052/structured-k8s-manifest-renderer
worktree: /home/lbendtly/Code/sun-AUDIT-052-structured-k8s-manifest-renderer
branch: AUDIT-052/structured-k8s-manifest-renderer
worktree: /home/lbendtly/Code/sun-AUDIT-052-structured-k8s-manifest-renderer
---

Replace handwritten Kubernetes YAML templates with a structured manifest renderer

**Depends on:** None.

**Description:** `cli/sun/lib/sun_cli_manifest.ml` renders Kubernetes resources with large `Printf.sprintf` YAML strings for Namespaces, ConfigMaps, Secrets, ExternalSecrets, Deployments, Rollouts, Services, Ingresses, NetworkPolicies, and CronJobs. The same module then writes temp YAML and shells out to `kubectl apply`.

**Impact:** Manifest changes are hard to review and easy to break with indentation, escaping, or missing field updates across Deployment/Rollout/CronJob variants. Similar pod-template patterns are repeated instead of sharing a typed representation. Values such as labels, env values, hosts, and secret keys depend on handwritten quoting rather than a YAML/JSON emitter.

**Remediation:**

1. Introduce a structured manifest model and renderer. Prefer a maintained YAML/JSON library if available in the project dependency set; otherwise build typed Yojson values and emit JSON, which Kubernetes accepts.
2. Factor shared pod template pieces across Deployment, Rollout, and CronJob rendering.
3. Keep current public CLI output and `--emit-to` behavior stable.
4. Add golden tests for representative manifests and server-side dry-run coverage where the existing test runner has cluster access.

**Acceptance criteria:**

- New manifest rendering paths build structured values rather than concatenating raw YAML blocks for core workload resources.
- Deployment, Rollout, and CronJob share common pod/container rendering logic.
- Existing manifest render tests pass, with added coverage for escaping labels/env values containing YAML-sensitive characters.
- `sun up --dry-run`, `sun deploy --dry-run`, and `sun deploy --emit-to` produce Kubernetes-accepted manifests.

## Review — automated checks passed
Structured YAML renderer implemented correctly — all workload types use shared pod_template/container_fields, value type with all required variants is present, Quoted used for data values, Map [] renders as {}, public API surface preserved, no Printf.sprintf YAML resource bodies remain, build and all 27 tests pass.
