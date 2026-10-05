---
id: CODEX_STYLE_AUDIT-092
type: bug
severity: medium
title: "Propagate failed workspace discovery instead of producing incomplete snapshots"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Propagate failed workspace discovery instead of producing incomplete snapshots

**Depends on:** None.

**Principles:** 6, 15, 18, 21–24, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/lib/workspace/sol_cli_workspace_scan.ml:3`: fold_dir warns on non-absence errors and returns init.
- `:95` and `:124`: contract/topic discovery use it inside Result APIs; schema discovery has the same observation loss.
- `cli/lib/workspace/sol_cli_workspace_model.ml:88`: incorporates these results into a successful workspace snapshot.
- `cli/lib/workspace/sol_cli_manifest.ml:54`: app discovery performs directory/stat calls whose operational exceptions are not consistently translated.
- `cli/lib/base/sol_cli_fs_walk.ml:10`: filesystem absence/stat classification is incomplete. Migration discovery already uses a Result fold.

## Mechanism and impact

A failed declaration-directory observation can erase contracts/topics from a valid-looking plan. Other directory failures can escape as Sys_error despite the public Result API. A warning does not make an incomplete mutation input safe.

## Remediation

Use one filesystem observation policy distinguishing documented optional absence from failed inspection. Propagate errors through required workspace discovery, including directory-entry classification and races. Keep forgiving warnings only for explicitly optional diagnostic discovery.

## Acceptance criteria

- Non-directory events path, unreadable subdirectory, dangling app entry, and disappearance during observation yield contextual Error.
- Legitimately absent optional directories remain empty.
- Failed workspace load cannot reach render/deploy/apply.
- Use deterministic fake filesystem observations or unprivileged fixtures so permission tests remain meaningful when the test runner is privileged.

- Demo/example: exercise generated workspace discovery; document failure/recovery if operator-visible behavior changes.
- Language parity: apply the same snapshot failure semantics to both language declarations.

## Existing work and scope

REFAC-140 owns decomposition, not successful incomplete snapshots. No matching open owner was found. Preserve migration discovery's correct absence/error distinction.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
