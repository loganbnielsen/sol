---
id: FEAT-102
type: feature
severity: high
title: Qualify TypeScript for the production profile -- close DEC-026 §2's remaining triggers
source: operator review (2026-09-26, sol-logan-comments), cli/lib/workspace/sol_cli_compat.ml
---

**Depends on:** None.

## The problem

The operator, on `Sol_cli_compat.supported_by_profile`, which returns `[ Ocaml ]`: "let's get TS in here? I think we need to focus on that if it's not supported yet". And: "if examples/pluto doesn't have a ts project, maybe we should add it? or we can have pluto_ocaml and pluto_ts?"

DEC-026 §2 staged TypeScript's production qualification behind three triggers. When all three hold, FEAT-088 adds TypeScript to the compatibility matrix "as a version-set update, with no new DEC needed". Their state, checked 2026-09-26:

1. **A deployed TypeScript golden-path CI job, merged and green: met.** The `golden-path-smoke-ts` job is in `.github/workflows/ci.yml:1086`, and main's latest CI run (head 14c1b79f) concluded `success`.
2. **The TypeScript worker has an `on_ready` equivalent: not met.** `npm pack @sol-fab/worker` (latest and only version 0.1.0): `RunWorkerOptions` in `dist/index.d.ts` has `drain`, `shutdownHooks`, `exit`, `onDrainStart` and `onError`, and no readiness hook. The package's source is `github.com/loganbnielsen/sol-typescript`, not this repo.
3. **`examples/pluto`'s `demo_ts` is cut over to the published `@sol-fab/*` packages with DEC-025's immutable-ref discipline: partly met.** Both `demo_ts` units depend on published `@sol-fab/kafka`, `@sol-fab/obs`, `@sol-fab/worker` / `@sol-fab/svc`, but by caret range (`^0.1.0`, `^0.2.0`). Whether the committed `package-lock.json` plus `npm ci` gives the immutability DEC-025 requires is the open question.

On the pluto question: pluto already has a TypeScript project (`examples/pluto/app/demo_ts`: `order_svc` and `fulfillment_worker`), so no split is needed. What is missing is that it cannot run under the production profile.

## Remediation

1. In `sol-typescript`: add a readiness hook to `@sol-fab/worker`, with the semantics DEC-026 §3 settles for OCaml's `on_ready`, and publish it. Record the version.
2. Pin `demo_ts` to exact versions and confirm the lockfile's integrity hashes are what `npm ci` installs. Record DEC-025's rule as applied to npm in the compatibility doc.
3. Set `supported_by_profile` to `[ Ocaml; Typescript ]`, update `docs/deployment/compatibility.md`'s matrix, and remove the "staged" preflight refusal for TypeScript workloads.
4. Run the TypeScript golden path against the profile (the existing smoke plus a profile-conformance check) as the evidence.

## Acceptance criteria

- The three triggers are each shown met in the completion notes, with the command and its output.
- A production-profile target with a TypeScript `-svc`/`-worker` passes preflight; the old refusal test is inverted.
- Demo/example: `examples/pluto/app/demo_ts` runs under the production profile, and the TypeScript tutorial says so.
- Language parity: this ticket *is* the parity work for the profile. Note any capability still OCaml-only, with its trigger.
