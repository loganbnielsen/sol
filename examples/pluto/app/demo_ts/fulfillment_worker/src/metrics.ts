// Metric names come from @sol/obs, which owns Sol's naming convention —
// prom-client is the ecosystem exposition library, the naming is Sol's.
//
// Real status vocabulary is exactly {ok, error, retry, ack_failed} —
// decode/validation failures are NOT a messages_total status at all.
// They're intercepted before the handler ever runs (@sol/kafka's
// wrapEachMessage) and counted on their own counter,
// sol_worker_decode_errors_total. Mirror both here rather than inventing
// extra status label values that would make a cross-language Grafana panel
// disagree between an OCaml and a TS worker.

import { Counter, Histogram, Registry } from "prom-client";
import {
  SOL_WORKER_MESSAGES_TOTAL,
  SOL_WORKER_MESSAGE_DURATION_SECONDS,
  SOL_WORKER_DECODE_ERRORS_TOTAL,
} from "@sol/obs";

export function makeWorkerMetrics() {
  const register = new Registry();
  const messagesTotal = new Counter({
    name: SOL_WORKER_MESSAGES_TOTAL,
    help: "Total Kafka messages processed by status",
    labelNames: ["status"],
    registers: [register],
  });
  const decodeErrorsTotal = new Counter({
    name: SOL_WORKER_DECODE_ERRORS_TOTAL,
    help: "Total messages rejected by decode/schema validation",
    registers: [register],
  });
  const messageDuration = new Histogram({
    name: SOL_WORKER_MESSAGE_DURATION_SECONDS,
    help: "Message processing latency in seconds",
    registers: [register],
  });
  return { register, messagesTotal, decodeErrorsTotal, messageDuration };
}
