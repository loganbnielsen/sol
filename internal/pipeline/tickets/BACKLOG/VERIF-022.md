---
id: VERIF-022
type: verification
severity: medium
title: Qualify projected ServiceAccount tokens for Sol-to-Sol calls on aws, gcp and byo
source: DEC-063 (2026-10-02 resolution) — the mechanism to qualify
---

**Depends on:** None.

## Blocked On

The operator's explicit authorization for a live-qualification run (AGENTS.md
§ Live qualification), and a qualified target per driver.

## Scope

Qualify the DEC-063 mechanism — a projected ServiceAccount token volume with
`audience: <callee unit>` and `expirationSeconds: 3600` — on `aws` (EKS), `gcp`
(GKE) and `byo`, under the qualification ledger's rules (strict evidence, no
in-run remediation):

1. **No API access.** A pod carrying the projected token cannot authenticate to
   the Kubernetes API (the audience is the callee, not the API server), so
   `DEC-026` §7's "no ambient Kubernetes token" holds. Assert this positively.
2. **Issuer discovery.** The callee reaches the cluster's OIDC issuer discovery
   document and JWKS; record the issuer URL per driver. On `byo`, confirm the
   driver *checks* the capability and reports it absent when there is none.
3. **Verify and authorize.** A declared caller succeeds; a unit not in the
   callee's `called_by` set is refused with `403`; a request with no token is
   `401`; a token minted for a different `aud` is refused.
4. **Rotation.** Rotate a signing key and confirm the callee re-fetches on an
   unknown `kid`; measure how long a rotated-out key remains trusted and compare
   it with the stated window (published-while-signing plus one cache TTL).
5. **Refresh without restart.** Confirm the framework re-reads the refreshed
   projected file and a running unit keeps calling after the token rotates.

## Acceptance criteria

- Each driver records the exact commands and observed outputs, the cluster's
  issuer URL, and the token-lifetime and rotation measurements.
- The DEC-063 driver-verdict rows move from `to qualify` to observed verdicts, or
  state precisely what failed.
- The `byo` capability check (issuer discovery required, missing reported) is
  confirmed live.
- The mechanism, audience and claims mapping are recorded for the `DEC-022`
  cross-language contract; the OCaml and TS implementations must match them.
- Demo/example: not applicable to this run; the implementing unit owns the pluto
  `calls` example per DEC-063.


## Disposition (2026-10-03) — live/operator blocked

Requires explicit authorization for a live qualification run and a qualified
target per driver.

Gated on explicit authorization and/or the live reference-app campaign; see
AGENTS.md § Live qualification.
