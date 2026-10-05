---
id: CODE_LAYER-033
type: refactor
severity: low
title: "Own TypeScript event decoding in the existing publishing contract package"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Own TypeScript event decoding in the existing publishing contract package

**Depends on:** None.

**Principles:** 1, 13, 15, 16, 18, 31, 32, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `examples/pluto/app/demo_ts/order_svc/src/wire.ts` implements OrderPlaced decoding.
- `examples/pluto/app/demo_ts/fulfillment_worker/src/wire.ts` repeats the fields/validation and reuses one decoder for OrderPlaced and OrderFulfilled.
- `examples/pluto/app/demo_ts/contract/src/contracts.ts:8` owns the event interfaces and schemas but exports no authoritative event decoders.

## Mechanism and impact

Consumers/producers maintain separate runtime acceptance rules for the publishing domain's same event. A contract evolution can compile while one copied decoder accepts/rejects different payloads. Coincidentally equal event shapes also conceal distinct ownership.

## Remediation

Move event-specific validated decoders into the existing contract package and have producer/consumer import them there. Preserve distinct named contracts even while shapes coincide. Reuse the existing package; no new shared dependency or generic decoding framework is required.

## Acceptance criteria

- Producer/consumer use the same authoritative OrderPlaced decoder.
- OrderFulfilled has an explicit independently named decoder/contract.
- Contract tests cover accepted/rejected field shapes and callers use those decoders.
- No cross-domain dependency on service implementation or duplicate event validation remains.

- Demo/example: update the runnable TS reference app imports and contract documentation.
- Language parity: compare publishing-domain decoder ownership with OCaml event modules and record the verdict.

## Existing work and scope

FEAT-129 generated language bindings; no matching open owner was found for handwritten decode ownership. This is a concrete second-use consolidation, not extraction for hypothetical reuse.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
