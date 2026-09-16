---
id: FEAT-085
type: feature
severity: medium
title: Example workspaces are not independently buildable under the DEC-024 workspace contract
source: FEAT-082 resumed golden-path walk 2026-09-15 (after BUG-034 / PR #271)
---

**Depends on:** DEC-025 (how an OCaml workspace obtains the Sol framework outside
the Sol source tree). The OCaml half cannot be made self-contained until that
mechanism exists.

The TypeScript half is **done** and was gated by DEC-023, recorded under
**Related** rather than on the `Depends on` line on purpose. The OCaml half now
has an explicit dependency of its own — DEC-025 — rather than being tracked as an
unspecified blockage here, because it is blocked on a product/distribution
decision that does not yet exist, not on engineering effort.

**Related:** FEAT-082, DEC-024, DEC-023, DEC-025, BUG-034, FEAT-084, INFRA-007.

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

### TypeScript half — DONE (2026-09-16, commit `cfd954be`)

`@sol-fab/kafka` and `@sol-fab/obs` were extracted to standalone public
repositories and published to npm (DEC-023), then this repo cut over:

- `packages/sol-obs` and `packages/sol-kafka`, plus the root npm workspace that
  existed only to wire them to the demo, were removed.
- `examples/pluto/app/demo_ts` is now its own npm project root, with its own
  `package.json`/`package-lock.json`, resolving `@sol-fab/*` from the registry.
- Both demo Dockerfiles build with the **workspace root** (`examples/pluto`) as
  context and install from npm instead of copying `packages/*/dist` out of the
  monorepo.
- CI: `demo-ts-dockerfile-smoke` builds from `examples/pluto`; `ts-tests` installs
  and builds from the demo's own project root. The `@sol-fab/*` suites and the
  Redpanda steps left this repo — their authoritative CI is the standalone
  repositories, which is also where the real-broker retry/DLQ tests run.

### OCaml half — BLOCKED on DEC-025

**Original step 1 is superseded.** It said to make `examples/pluto` standalone by
linking `vendor/framework` to the Sol framework source. That was faithful to what
`sol new workspace` emits, but it is the same coupling DEC-023 explicitly rejected
for TypeScript (`vendor/ts`, `../../packages/...`, widening the build context back
to the enclosing repo), and it contradicts DEC-024's contract that a workspace is
independently located by `sol.yml`.

**Do not** vendor the framework, widen the Docker context, or add
`../../packages`-style paths to "finish" this ticket. Each relabels the coupling
rather than removing it.

**DEC-025 is now decided (2026-09-16)**, so the mechanism no longer needs
discovering — public application-facing opam packages (`sol-svc`, `sol-worker`,
`sol-fn`, `sol-jobs`, `sol-obs`, `kafka-eio-service`; `sol-runtime`/`sol-env`
private), reached initially through **immutable tag/commit-pinned git opam
dependencies**. Public-opam publication is tracked as RELEASE-005 and does not
gate this ticket.

The remaining work:

1. Give the framework public opam package definitions and publishable library
   names (DEC-025's shape; `sol-obs` stays one package).
2. Make `sol new workspace` emit **workspace-owned opam metadata** declaring the
   framework dependencies, and stop creating the `vendor/framework` symlink.
3. Make `sol up` stop materialising framework source into the Docker build
   context, and stop emitting `#main` pins in generated Dockerfiles — a mutable
   branch pin is forbidden by DEC-025's invariants.
4. Make `examples/pluto` (and `examples/venus`, if it remains a workspace)
   ordinary workspaces under that mechanism: their own `dune-project` project
   root, the framework obtained as a declared dependency, and workspace-root
   Dockerfiles (`COPY . /workspace`, `dune build app/...`) with the
   `examples/<name>/` prefixes dropped.
5. Update `example-dockerfile-smoke` to build with the workspace root as context,
   so CI validates the context `sol up` actually uses.
6. Confirm the Sun root `dune build` still behaves once the examples are no
   longer part of the root dune project.

### Then

7. Run the `/tmp/foo` proof and resume FEAT-082's walk
   (`sol up --scope=demo_ts`) at the next obstacle.

## Acceptance criteria

- **Both language paths** must survive being physically copied outside the Sol
  checkout: `examples/pluto` copied to a directory with no enclosing Sun checkout
  builds, for the OCaml units (after DEC-025) and the TS units (already true).
  This is the executable form of DEC-024 — *a Sol workspace's buildability does
  not depend on its location inside the Sol source repository* — and it is a
  stronger check than `find_root` resolving `sol.yml` correctly.
- No Dockerfile under `examples/pluto` references a path outside the workspace.
- `sol new workspace`'s emitted workspace is itself self-contained by the same
  mechanism (per DEC-025's acceptance criteria); if the examples are the proof
  fixture, the scaffold is what they must match.
- `sol up` in `examples/pluto` reaches the running-svc/worker step, which is the
  next obstacle in FEAT-082's walk.
- CI's example Dockerfile smoke matrix builds with the workspace root as context.

## Outcome (2026-09-16) — DONE

DEC-025 chose public opam packages as the framework's distribution mechanism and
immutable git pins as the interim. The representation change landed as one commit
(`08853eee`), followed by CI bootstrap wiring and the standalone examples.

**What the workspace boundary is now:**

```text
workspace → declared opam dependency → installed package
```

`sol new` no longer symlinks framework source into the generated workspace. That
symlink made the framework's Dune files part of the *consumer's* Dune project,
which is both the coupling DEC-024 forbids and provably incompatible with the
framework being a package at all: any `(public_name ...)` needs a package at the
project root. Each workspace now has its own `dune-project` and `<name>.opam`,
uses the public hyphenated library names, and the generated/example Dockerfiles
reproduce the declared environment with `opam install . --deps-only` — they carry
no dependency list and no Sol repository list.

**Evidence.**

Isolated copied-workspace proof, `/tmp/sol-proof/`, copied files only:

| Check | Result |
| --- | --- |
| Symlinks in the copied OCaml workspace | 0 |
| Absolute refs to the Sol checkout | 0 |
| `$SOL_HOME` / `vendor/framework` refs | 0 |
| Pins in the fresh switch **before** dependency setup | 0 |
| Pins resolving into the original checkout **after** setup | **0** |
| Framework resolution | `git+https://github.com/loganbnielsen/sol.git#main` |
| `dune build` in the copy, fresh switch (`sol-proof`, OCaml 5.4.1) | exit 0 |
| TS copy: refs to `../sol-obs`/`../sol-kafka`/checkout | 0 |
| TS copy: `npm ci` + `npm run build -w order-svc` | exit 0 |

CI proves a different property — that Sol can *establish* its package boundary from
scratch — and is green across all 10 jobs (`09c6eadc`). Neither proof substitutes
for the other.

**Acceptance criteria:**

- Both language paths survive being copied outside the Sol checkout — **met**.
- No Dockerfile under `examples/pluto` references a path outside the workspace —
  **met** for build paths; the two `terraform_var_file` references found by the
  proof are *deployment* configuration and are filed as BUG-035.
- `sol new workspace`'s emitted workspace is self-contained by the same mechanism
  — **met**, and enforced by the scaffold compile guard, which now resolves the
  framework through installed packages rather than a vendored symlink.
- CI's example Dockerfile smoke matrix builds with the workspace root as context —
  **met** (per-workspace context, so the job fails if a workspace starts needing
  the enclosing repository again).
- `sol up` in `examples/pluto` reaches the running-svc/worker step — **reassigned
  to FEAT-082's walk**, which is where that step lives and what it exists to
  exercise. It is a golden-path capability, not a workspace-independence property.

**Found and fixed along the way**, each invisible to a green local suite and all
caught by CI's clean environment: an unsubstituted `{{basename}}` that made every
generated Dockerfile unbuildable; opam not applying a dependency's `pin-depends`
transitively; published `*-eio` releases lagging the framework; and `dune subst`
failing because `dune-project` has no `(name ...)`.

**Follow-ups:** RELEASE-005 (publish the framework and its dependencies, which
retires the interim pins entirely, and carries INFRA-007's opam inventory);
BUG-035 (Pluto's deploy targets reach back into the Sol repository).
