---
id: TYPE_AUDIT-079
type: refactor
severity: low
title: "Retain resolved workload identities until the local execution adapter serializes them"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Retain resolved workload identities until the local execution adapter serializes them

**Depends on:** None.

**Principles:** 1, 3, 4, 13, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/lib/deploy/sol_cli_up_execution.ml:1` defines service_execution k8s_name and namespace as strings.
- `:49`: service_execution erases validated spec identities before build/push.
- `:93`: wait_for_service_rollout accepts both the typed service_spec and independently string-valued execution record.
- Real serialization edges are kubectl argv construction and user-facing formatting, not the execution record.

## Mechanism and impact

The execution record is an internal operation value, not a serialized report. Early conversion allows identities to be swapped or disagree with the typed spec while the compiler cannot help. This is specifically abstract Kubernetes_name erasure; rendering DTOs elsewhere need not be changed.

## Remediation

Retain resolved namespace/name types in service_execution, or eliminate redundant identities and derive them from the validated spec at the adapter edge. Convert only for argv/output formatting. Update all callers together without compatibility aliases.

## Acceptance criteria

- Internal execution identities retain the abstract validated types or have one authoritative source.
- Rollout cannot accept conflicting independently supplied identity strings.
- Serialization happens at named argv/output boundaries.
- Existing build/push/rollout callers and tests retain behavior; no new wrapper abstraction is added.

- Demo/example: not applicable: internal execution typing; record why.
- Language parity: no language-parity impact: shared CLI adapter.

## Existing work and scope

TYPE_AUDIT-078 covered deploy-event IDs, not these execution identities. Release-inspection rendering DTOs are deliberately outside this ticket.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.

## Completion notes (2026-10-04)

**Premise re-verified** against `origin/main @ 0696069d`: `sol_cli_up_execution.ml:1-8` still
declared `k8s_name`/`namespace` as `string`, and `:49-50` converted the validated spec identities
with `k8s_name_to_string`/`namespace_to_string` before build/push; `wait_for_service_rollout`
accepted both the typed `service_spec` and the independently string-valued execution record. The
premise held.

**Implemented — the first remediation option: retain the resolved identities as the abstract
validated types, serialize only at the adapter edges.**

- `Sol_cli_up_execution.service_execution.k8s_name`/`namespace` now carry
  `Sol_cli_deployment_plan.k8s_name`/`namespace` instead of `string`; the constructor copies the
  validated spec fields without converting. The record is now a pure operation value that cannot
  disagree with the spec it was built from while the compiler cannot see it.
- `wait_for_service_rollout` serializes once into named `k8s_name`/`namespace` locals at its kubectl
  argv/formatting boundary (`rollout_status`, `diagnose_service_live`, and the two error formats);
  it no longer threads stringly identity past the validated type.
- `cmd_up.ml`'s `expose_service` serializes once into named locals before building the port-forward
  name, argv (`replace_conflicting`, `start`) and the user-facing `namespace` output.
- `test_up_execution_descriptor_uses_host_push_image` asserts the same "charge-svc"/"myapp-payments"
  output, now converted at the assertion boundary, so the existing behavior coverage is retained.

No new wrapper abstraction; the redundant identity fields were kept but typed, so no caller needed a
compatibility alias. Internal execution typing only — no behavior change.

**Checks run (worktree `sol-TYPE_AUDIT-079`):**

```
dune build cli/                                       # clean
dune test cli/                                        # 53/55 pass; the 2 failures are the
                                                      # pre-existing Test_scaffold compile tests
internal/ci/check_ocamlformat.sh --staged             # clean after `dune fmt`
```

The two `Test_scaffold` failures ("scaffold actually compiles", "bare fn library compiles") are
environmental and unrelated to this diff: the scaffolded temp workspace runs `dune build` and fails
`Error: Library "sol-fn" not found` / `"sol-obs" not found` / `"kafka-eio-service" not found`,
because those framework packages are not installed in this switch (`opam list` shows only
`sol-env`/`sol-runtime`). No module touched here is compiled by that scaffold build.

**Demo/example:** not applicable — internal execution typing; no app-author-visible surface changed.
**Language parity:** no impact — shared CLI adapter, no framework contract changed.

