---
id: FEAT-047
type: feature
severity: medium
source: BUG-022 resolution 2026-09-09 — the pinned toolchain now enforces the generated policy
---

**Depends on:** BUG-022 (in `DONE`, and its golden-path smoke green — the bump is only truly validated once the whole chart stack installs on k3s v1.35.5).

The substrate now honours cross-namespace `namespaceSelector` policy, so the live end-to-end assertion FEAT-041 and FEAT-045 had to abandon is achievable again — and the caveats that replaced it should go.

## Background

FEAT-041's golden-path check originally probed the declared cross-namespace call from a throwaway pod, and FEAT-045's criterion 3 asked for an *instrumented* app call. Both were denied on the substrate that was pinned at the time (kube-router ignored the `namespaceSelector` rule and REJECTed, which surfaces as `Connection refused` rather than a timeout). So the smoke was softened to assert the **deploy path** — the injected `CHECKOUT_SVC_URL` and the applied NetworkPolicy pair — and `docs/deployment/service-runtime-contract.md` grew a dev-substrate caveat.

BUG-022 removed the obstacle by moving the pin to k3d v5.9.0 / k3s v1.35.5, verified locally with a negative control.

## Remediation

- Restore a **live** assertion in the `golden-path-smoke` job: a declared caller reaches its peer (allow), and an undeclared pod does not (deny). Keep the deny half — an allow-only test would also pass on a substrate that ignores policy entirely.
- Prefer exercising the **instrumented** call (FEAT-045 criterion 3). `charge_svc`'s `/checkout-quote` already calls the peer through `Peer`, and `checkout_svc`'s `/quote` is `` `Api_key``-authed, so hitting the caller's route end to end proves the injected URL, the shared key, and `traceparent` forwarding in a single assertion.
- Retire the "Dev-substrate version caveat" in `service-runtime-contract.md`, or reduce it to a version statement, and update the matching notes in the FEAT-041/FEAT-045 completion notes (which currently record those criteria as unmet).
- Record for the record: **egress** policy is still unenforced on k3s (BUG-022's fourth finding). The generated policies do not depend on it, but do not add an egress-deny assertion expecting it to hold.

## Acceptance criteria

- The smoke fails if a declared cross-namespace call is refused, and fails if an undeclared pod reaches the peer.
- The instrumented caller route is exercised, not only a probe pod, so a regression in `Peer`'s header wiring fails CI.
- The dev-substrate caveat is removed or reduced to a version statement.
