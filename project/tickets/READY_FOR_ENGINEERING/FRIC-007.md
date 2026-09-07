---
id: FRIC-007
type: dogfood-finding
severity: blocker
source: project/dogfood/RUN_2026-09-07.md
---

**Depends on:** None.

Every generated Sol service crash-loops on startup: Redpanda's schema registry (as deployed by `sol dev up`'s pinned Helm chart) rejects `schemaType: "JSON"` registration.

**Description:** `Kafka_service.register` (`integrations/kafka/kafka-eio-service/lib/kafka_service.ml:167-170`, via `kafka_service_schema.ml`'s `register_schema`) sends every schema registration as:

```json
{"schemaType": "JSON", "schema": "..."}
```

to `POST /subjects/{subject}/versions`, unconditionally, for every generated `-svc` and `-worker`. The Redpanda broker `sol dev up` currently deploys (Helm chart `redpanda/redpanda` version `5.8.12`, running Redpanda image `v24.1.8`) rejects this with:

```
HTTP 422 {"error_code":422,"message":"Invalid schema type JSON"}
```

Confirmed independently of any Sol code path via a direct `curl` against the raw registry API (same request, same response) — this is not a Sol-side protocol bug, it's the deployed Redpanda version/configuration rejecting the schema type Sol always sends. The identical request with the `schemaType` field omitted (defaulting to Avro) returns `200`.

**Impact:** This is not an edge case — it reproduced deterministically on a completely fresh `sol dev up` substrate with a completely fresh `sol new workspace` scaffold, with zero modification. Both generated services (`charge-svc`, `notify-worker`) enter `CrashLoopBackOff` immediately and permanently:

```
error: kafka register: schema registry for topic dogfood_2026_09_07-payments-charges: schema registry: HTTP 422: {"error_code":422,"message":"Invalid schema type JSON"}
```

Every step after this in the golden path (`sol status`'s health, `curl /health`, `POST /charges`, the Kafka→worker→notification flow) is unreachable for **any** new user following the documented golden path today. This is the single highest-severity finding of this dogfood run.

**Not yet determined:** whether this is (a) a capability regression/config requirement in Redpanda `v24.1.8`'s schema registry that an earlier version didn't have, (b) a cluster/schema-registry config flag Sol's Helm values (`platform/local/...` chart values) don't currently set, or (c) a licensing gate on non-Avro schema types in this Redpanda edition — the broker's own logs (`pandaproxy - server.cc:125`) give only the same generic exception text, no license or config hint. Whoever picks this up should check Redpanda's release notes/docs for `v24.1.8`'s schema registry JSON Schema support requirements before assuming a code-level fix on Sol's side is the only option.

**Remediation:** Investigate in this order:
1. Check whether Redpanda's Helm values (wherever `sol dev up` configures the `redpanda/redpanda` chart) need an explicit flag to enable JSON Schema support (e.g. a schema-registry or pandaproxy config property), or whether the pinned chart/image version needs bumping.
2. If JSON Schema support genuinely isn't available in a supportable way on the currently-pinned Redpanda version, evaluate switching Sol's default `schemaType` to Avro instead — this is a more invasive change (Avro schema definitions differ from Sol's current JSON-Schema-shaped `MESSAGE.schema` values, and would need re-deriving `events/payments/charged.ml`-style generated schemas in Avro form) and should not be done without confirming JSON Schema truly isn't a viable path first.
3. Whichever fix lands, add a golden-path regression check (even a minimal one — e.g. `sol dev up` + `sol up` + a single `curl /health` in CI, gated to run only when Docker/k3d are available) so this class of "every generated service is broken" regression doesn't require a manual dogfood pass to catch again.
