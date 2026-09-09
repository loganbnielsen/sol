---
id: FEAT-039
type: feature
severity: low
source: FEAT-038 review, 2026-09-08
branch: FEAT-039/demo-ts-ci-check
worktree: ../sol-FEAT-039-demo-ts-ci-check
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
