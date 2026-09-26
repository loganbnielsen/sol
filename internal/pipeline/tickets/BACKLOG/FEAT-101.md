---
id: FEAT-101
type: feature
severity: medium
title: Publish a prebuilt, versioned migration-runner image instead of building the Sol CLI from source on every sol migrate
source: operator code-review notes (2026-09-26), cli/bin/cmd_migrate.ml push_runner_image
---

**Depends on:** None.

## The problem

`sol migrate` runs migrations in-cluster using an image *of the Sol CLI itself*. `push_runner_image` (`cli/bin/cmd_migrate.ml`) resolves `sol_home`, which is **a checkout of the Sol source repository** found by `Sol_cli_cmd_new.infer_sol_home` and not the user's project. It then runs `docker build` with that whole checkout as context and a Dockerfile (`sol_cli_dockerfile`) that installs OCaml dependencies and compiles the CLI. So:

- every user needs a Sol source checkout, which a released user won't have;
- every image build pays for an OCaml toolchain and a full compile;
- the image pins support libraries to `#main`, so it isn't reproducible.

## Remediation

Publish a migration-runner image per Sol release, and have `sol migrate` reference it by version (or digest) instead of building it.

## Open Questions

1. Which registry hosts the image (GHCR under the project, or elsewhere), and who is allowed to push?
2. Is it tagged by release version or pinned by digest in the CLI? Digest is reproducible; a tag is simpler.
3. What does a development build of `sol` (not a release) use: build from source as today, or the latest published image?

## Acceptance criteria (once the questions are answered)

- `sol migrate` needs no Sol source checkout.
- A test shows the runner image reference comes from the release, not from a local build.
- **Demo/example:** pluto's migration flow still works; state how that was checked.
