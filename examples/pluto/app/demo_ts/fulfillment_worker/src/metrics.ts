// Metric names ported by hand from framework/sol-worker/lib/worker.ml
// (sol_worker_messages_total{status}, sol_worker_message_duration_seconds) —
// prom-client is the ecosystem exposition library, the naming is Sol's.
//
// Real status vocabulary (worker.ml:99-163) is exactly {ok, error, retry,
// ack_failed} — decode/validation failures are NOT a messages_total status
// at all. They're intercepted before the handler ever runs
// (kafka_service_intf.ml's wrap_on_decode_error) and counted on their own
// counter, sol_worker_decode_errors_total. Mirror both here rather than
// inventing extra status label values that would make a cross-language
// Grafana panel disagree between an OCaml and a TS worker.

import { Counter, Histogram, Registry } from "prom-client";

export function makeWorkerMetrics() {
  const register = new Registry();
  const messagesTotal = new Counter({
    name: "sol_worker_messages_total",
    help: "Total Kafka messages processed by status",
    labelNames: ["status"],
    registers: [register],
  });
  const decodeErrorsTotal = new Counter({
    name: "sol_worker_decode_errors_total",
    help: "Total messages rejected by decode/schema validation",
    registers: [register],
  });
  const messageDuration = new Histogram({
    name: "sol_worker_message_duration_seconds",
    help: "Message processing latency in seconds",
    registers: [register],
  });
  return { register, messagesTotal, decodeErrorsTotal, messageDuration };
}
