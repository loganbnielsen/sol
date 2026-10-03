---
id: INFRA-100
type: infra
severity: medium
title: Publish the migration runner in the qualification harness and pass its digest
source: SEC-011 (the deployer and the migrate path must not build or publish the runner)
---

**Depends on:** SEC-011.

## Problem

SEC-011 removed the last path where Sol built and pushed the migration-runner
image: `sol deploy <target>`'s migration prerequisite and `sol migrate apply
<target>` now consume a pre-built, **digest-pinned** runner — from the release
bundle when Sol runs as an installed release, or from `SOL_MIGRATION_RUNNER_IMAGE`
when it runs from a source checkout — and fail closed when neither source names
one. Sol's own execution never resolves the publisher identity (ADR 0002), so it
must not publish the runner itself.

`internal/qualification/aws/live-row.sh` runs the **checkout** binary and relies
on Sol publishing the runner on the way:

```
run migrate-apply bash -c "cd '$WORKSPACE' && exec '$SOL' migrate apply '$TARGET' --registry '$ECR_REGISTRY'"
run app-deploy    bash -c "cd '$WORKSPACE' && exec '$SOL' deploy '$TARGET' --registry '$ECR_REGISTRY' --image-tag '$APP_TAG'"
```

Both steps break after SEC-011: `sol migrate`'s `--registry` flag is gone (it
existed only to name the repository the built runner was pushed to), and in
checkout mode Sol now refuses because no runner is named. The AWS qualification
run cannot reach its deploy step until the harness supplies one.

## Remediation (harness-side, deliberately outside Sol's execution)

The harness already acts as the publisher for the application images: it builds
them and pushes them with its own registry credentials before calling `sol
deploy` (ADR 0002's publisher identity, entirely outside Sol). Give the migration
runner the same treatment, in the harness:

1. Build the runner from the release recipe
   (`internal/tooling/release/migration-runner.Dockerfile`, with the same
   `SOL_RELEASE_VERSION` the release workflow uses) and push it to the target's
   ECR repository with the harness's own credentials — the `app-push` step is the
   model.
2. Export the pushed digest reference (`<image>@sha256:<64 hex>`) as
   `SOL_MIGRATION_RUNNER_IMAGE` for every `sol migrate apply` and `sol deploy`
   step.
3. Drop `--registry` from the harness's `sol migrate apply` invocation.

Nothing here changes Sol: the digest is artifact identity, and passing it grants
no publisher authority. The harness is where the publisher identity already
lives.

## Acceptance criteria

- The AWS run procedure builds and pushes the migration runner as the publisher
  before any `sol migrate apply`/`sol deploy` step, and exports its digest
  reference as `SOL_MIGRATION_RUNNER_IMAGE` for those steps.
- No harness step relies on Sol building or pushing any image.
- The harness's `sol migrate apply` invocation carries no `--registry`.
- The run procedure and the AWS matrix state the runner-publishing step, so a
  later operator reproduces it rather than rediscovering the refusal.

**Demo/example coverage:** Not applicable — this is qualification-run procedure,
not an app-author surface. The runnable proof is the AWS run itself
(`HARDEN-007`), which is live-blocked on explicit authorization.

**TypeScript-parity note (DEC-022):** No language-parity impact — the migration
runner is Sol's own OCaml tooling and the harness is language-neutral.

## Why this is S5's work, not S3's

The refusal belongs to `sol deploy`/`sol migrate` (SEC-011). Publishing the
runner and naming its digest is a property of the qualification run, whose
harness, run procedure and matrix belong to the live-qualification stream
(`internal/qualification/`). Filing it here keeps the boundary explicit instead
of letting SEC-011 edit another stream's run procedure.

## Evidence

- `internal/qualification/aws/live-row.sh`: the `migrate-apply` and `app-deploy`
  steps quoted above; `SOL="\$ROOT/_build/default/cli/bin/main.exe"` and no
  `SOL_HOME` override in the same script.
- `internal/ci/check_publisher_deployer_boundary.sh` (after SEC-011): the deploy
  and migrate paths may not call `Sol_cli_docker.build`/`push`.
- `internal/tooling/scripts/build-release-bundle.sh` refuses a
  `--runner-image` that is not a digest reference, and
  `.github/workflows/release.yml` publishes the runner and records that digest —
  the release half of "publish and version it as part of the Sol release
  process" already exists.
