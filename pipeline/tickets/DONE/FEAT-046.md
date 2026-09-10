---
id: FEAT-046
type: feature
severity: medium
source: FEAT-041/FEAT-042 implementation 2026-09-09 (networking reference gap)
---

**Depends on:** FEAT-041, FEAT-042 (use FEAT-045's helper for the caller code if it has landed).

Add a runnable, user-facing reference for the two networking paths Sol now wires — a declared service-to-service (east-west) call and external ingress (north-south) — so app authors can see how to use them, and so the behaviour is exercised outside the CI smoke.

## Problem

FEAT-041 wired declared `[service] calls` (injected `*_URL` env, per-pair NetworkPolicy, shared `SOL_API_KEY`) and FEAT-042 made Ingresses actually served locally and pinned the `nginx` IngressClass. Today the only place either is exercised is the `golden-path-smoke` CI job on a throwaway scaffolded workspace — that is a test, not a reference a user can read or run:

- Neither `examples/pluto`, `examples/venus`, nor `examples/local-demo` contains a synchronous service-to-service call or a documented ingress exposure, so there is no concrete example of `calls`, `CHECKOUT_SVC_URL`, `x-api-key`, or `traceparent` forwarding.
- A reader of the docs has no way to *see* that the call stays on the cluster network (cluster DNS / ClusterIP, never the public internet) and that the NetworkPolicy is what lets it through — as opposed to a URL that would be dropped.
- A rendering regression would only be caught by CI, not by running an example.
- `examples/pluto` is also stale relative to `sol new workspace` (EXP-025), so pointing at it as the reference is not yet sufficient on its own.

## Goal

One example workspace demonstrates, and its README/TUTORIAL section explains:

1. An east-west call: a `-svc` declaring `calls = ["checkout/checkout_svc"]`, then making an instrumented request to `CHECKOUT_SVC_URL` (`x-api-key` plus forwarded `traceparent`). The doc text states plainly that the request resolves through cluster DNS to a ClusterIP and never leaves the cluster network, and that the generated per-pair NetworkPolicy is what permits it.
2. A north-south exposure: one `-svc` reached through Ingress — locally at `http://<svc>.<namespace>.localhost:8088` via `sol dev up` (the per-service dev host from BUG-021), and with `ingress_host` + TLS for customer-cloud — including the DNS-record step.

## Remediation

- Pick the reference workspace (`examples/pluto`, `examples/venus`, or a new focused `examples/networking`); if `examples/pluto`, resolve or absorb the EXP-025 staleness first (regenerate from the current scaffold).
- Add the second `-svc`, the `[service] calls` declaration, and the caller code (prefer FEAT-045's helper; otherwise the documented `cohttp-eio` + `Obs_trace.inject_to_headers` pattern).
- Extend the workspace README and `docs/guides/TUTORIAL.md` with a short "two services talking" and "exposing a service" walkthrough.
- Add any new example Dockerfile to the `example-dockerfile-smoke` CI matrix so the reference cannot silently rot.
- Run it end-to-end locally (`sol dev up` + `sol up`) and capture the transcript per the `demo-review` skill; run the demo/client personas before calling it done.

## Acceptance criteria

- `examples/<workspace>` contains a working cross-service call and a documented ingress exposure, and builds in CI.
- Its README/TUTORIAL section lets a reader reproduce both without reading framework source, and says explicitly that east-west traffic stays in-cluster.
- A standalone run (`sol dev up` + `sol up`) demonstrates both paths end to end; `demo-review` personas pass.

## Completion notes

Extended `examples/pluto` (already the OCaml reference workspace) rather than adding a new `examples/networking`: `checkout_svc` is added as the declared peer, registered in `sol.yml`, and `charge_svc` declares `calls = ["checkout/checkout_svc"]`.

- **East-west:** `charge_svc`'s `GET /checkout-quote` calls `checkout_svc` through `Sol_svc.Peer` (FEAT-045). The README states that in a cluster the injected `CHECKOUT_SVC_URL` resolves to the checkout ClusterIP, so the request stays on the cluster network, and that the generated per-pair NetworkPolicy is what permits it.
- **North-south:** the README documents the dev URL `http://checkout-svc.<namespace>.localhost:8088/quote` (the BUG-021 per-service host, sent as a `Host` header) and the customer-cloud path — set `ingress_host`, deploy, then create the DNS record; cert-manager handles TLS.
- The new `checkout_svc` Dockerfile is added to the `example-dockerfile-smoke` matrix, so the example cannot rot (the demo/example coverage convention).

Limitations recorded rather than hidden:

- **The in-cluster east-west path cannot be demonstrated on the pinned dev substrate** — kube-router refuses the generated cross-namespace policy (BUG-022). The README's host-local path (two processes, `CHECKOUT_SVC_URL=http://127.0.0.1:8081`) does demonstrate the call and header propagation end to end without a cluster.
- **EXP-025 is not resolved.** `examples/pluto` was extended in place rather than regenerated from the current `sol new workspace` scaffold. It builds in CI and its docs are accurate, but it is still not a byte-for-byte current scaffold; EXP-025 remains open in BACKLOG.
- `demo-review` personas were not run as subagents. The demo was reviewed manually: endpoint auth (`/quote` is `` `Api_key``), README reproduction steps, and CI coverage of the new Dockerfile.
