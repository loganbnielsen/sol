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

- **Positioning and wedge.** What Sol is for in one sentence, and against whom: Vercel/Render/Railway/Fly, Heroku, DIY Kubernetes with Helm/Terraform, or a cloud's own PaaS. Note Sol is **language-agnostic**: OCaml is the first-class/encouraged path, and TypeScript is supported through the in-tree `@sol/kafka` and `@sol/obs` packages with a runnable `demo_ts` showcase — both runtimes land in the same Grafana panels and Tempo traces. So the wedge is not the language. Candidates visible in the codebase: one **application model** (`-svc`/`-worker`/`-fn` plus the ops conventions — probes, metrics, traces, drain) applied across languages; **events as the default cross-domain integration** with typed, schema-registry-enforced messages; and **the same model whether Sol hosts it or you do**.
- **Packaging: two poles.** People can self-host if they want, or hand the whole thing to Sol — the decision is which pole is the front door and how the middle is priced. DEC-004 already defines three lanes (Sol-hosted, customer-cloud, exported self-managed); GTM has to say which one leads, which is free, and what triggers the upgrade.
- **ICP.** Who adopts first — teams building event-driven backends across multiple domains who want the platform rather than the plumbing, and who either can't or don't want to run Kubernetes themselves. Language is an implementation detail, not a segment.
- **Pricing and packaging**, tied to the substrate tiers: hosted (DEC-008 / DEC-011 / INFRA-006), customer-cloud ("bring your own"), and self-hosted. The cheap-substrate economics decide whether a "cheap to start" claim is credible, and the self-host pole raises the open distribution/licensing question.
- **Funnel.** Top of entry is the reference workspace and demo (FEAT-046), the TUTORIAL, and the golden-path smoke as the reliability proof.
- **Preconditions to check before starting:** a runnable demo that shows the platform working (FEAT-046), a hosted tenancy prototype (INFRA-004), a decided hosted provider policy (DEC-011), and enough feature completeness that the docs do not promise behaviour that isn't there.

## Acceptance criteria

- A written plan covering positioning, ICP, pricing/packaging, and the funnel, stored alongside the other planning docs (`docs/planning/`).
- Every claim in it is traceable to something that exists or is scheduled; anything aspirational is marked as such.
