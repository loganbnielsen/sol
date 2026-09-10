---
id: DOCS-015
type: feature
severity: low
source: architecture discussion 2026-09-09 ("eventually we need a GTM plan")
---

**Depends on:** None.

Draft Sol's go-to-market plan — positioning, ICP, pricing/packaging, and the funnel — once the product surface it would describe actually exists.

## Why this exists now

Several decisions already assume a commercial story, but nothing written down connects them: DEC-002 (single-tenant hosted), DEC-004 (hosted is a first-class path, with an exported self-managed lane), DEC-005 ("instant" onboarding), DEC-006 (billing), DEC-009 (thin web control plane; north star — "going from backend code to a running, observable, billed production service should require learning none of Sol's own infrastructure vocabulary"). DEC-008's criteria explicitly benchmark the hosted cost floor against "Vercel-style" cheapness, and DEC-011 reopens which provider that floor rests on.

This is a placeholder so the question is not lost. Nothing should be scheduled against it until the preconditions below hold.

## What it needs to answer

- **Positioning and wedge.** What Sol is for in one sentence, and against whom: Vercel/Render/Railway/Fly (developer UX, different language and event model), Heroku, DIY Kubernetes with Helm/Terraform, or a cloud's own PaaS. The differentiators actually visible in the codebase: typed OCaml primitives (`-svc`/`-worker`/`-fn`), events as the default cross-domain integration, and "runs in your own cloud/account" rather than only Sol-hosted.
- **ICP.** Who adopts first — OCaml/typed-functional teams, teams that want an event-driven backend without building the plumbing, or teams that want Kubernetes portability without Kubernetes operations — and what they use today.
- **Pricing and packaging**, tied to the substrate tiers: hosted (DEC-008 / DEC-011 / INFRA-006), customer-cloud ("bring your own"), and self-hosted. The cheap-substrate economics decide whether a "cheap to start" claim is credible.
- **Funnel.** Top of entry is the reference workspace and demo (FEAT-046), the TUTORIAL, and the golden-path smoke as the reliability proof.
- **Preconditions to check before starting:** a runnable demo that shows the platform working (FEAT-046), a hosted tenancy prototype (INFRA-004), a decided hosted provider policy (DEC-011), and enough feature completeness that the docs do not promise behaviour that isn't there.

## Acceptance criteria

- A written plan covering positioning, ICP, pricing/packaging, and the funnel, stored alongside the other planning docs (`docs/planning/`).
- Every claim in it is traceable to something that exists or is scheduled; anything aspirational is marked as such.
