---
id: FEAT-085
type: feature
severity: medium
title: Example workspaces are not independently buildable under the DEC-024 workspace contract
source: FEAT-082 resumed golden-path walk 2026-09-15 (after BUG-034 / PR #271)
---

**Depends on:** None.

The OCaml/structural half of this ticket is independent. Its TypeScript half is
gated by DEC-023 (install path for `@sol-fab/*`), recorded under **Related**
rather than on the `Depends on` line on purpose.

**Related:** FEAT-082, DEC-024, DEC-023, BUG-034, FEAT-084.

## Finding (real run — see FEAT-082's resume log)

`examples/pluto` and `examples/venus` carry `sol.yml` but are **subtrees of the
Sun repo's Dune project**, not independent projects:

```text
examples/pluto/
├── sol.yml            <- DEC-024 workspace boundary
├── app/.../dune       <- unit build files
├── sol/...
└── (no dune-project, no dune-workspace, no vendor/framework)
```

`dune` resolves them only because the enclosing `sun/` checkout has the
`dune-project`, and their Dockerfiles encode that assumption: every one sets the
build context to the **Sun monorepo root** (`docker build -f
examples/pluto/app/.../Dockerfile .`), OCaml units then `dune build
examples/pluto/app/...`, TS units `COPY package.json packages/sol-kafka
packages/sol-obs examples/pluto/...`.

After BUG-034, `sol up` derives the build context from the resolved workspace
root, so those paths do not exist and the build dies:
`"/examples/pluto/app/demo_ts/order_svc": not found`.

A path rewrite alone does **not** fix the OCaml units: with the context at the
workspace root there is no `dune-project` there, so `dune build app/...` has no
project root. The workspace has to become self-contained, not merely be built
from a smaller context.

## Why this is a real gap, not fixture hygiene

DEC-024's contract is that a workspace is independently located by `sol.yml`;
FEAT-082's boundary criterion is that it must obtain everything required to
build without knowledge of the Sol source repository containing it.
`examples/pluto` fails that criterion — the fixture only ever built because the
old, buggy root discovery expanded the context to the whole Sun repo. Fixing
this is the prerequisite for the golden-path walk, and it is the shape FEAT-084's
scaffold must produce.

The TypeScript half is **DEC-023**: `@sol-fab/kafka`/`@sol-fab/obs` live in
`packages/`, outside the workspace, so the TS units cannot be self-contained
until a supported install path resolves them through normal package management.
This ticket must **not** widen the Docker context back to the enclosing repo or
teach workspace builds about `../../packages` to work around that.

## Remediation

1. Make `examples/pluto` a standalone project, mirroring what
   `sol new workspace` emits: a project root (`dune-project`), and
   `vendor/framework` linked to the Sol framework source so the in-tree
   `sol_svc`/`sol_worker` libraries resolve exactly as they do in a scaffolded
   workspace. Do the same for `examples/venus` if it remains a workspace.
2. Migrate every Dockerfile under those examples to workspace-root-relative
   paths (`COPY . /workspace`, `dune build app/...`), and drop the
   `examples/<name>/` prefixes.
3. Update `.github/workflows/ci.yml`'s `example-dockerfile-smoke` /
   `demo-ts-dockerfile-smoke` matrices to build with the **workspace root** as
   context (`cd examples/pluto && docker build -f app/.../Dockerfile .`), so CI
   validates the context `sol up` actually uses rather than the old monorepo
   context.
4. Confirm the Sun root `dune build` still behaves once the examples are
   separate projects (they should simply no longer be part of the root project).
5. Leave the TypeScript units red until DEC-023 lands the install path, then
   resume FEAT-082's walk (`sol up --scope=demo_ts`) at the next obstacle.

## Acceptance criteria

- `examples/pluto` builds from a **copy of itself alone**, with no enclosing Sun
  checkout: `docker build` with the workspace root as context succeeds for the
  OCaml units, and for the TS units once DEC-023 has landed.
- No Dockerfile under `examples/pluto` references a path outside the workspace.
- `sol up` in `examples/pluto` reaches the running-svc/worker step, which is the
  next obstacle in FEAT-082's walk.
- CI's example Dockerfile smoke matrix builds with the workspace root as context.
