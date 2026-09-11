# @sol/obs

Sol's observability naming/shape conventions for TypeScript services, so a
TS `-svc`/`-worker` and an OCaml one land in the same Grafana panel and the
same Loki query without disagreeing on label vocabulary.

This is **not** a metrics or logging library — [`prom-client`](https://github.com/siimon/prom-client)
(or any Prometheus client) and your logger of choice remain the mechanism.
This package only owns the *shape*: metric names, label vocabularies, the
Loki push format, and W3C `traceparent` propagation glue that has no
official carrier outside HTTP/gRPC.

## What's here

- **`metrics.ts`** — the exact metric names and label vocabularies from
  `sol-worker`/`sol-svc`'s OCaml source (`sol_worker_messages_total`,
  `sol_worker_decode_errors_total`, `sol_svc_requests_total`,
  `sol_svc_request_duration_seconds`), plus small helpers
  (`statusClassOf`, `routeLabel`, `httpMethodLabel`) that derive label
  values the same way the OCaml side does.
- **`tracing.ts`** — `traceparentOf`/`extractTraceparent`, W3C `traceparent`
  header formatting/parsing for transports OpenTelemetry has no official
  carrier for (Kafka today; anything non-HTTP tomorrow).
- **`loki.ts`** — `makeLokiPusher`, Sol's structured-log-to-Loki push shape.

## Why these three specific things

Each one is here because a prior hand-rolled TypeScript port ([FEAT-033](../../pipeline/tickets/DONE/FEAT-033.md))
got it wrong at least once, in a way that would silently desync a
cross-language dashboard rather than fail loudly:

- Inventing `status="decode_error"`/`status="db_error"` label values that
  don't exist in the OCaml vocabulary.
- Putting the raw, caller-controlled request path into the `route` label
  instead of a fixed pattern — unbounded cardinality.
- Hardcoding the W3C traceparent sampled flag to `"01"`, and separately,
  parsing it with `parseInt(flags, 16) || 1`, which treats a legitimate
  unsampled trace (`flags=0`) as sampled due to JS falsy-zero coercion.

See each module's own comments for the exact OCaml source line references.

## Usage

```ts
import {
  SOL_SVC_REQUESTS_TOTAL,
  httpMethodLabel,
  statusClassOf,
  routeLabel,
  traceparentOf,
  makeLokiPusher,
} from "@sol/obs";
import { Counter } from "prom-client";

const requests = new Counter({
  name: SOL_SVC_REQUESTS_TOTAL,
  help: "Total HTTP requests by method, route, and HTTP status class",
  labelNames: ["method", "route", "status_class"],
});

requests.inc({
  method: httpMethodLabel(req.method),
  route: routeLabel(matchedRoutePattern), // undefined -> "unmatched"
  status_class: statusClassOf(res.statusCode),
});

const log = makeLokiPusher(process.env.LOKI_URL, "order-svc");
log("info", "order accepted", { orderId });
```
