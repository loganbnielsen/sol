# FND-0049 — Message drop and diversion signals exist as metrics but have no starter alerts; the source-topic decode default is contested

- **Classification:** `DESIGN_GAP`
- **State:** `OPEN`
- **First identified:** 2026-09-23. The alerting gap and the policy argument were raised by
  a second reviewer; re-verified in this audit.
- **Derived ticket:** `OBS-047` (alerts), `BUG-051` (decode policy — decided in HARDEN-004 handoff step 6)
- **Evidence class:** `STATIC`

## What is established

The starter alert set (`cli/platform/infra/base/main.tf:1105-1227`) is `SolHighErrorRate`,
`SolPodRestartLoop`, `SolRolloutFailed`, `SolNodeNotReady`, `SolTelemetryTargetDown`,
`SolPostgresUnavailable`, `SolKafkaConsumerLagHigh`, `SolKafkaBrokerDown`. Consumer lag
**is** covered. That corrects the reviewer's statement that it was not.

Nothing alerts on the three signals that mean messages are being dropped or diverted:

- `sol_worker_decode_errors_total`: source-topic decode failures, each **acked and dropped**
  by default (`kafka_service.ml:306-310`);
- `sol_worker_messages_total{status="dead_letter"}`: DLQ inflow;
- `sol_worker_messages_total{status="relay_failed"}`: the only metric-level signal for
  FND-0035.

## The contested policy

The ack-and-drop default on the source topic is a documented carve-out
(`sol-worker.md:258`, BUG-028 non-goals: "the message was never accepted"). It applies
even under `Retry_topics`, where a DLQ exists and could hold the message. The reviewer's
case: a producer deployed with an incompatible schema makes every consumer ack its way
through the topic at full throughput, and the only trace is a counter nobody is alerted
on. This audit records that argument without overturning the recorded decision. It needs
an explicit re-decision (DEC).

## Decision (recorded 2026-09-23 in the HARDEN-004 handoff, step 6)

(1) Route source-topic decode failures to the DLQ whenever `Retry_topics` configures one,
and make ack-and-drop an explicit opt-in exposed through `Worker.Make*`. (2) Add starter
alerts for decode drops, DLQ inflow and `relay_failed`.

## Related

BUG-028, BUG-029, FND-0035, OBS-043.
