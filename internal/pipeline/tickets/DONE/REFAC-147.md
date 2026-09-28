---
id: REFAC-147
type: refactor
severity: medium
title: Teach decode operate render boundaries in the generated HTTP example
source: Logan readability review generalized by style audit (2026-09-27)
---

Teach decode, operate, and render boundaries in the generated HTTP example

**Depends on:** None.

**Premise verified (2026-09-27):** read both handler implementations on `origin/main`
at `954afad7`; each route still owns decode, operation, and response mapping inline.

**Problem:** the canonical workspace scaffold's `/charges` route embeds JSON decoding,
ID generation, tracing/logging, publishing, error classification, and HTTP response
rendering in one route literal
(`platform/shared/templates/workspace/app/payments/charge_svc/lib/handler.ml`). The
checked-in Pluto reference repeats the same dense controller shape with a database
operation (`examples/pluto/app/payments/charge_svc/lib/handler.ml`). App authors
therefore copy a handler whose operation cannot be tested without constructing HTTP
requests. The generic service template is already appropriately small and is out of
scope.

## Remediation

Keep routes declarative. Extract only a typed charge input, `decode_charge`, and a
directly testable `create_charge` operation/result in both the scaffold and Pluto. Let
the route remain the HTTP controller that maps decode/operation results to responses.
Do not invent a controller framework or force the two examples to share application
code.

## Acceptance criteria

- Each `/charges` route body is a short, linear decode → operate → render flow.
- Charge input and operation outcomes are typed rather than tuple/string conventions.
- Each operation is directly unit-testable without `Request.t` or `Response.t`.
- A generated workspace and Pluto retain behavior and build; focused tests cover the
  operation boundary, and scaffold golden expectations are updated.
- The runnable example is updated in the same change and receives focused runnable
  validation; an additional persona review is optional under FEAT-105 and the operator's
  explicit review waiver for this refactor queue.
- Language parity: no impact; this teaches application structure without changing the
  HTTP or event contract.

## Completion notes (2026-09-28)

- Premise reverified at `621b3f9d`: both charge routes still contained local tuple
  decoding and inline operations. Extracted `charge_input`, `accepted_charge`, named
  decoding/operation/response functions, and declarative route registration in both.
- Pluto retains direct `Notification.insert` acceptance with native database errors;
  the scaffold retains its span, pre-publication acceptance log, Kafka event payload,
  correlation-header/default behavior, and publication-error response. No shared app
  library or framework/controller abstraction was introduced.
- Direct operation tests require neither Request nor Response nor live database/broker:
  successful values and unchanged errors, missing/wrong fields, malformed JSON,
  event identity/payload, and explicit/default correlation IDs are covered.
- Pluto builds and its charge test passes. A real `sol new workspace sample` generated
  32 files; the generated charge test and full workspace build pass. All 52 CLI scaffold
  tests pass, including the golden test/dune expectation and generated operation-test
  execution added to the existing build case. Formatting and no-comments checks pass.
- Demo/example: both the canonical runnable Pluto example and copied workspace template
  changed together; Pluto documents the directly runnable test. Additional adversarial
  personas were waived as authorized; no HTTP/event/runtime contract changed.
- Language parity: no impact; this is OCaml application organization, with unchanged
  HTTP statuses/response text, event schema, database writes and retry/error behavior.
