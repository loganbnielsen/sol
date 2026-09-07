// Metric names ported by hand from framework/sol-worker/lib/worker.ml
// (sol_worker_messages_total{status}, sol_worker_message_duration_seconds) —
// prom-client is the ecosystem exposition library, the naming is Sol's.

import { Counter, Histogram, Registry } from "prom-client";

export function makeWorkerMetrics() {
  const register = new Registry();
  const messagesTotal = new Counter({
    name: "sol_worker_messages_total",
    help: "Total Kafka messages processed by status",
    labelNames: ["status"],
    registers: [register],
  });
  const messageDuration = new Histogram({
    name: "sol_worker_message_duration_seconds",
    help: "Message processing latency in seconds",
    registers: [register],
  });
  return { register, messagesTotal, messageDuration };
}
