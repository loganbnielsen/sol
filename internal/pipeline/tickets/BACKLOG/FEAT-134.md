---
id: FEAT-134
type: feature
severity: high
title: "Implement DEC-063: projected ServiceAccount tokens for Sol-to-Sol calls, authorized by the declared calls graph"
source: VERIF-022 / ALPHA_CAMPAIGN.md row E5 — DEC-063's decided mechanism has no implementing unit
---

**Depends on:** None.

**Related:** DEC-063 (the decided contract and its answers to the open questions), DEC-062 (not
a dependency: this needs no cloud IAM), DEC-022 (OCaml/TS capability parity), VERIF-022 (the
live qualification this unblocks), BUG-088/BUG-089 (workspace-wide derivation), FEAT-116/FEAT-129
(the declaration and its bindings), DEC-026 §7 (no ambient Kubernetes token), DEC-051 (`byo`
capability facts).

## Premise (verified 2026-10-03)

DEC-063 resolved the mechanism on 2026-10-02 and recorded that "Implementation is a follow-up;
`VERIF-022` qualifies the mechanism live ... before the framework claims it". No implementation
ticket was filed, and the mechanism is not in the tree, so `VERIF-022` has nothing to qualify.
Checked (positive controls included, because an absence search must be able to match):

```console
$ rg -n 'serviceAccountToken|expirationSeconds' cli/ framework/ --glob '*.ml'
(no matches)
$ rg -n 'automountServiceAccountToken' cli/lib/workspace/sol_cli_manifest_yaml.ml
207:    [ "automountServiceAccountToken", Y.bool false; "metadata", metadata ~ns ~name ]
$ rg -n 'Service\.call' framework/ cli/ --glob '*.ml'
(no matches)
$ rg -n 'Jwks_url' framework/ocaml/sol-svc/lib/auth.ml
12:  | Jwks_url of string
```

The projected-token volume, the caller API and the `calls`-graph authorization are absent;
`sol-svc`'s generic JWT/JWKS verification is the one piece that already exists, and it is the
callee half only. The Alpha campaign's `E5` was recorded as live-blocked on operator
authorization; preparation established that it is implementation-blocked first.

## Scope

Implement DEC-063's decided API. The decision is the specification.

1. **Manifest projection.** Each unit that declares `calls` gets a projected
   `serviceAccountToken` volume with `audience: <callee unit>` and
   `expirationSeconds: 3600`, mounted at the stable path the framework reads.
2. **Caller.** `Service.call <Callee>.<route> request` (OCaml) resolves the callee from the
   declared `calls` graph, reads the projected token for that audience, and attaches
   `Authorization: Bearer <token>`. The developer never handles the token; an undeclared call
   site is a plan/build-time error.
3. **Callee.** Verification middleware validates the token offline against the issuer's JWKS
   (`iss`, `aud`, `exp`/`nbf`, signature), maps `sub`/`kubernetes.io` claims to the Sol unit
   exactly (never from mutable labels), and authorizes against `called_by`: `401` for no token
   or an unverifiable one, `403` for an authenticated but undeclared caller. Re-read the
   projected file when it changes, without a restart.
4. **Issuer discovery.** The callee reaches the cluster's OIDC discovery document and JWKS; on
   `byo` the driver checks the capability and reports it absent rather than silently falling
   back to NetworkPolicy as if it were equivalent.
5. **`DEC-022` parity.** The same contract — audience, projected file path, claims mapping,
   `401`/`403` semantics — in TypeScript.
6. **Example.** The pluto `calls` edge `payments/charge_svc` → `checkout/checkout_svc` becomes
   authenticated and authorized, with a negative case: a caller not in `called_by` is refused
   with `403`.

## Non-goals

- No SPIFFE/SPIRE, mTLS or service mesh (DEC-063's non-goals).
- No `TokenReview`; it stays deferred with its named trigger.
- No external-caller identity work; that is DEC-029's scope.

## Acceptance criteria

- A declared `calls` edge renders the projected token volume with the callee audience and
  `expirationSeconds: 3600`; an undeclared call site fails at plan/build time.
- Tests cover the declared caller succeeding and the three negatives: no token `401`, an
  undeclared caller `403`, and a token minted for a different `aud` refused.
- A rotated projected file is picked up by a running unit without a restart.
- The pluto `calls` example exercises the positive and the `403` negative.
- The TypeScript contract matches (DEC-022 capability/behavioural parity, not shared
  implementation); state the parity in the completion notes.
- `VERIF-022` is then runnable; the `aws`/`gcp`/`byo` driver verdicts remain its to establish,
  not this ticket's to claim.

**Demo/example coverage:** the pluto `calls` edge above, with its negative case, is the runnable
example this ticket must update.

**TypeScript parity (DEC-022):** required — this is an application-facing framework primitive, and
the contract must hold in both languages.
