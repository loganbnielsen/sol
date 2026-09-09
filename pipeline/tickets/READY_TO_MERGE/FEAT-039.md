---
id: FEAT-039
type: feature
severity: low
source: FEAT-038 review, 2026-09-08
branch: FEAT-039/demo-ts-ci-check
worktree: ../sol-FEAT-039-demo-ts-ci-check
pr: https://github.com/loganbnielsen/sol/pull/168
---

**Depends on:** FEAT-038 (done — merged).

Add a dedicated CI build check for `examples/pluto/app/demo_ts`'s two Dockerfiles.

## Problem

CI's `example-dockerfile-smoke` job matrix (`.github/workflows/ci.yml`) only covers the OCaml example services (`examples/pluto/app/comms/notify_worker/Dockerfile`, `examples/pluto/app/payments/charge_svc/Dockerfile`) — by design, since that job specifically catches *scaffold-template drift* (comparing hand-maintained examples against what `sol new` currently generates), and `demo_ts` has no Sol template to drift from.

That means the two TypeScript Dockerfiles FEAT-038 rewrote to build from repo-root context (`examples/pluto/app/demo_ts/{order_svc,fulfillment_worker}/Dockerfile`) have zero ongoing CI coverage. A future change to the npm workspace setup, either package's `package.json`, or either Dockerfile could silently break the build and nothing would catch it until someone tries to run the demo by hand.

## Remediation

Add a separate CI job (not folded into `example-dockerfile-smoke`, since that job's purpose is specifically template-drift detection) that builds both `demo_ts` Dockerfiles from repo-root context on every push/PR, the same way `example-dockerfile-smoke` builds the OCaml ones — just without the template-diff step, since there's no template to diff against here. A plain `docker build` success check is sufficient scope.

## Acceptance criteria

- A new CI job builds both `examples/pluto/app/demo_ts/{order_svc,fulfillment_worker}/Dockerfile` on every PR.
- A deliberately broken workspace reference (e.g. a bad `@sol/kafka` version constraint) causes this job to fail, proving it actually catches real breakage.

## Review — real CI confirmed green (2026-09-08)

Diff confirmed clean and additive: new `demo-ts-dockerfile-smoke` job shares the workflow's existing triggers, doesn't touch `example-dockerfile-smoke`. Deliberate-break-then-revert left zero trace in any of the four `package.json` files. This was the new job's first-ever real run on GitHub Actions — both matrix entries passed (order_svc 25s, fulfillment_worker 29s), the actual proof it works, not just a local claim. Full local suite independently re-run (pass). PR #168's complete CI run (34304110759) fully green: `test`, both new `demo-ts-dockerfile-smoke` entries, all 4 `example-dockerfile-smoke` entries, and `golden-path-smoke` (17m35s) all passed. Promoting on confirmed real-CI green — last ticket of today's TS framework-parity effort.
