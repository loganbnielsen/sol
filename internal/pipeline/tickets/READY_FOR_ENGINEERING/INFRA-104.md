---
id: INFRA-104
type: infra
severity: medium
source: alpha.7 GCP H3, Q2 and Q3, 2026-10-04
title: Align the GCP qualification target and app driver with the alpha reference scenario
---

**Depends on:** None.

## Premise verified

`internal/qualification/gcp/live-qual.sh` writes a cloud target omitting `app_db` and `events` while the enabled alpha `orders_svc` declares both. Sol correctly rejects this before provisioning; a local patch exists. Its separate app target/driver still exercises `charge_svc`, `notify_worker`, `/charges` and `/notifications`, not the alpha orders/outbox/jobs scenario in both language namespaces. Thus its app phase cannot establish alpha B1/B3/B4 solely by being successful.

## Remediation

Correct the generated target and connect the GCP app phase to the existing language-neutral alpha scenario and row assertions. State the explicit alpha-row to provider-row/evidence mapping once in the procedure. Preserve managed Cloud SQL and Redpanda dependencies and production transport. Reuse the scenario assertions already implemented for the reference applications.

## Acceptance criteria

- The generated target declares the service's resources and passes `sol check` before provider mutation.
- The app phase drives the orders scenario for both OCaml and TypeScript namespaces with independent effect assertions, and records which alpha rows it actually ran.
- Legacy charges evidence cannot be presented as the new orders/outbox/jobs contract passing.
- Update the runnable GCP procedure and its offline checks. Language-parity impact: already equivalent scenario required in both languages; neither namespace may be silently omitted.
