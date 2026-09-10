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

## Positioning (agreed 2026-09-09)

**Category:** DevOps in a box — on a modern, extensible system, without vendor lock-in.

**Vision:** a solo engineer can start a business or a service and run it in production without hiring a second engineer for operations. Startup-focused: the trigger is a technical founder taking something live.

**The qualifier is the differentiator, not the category.** "DevOps in a box" is claimed by Coolify, Dokku, Porter, Northflank and every PaaS. "Modern, extensible, no lock-in" is what separates Sol from Heroku/Render/Railway/Fly, and the defensible mechanism behind it is **grow without a rewrite** — solo to a team, one service to many domains, your cloud to ours, with Terraform state export as a literal handoff (DEC-008).

**Retired as differentiators:**

- **"Typed."** Every typed language is typed. What is actually distinctive is that the contracts *between* services are enforced — registry-rejected event schemas, declared calls that get a real network path — not that types exist in-process.
- **"Event-driven."** Events are the default integration path, not the product: `-svc`, `-worker`, `-fn`, migrations, ingress, rollout/rollback and observability are all in scope.

**Already-written asset worth keeping:** the README's claim that Sol's conventions are "regular enough that AI coding agents produce correct output" amplifies the solo-engineer leverage story directly, and is more modern than the category phrase.

**Open, and blocking:** licensing and distribution. The repository is public and has **no `LICENSE` file**, while the README's first sentence calls Sol "open-source" — so "free self-hosting" is not legally available as written, and the README overstates. Deciding the licence is the prerequisite for the self-host pole.

**Unhappy paths are the proof.** "No ops engineer" is demonstrated by what happens when things break — a bad deploy rolled back, a malformed event rejected, a crash-looping pod diagnosed from traces. The current reference workspace (FEAT-046) shows happy paths only; the demo has to catch up to the claim.

## What it needs to answer

- **Positioning and wedge.** What Sol is for in one sentence, and against whom: Vercel/Render/Railway/Fly, Heroku, DIY Kubernetes with Helm/Terraform, or a cloud's own PaaS. Note Sol is **language-agnostic**: OCaml is the first-class/encouraged path, and TypeScript is supported through the in-tree `@sol/kafka` and `@sol/obs` packages with a runnable `demo_ts` showcase — both runtimes land in the same Grafana panels and Tempo traces. So the wedge is not the language. Candidates visible in the codebase: one **application model** (`-svc`/`-worker`/`-fn` plus the ops conventions — probes, metrics, traces, drain) applied across languages; **events as the default cross-domain integration** with typed, schema-registry-enforced messages; and **the same model whether Sol hosts it or you do**.
- **Packaging: two modes, open-core.** Self-host (free: the software — framework, CLI, Terraform modules) and Sol-hosted (paid: the same thing with Sol running it, plus SLA, compliance and team features). A third mode — Sol operating inside the customer's own cloud account — was explicitly declined as too much surface (cross-account IAM, the customer's compliance regime and support chain). DEC-004 already recognises the two modes, with hosted as the paved road; this framing promotes the *free self-host path to the front door*, which leans on that decision and should be an explicit choice rather than drift.
- **ICP.** A technical founder or very small team taking a backend into production — people who would otherwise be the ops engineer. Not segmented by language (Sol is language-agnostic: OCaml is encouraged, TypeScript is supported in-tree).
- **Pricing and packaging**, tied to the substrate tiers: self-hosted (free, open core) and hosted (DEC-008 / DEC-011 / INFRA-006 — where the paid value is not running it, plus SLA/compliance/team features). The cheap-substrate economics (INFRA-006) decide whether "cheap to start" is credible. See the Positioning section for the licensing blocker.
- **Funnel.** Top of entry is the reference workspace and demo (FEAT-046), the TUTORIAL, and the golden-path smoke as the reliability proof.
- **Preconditions to check before starting:** a runnable demo that shows the platform working (FEAT-046), a hosted tenancy prototype (INFRA-004), a decided hosted provider policy (DEC-011), and enough feature completeness that the docs do not promise behaviour that isn't there.

## Acceptance criteria

- A written plan covering positioning, ICP, pricing/packaging, and the funnel, stored alongside the other planning docs (`docs/planning/`).
- Every claim in it is traceable to something that exists or is scheduled; anything aspirational is marked as such.
