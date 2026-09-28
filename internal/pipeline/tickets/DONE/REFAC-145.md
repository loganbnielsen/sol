---
id: REFAC-145
type: refactor
severity: medium
title: Give Deployment and Rollout rendering one typed workload input
source: Logan readability review generalized by style audit (2026-09-27)
---

Give Deployment and Rollout rendering one typed workload input

**Depends on:** None.

**Premise verified (2026-09-27):** read both public signatures, their builders, and
their sole production caller on `origin/main` at `954afad7`; the duplicated 20/21-field
calls remain.

**Problem:** `deployment_doc` and `rollout_doc` in
`cli/lib/workspace/sol_cli_manifest.mli` expose 20 and 21 labelled parameters. Both
forward the same pod/workload fields into `pod_template` in
`sol_cli_manifest_yaml.ml`; the shared production caller in
`sol_cli_deployment_render.ml` reconstructs those two long calls separately. Labels
make each argument legible but do not express the real domain value, and the compiler
cannot ensure the Deployment and Rollout paths receive the same pod shape.

## Remediation

Define one meaningful typed workload/pod render specification at the manifest boundary.
Have the Deployment and Rollout builders accept it plus only their wrapper-specific
strategy, construct it once in `deployment_resources`, and migrate direct renderer
tests. Do not introduce a generic dependencies record or change the rendered schema.

## Acceptance criteria

- Shared pod fields cannot differ between the Deployment and Rollout call sites because
  both builders consume the same typed value.
- Neither public builder has more than three independent arguments beyond the shared
  record and its wrapper-specific strategy.
- Existing YAML parity tests cover Deployment, Canary, and Blue-green output and remain
  unchanged at the parsed-value level.
- Demo/example: not applicable; this is an internal renderer refactor with identical
  manifests.
- Language parity: no impact; rendering is shared by every application language.

## Completion notes

- `Sol_cli_manifest.Workload_spec.t` is the one typed value shared by Deployment and
  Rollout rendering; `deployment_resources` constructs it once.
- `deployment_doc` now takes the workload plus its optional rolling strategy;
  `rollout_doc` takes the workload plus progressive-delivery strategy. `pod_template`
  consumes the same record directly.
- All 156 manifest-render tests pass, including Deployment, Canary, Blue-green, worker,
  security, and parsed YAML invariants.
- Demo/example: not applicable; rendered manifests are unchanged.
- Language parity: no impact; rendering is shared by every application language.
