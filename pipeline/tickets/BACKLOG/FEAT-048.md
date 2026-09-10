---
id: FEAT-048
type: feature
severity: low
source: architecture discussion 2026-09-09 (edge/ingress cost review); re-raised 2026-09-10
---

**Depends on:** None.

Decide whether Sol offers a Cloudflare (or equivalent) **edge** integration, and if so which slice — this is a discovery spike, not a commitment to build.

## Why it came up

Ingress cost and exposure were being reviewed, and Cloudflare is the obvious candidate: cheap, provider-neutral, and it removes the public load balancer entirely. The surrounding analysis exists only in conversation — this ticket exists so it is not lost.

## What the analysis concluded so far

- **Cloudflare is not a cloud provider, it is an *edge* provider.** Model it as an axis orthogonal to the cloud provider (`provider = aws|gcp` × `edge = none|cloudflare`), because it fronts any of them. That is also why it composes with the parked GCP question.
- **Most of the capability list is not differentiating.** DNS, CDN, WAF, DDoS and TLS all have direct AWS equivalents. The real differences are cost/posture (one DNS toggle versus ALB + CloudFront + WAF + ACM + Shield), provider neutrality, and **Cloudflare Tunnel** — outbound-only, no public load balancer, no inbound ports, with no clean AWS analogue (CloudFront VPC origins come closest).
- **The one slice worth building is Tunnel.** DNS/TLS mostly follow for free; WAF/rate-limiting is documentation, not code.
- **The blocker is prior work, not Cloudflare**: app `ingress_host` DNS records are still a manual step (FEAT-042 deferred external-dns). Automate that on Route53 first — it is a prerequisite for any edge provider.
- **Two cautions.** Third-party TLS termination puts Cloudflare in the data path, which is a procurement conversation for payments customers. And integration is not CI-testable without account credentials, so it would be Terraform plus docs with weak automated coverage — a real cost given the demo/example coverage convention.
- **Precedent to weigh**: FRIC-012 rejected a standing tunnel (SSM) for DB access in favour of reusing infrastructure Sol already owns. A *public ingress* tunnel is a different case — it replaces a load balancer rather than working around network reachability — but the principle should be argued explicitly.

## Remediation

- Confirm or refute the Tunnel-only scope, and the claim that it obviates the ALB/public-IPv4/egress line items for hosted and self-hosted deployments.
- State what it does *not* replace (compliance attestations, managed data services).
- Decide the sequencing against the Route53 DNS automation prerequisite.
- Get a view on the third-party-in-the-data-path question before treating it as a hosted-tier option.

## Acceptance criteria

- A written recommendation: build it, don't, or defer with a named trigger.
- If it proceeds, the scope is the Tunnel slice plus docs, and the `edge` axis is recorded in the substrate contract.
- The DNS-automation prerequisite and the compliance/TLS-termination question are each explicitly resolved or deferred.
