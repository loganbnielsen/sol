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

Both qualification harnesses run the **checkout** binary and rely on Sol
publishing the runner on the way:

```
$ rg -n 'migrate apply.*--registry' internal/qualification/
internal/qualification/aws/live-row.sh:235:  run migrate-apply bash -c "cd '$WORKSPACE' && exec '$SOL' migrate apply '$TARGET' --registry '$ECR_REGISTRY'"
internal/qualification/gcp/live-qual.sh:1351:  if ! run migrate-apply "$SOL" migrate apply "$TARGET" --registry "$(app_registry)"; then
internal/qualification/gcp/test-live-qual.sh:491:  "migrate apply qual/gcp/us-central1 --registry us-central1-docker.pkg.dev/sol-qualification/test-cluster" \
```

plus `sol deploy` in the same scripts (`live-row.sh:245`, and the GCP
equivalent). Those steps break after SEC-011: `sol migrate`'s `--registry` flag is
gone (it existed only to name the repository the built runner was pushed to), and
in checkout mode Sol now refuses because no runner is named. Neither run can
reach its deploy step until the harness supplies one.

## Remediation (harness-side, deliberately outside Sol's execution)

The harnesses already act as the publisher for the application images: they build
them and push them with their own registry credentials before calling `sol
deploy` (ADR 0002's publisher identity, entirely outside Sol). Give the migration
runner the same treatment, in each harness:

1. Build the runner from the release recipe
   (`internal/tooling/release/migration-runner.Dockerfile`, with the same
   `SOL_RELEASE_VERSION` the release workflow uses) and push it to the target's
   registry with the harness's own credentials — the `app-push` step is the
   model, and the runner may be built once and reused for the run.
2. Export the pushed digest reference (`<image>@sha256:<64 hex>`) as
   `SOL_MIGRATION_RUNNER_IMAGE` for every `sol migrate apply` and `sol deploy`
   step.
3. Drop `--registry` from each harness's `sol migrate apply` invocation, and
   update the GCP harness self-test (`internal/qualification/gcp/test-live-qual.sh`)
   that asserts the old invocation shape.

Nothing here changes Sol: the digest is artifact identity, and passing it grants
no publisher authority. The harness is where the publisher identity already
lives.

## Acceptance criteria

- Each qualification harness builds and pushes the migration runner as the
  publisher before any `sol migrate apply`/`sol deploy` step, and exports its
  digest reference as `SOL_MIGRATION_RUNNER_IMAGE` for those steps.
- No harness step relies on Sol building or pushing any image.
- Neither harness's `sol migrate apply` invocation carries `--registry`, and the
  GCP harness self-test asserts the new shape.
- The run procedures and the AWS/GCP matrices state the runner-publishing step,
  so a later operator reproduces it rather than rediscovering the refusal.

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
- `internal/qualification/gcp/live-qual.sh` and its self-test
  `internal/qualification/gcp/test-live-qual.sh`: the same `migrate apply
  <target> --registry <registry>` invocation, found by the `rg` above.
- `internal/ci/check_publisher_deployer_boundary.sh` (after SEC-011): the deploy
  and migrate paths may not call `Sol_cli_docker.build`/`push`.
- `internal/tooling/scripts/build-release-bundle.sh` refuses a
  `--runner-image` that is not a digest reference, and
  `.github/workflows/release.yml` publishes the runner and records that digest —
  the release half of "publish and version it as part of the Sol release
  process" already exists.

## Completion notes (2026-10-03)

**Premise verified.** Both harnesses still ran Sol from a checkout, still passed
`sol migrate apply <target> --registry <registry>` (a flag SEC-011 removed), and
relied on Sol publishing the runner on the way — so neither run could reach its
deploy step. `rg -n 'migrate apply.*--registry' internal/qualification/` named
all three sites before this change and names none now.

**One implementation of the publisher boundary, in
`internal/qualification/publish-migration-runner.sh`.** Both harnesses call it,
so the publisher's discipline exists once rather than twice:

- it builds Sol's own `internal/tooling/release/migration-runner.Dockerfile`
  with `SOL_RELEASE_VERSION` (or takes `--binary`), **in a build directory of its
  own** — building into the caller's `_build` would have re-stamped the checkout's
  dev-stamped `sol` binary, which then no longer resolves a checkout's assets and
  would have broken the very steps the harness runs afterwards;
- it pushes with the harness's credentials and prints **only** the pushed
  `<image>@sha256:<64 hex>`, refusing anything else, so a moving tag cannot reach
  Sol;
- it refuses an empty `--version`, because the runner image must identify the Sol
  revision it was built from.

**Both harnesses publish, then hand Sol the digest.** `live-row.sh` (AWS) and
`live-qual.sh` (GCP) publish after the workload images, export
`SOL_MIGRATION_RUNNER_IMAGE`, and no longer pass `--registry` to `sol migrate
apply`; `sol deploy` still gets the target's registry for the workspace's own
images. AWS additionally creates `pluto/sol-migration-runner`, because the
platform provisions one ECR repository per service and this artifact is Sol's
own; GCP pushes into the Artifact Registry repository the row already uses. Each
harness re-checks the returned reference for the digest shape before exporting
it, so a publisher bug cannot be papered over.

**Offline and adversarial verification — three suites, all stubbed, no cloud and
no spend:**

- `internal/qualification/test-publish-migration-runner.sh` — 31 assertions: the
  push and the printed digest; a self-built binary; and the refusals for a
  tag-only digest, a truncated digest, a failed push, a failed build, a named
  binary that is absent, an empty version, a missing image, and a checkout
  without the release recipe. Each refusal must print nothing on stdout.
- `internal/qualification/aws/test-live-row.sh` — 22 assertions: the runner is
  built from the release recipe and pushed before Sol's first step, the
  repository is created only when absent, `sol migrate apply` carries no
  `--registry` and does carry the digest, `sol deploy` still carries the
  registry and the same digest, and — adversarially — a runner that resolved to
  no digest, or a repository the publisher cannot create, fails the phase with
  **no `sol` invocation at all**.
- `internal/qualification/gcp/test-live-qual.sh` (extended) — 247 assertions:
  the same shape for the GCP row, plus the adversarial case where Sol is never
  invoked when the publisher could not deliver a digest.

All three are wired into CI's `test` job beside the existing harness self-test,
and the repo-wide comment guard passes over the new scripts.

**Idempotence:** an existing runner repository is left alone; a re-run publishes
the same tag with a new digest and hands Sol that digest, which is what the
record should show (`RUNNER_VERSION` defaults to `sol-<git sha>` and is
overridable, so the artifact and the revision it came from stay aligned).

**Docs updated where the operator will read them:** the AWS run procedure's
publisher step, the AWS matrix's docker prerequisite (its claim that "Sol's
migration check shells out to `docker build`" was stale after SEC-011 — the
publisher does, Sol does not), a new section in the GCP matrix, and both
harnesses' own help text.

**Deliberately not done:** no cloud qualification run was started, and this
ticket claims no live evidence. It restores the harnesses' ability to reach their
deploy steps; the runs themselves stay gated on explicit authorization
(`HARDEN-007`).

**Demo/example coverage:** not applicable — this is qualification-run procedure
and harness code, not an app-author surface. The runnable proof is the two
harness suites, which a reader can execute without credentials.

**TypeScript parity (DEC-022):** no impact — Sol's own tooling and the harnesses;
no framework primitive, wire format or runtime contract changed.
