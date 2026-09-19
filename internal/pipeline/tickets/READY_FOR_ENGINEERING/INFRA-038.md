---
id: INFRA-038
type: bug
severity: high
title: A profile guarantee must not fire because nothing in the scope uses the capability
source: HARDEN-002 Run 5 Attempt 5 — a scoped deploy of a stateless service failed the Kafka-durability guarantee
---

**Related:** ADR 0002, ADR 0004, HARDEN-002 (Attempt 5), FRIC-026/FRIC-011 (the
image and wiring declarations this sits beside).

## The finding

Attempt 5 could not deploy the qualification workload. Scoping to the OCaml
services removed the TypeScript blocker, and then:

```text
error: this target selects profile production-single-region/v1, and preflight
found 1 unmet guarantee(s). Nothing was changed.
  - Kafka durability is not established [application]:
    declare each Kafka-using service with uses: [<kafka resource>]
```

The service in scope was `checkout_svc`. It is a **stateless** `/quote` endpoint
(`app/checkout/checkout_svc/lib/checkout.ml`, 16 lines, no database, no events),
so declaring `uses: [app_db, events]` for it would be a fabrication. The fixture
is correct; the guarantee is wrong for this scope.

The mechanism is the quantifier in `sol_cli_deployment_plan.ml`:

```ocaml
( not (service_uses "kafka")
, Sol_cli_profile.Kafka_durability
, "declare each Kafka-using service with uses: [<kafka resource>]" )
```

`service_uses` is a `List.exists` over the *selected* services, so the guarantee
is unmet whenever no selected service declares a Kafka resource. A whole-workspace
deploy passes it (charge_svc and notify_worker declare `events`); a legitimate
single-service deploy of a service that uses nothing cannot pass it at all.

The message describes a per-service conformance rule — "declare **each**
Kafka-using service" — which is vacuously satisfied when nothing uses Kafka. The
implementation asks a different question: "does *anything here* use Kafka?"

## Why it matters beyond this scope

Partial deploys are the normal way to work on one service, and they are exactly
how a qualification run must avoid the TypeScript services this profile excludes
(DEC-026 §2). A guarantee that can only be satisfied by deploying something
unrelated to what is being qualified will keep steering people into either lying
in the fixture or deploying more than they meant to.

## Decision required

Two readings, and they differ in what the profile promises:

1. **Per-service conformance (recommended).** Fire only when a service declares a
   use the profile cannot honour — i.e. `service_uses "kafka" && not (profile
   promises Kafka durability)`. A scope that declares no Kafka use passes
   vacuously, matching the message. The guarantee then means "nothing here
   depends on a capability this target does not provide", which is the property
   worth having.
2. **Platform capability.** Keep it keyed on the selection, but then the message
   is wrong: it should say the *target* does not establish Kafka durability, and
   the remedy is a target/profile change, not a `uses:` declaration.

Only (1) lets a stateless service be deployed on its own. Whichever is chosen,
the message and the predicate must agree — that disagreement is what made this
hard to read from the outside.

## Acceptance criteria

- The predicate and the message state the same rule.
- A scoped deploy of a service that declares no Kafka use passes when the profile
  provides Kafka durably.
- A service that declares a Kafka use on a profile that cannot honour it still
  fails, with a message naming the service.
- Covered by tests for: no services selected, one service with no uses, one
  service with a Kafka use, and mixed scopes.
- HARDEN-002's deploy step (procedure step 6) is exercisable for a stateless
  service in isolation.

**Demo/example coverage:** `examples/pluto/sol.yml` stays as it is — this ticket
exists because the fixture was right and the check was wrong.

**TypeScript parity:** No language-parity impact.
