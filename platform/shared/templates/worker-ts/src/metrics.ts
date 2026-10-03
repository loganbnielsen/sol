import { Counter, Histogram, Registry } from "@prometheus-io/client";
import {
  SOL_WORKER_MESSAGES_TOTAL,
  SOL_WORKER_MESSAGE_DURATION_SECONDS,
  SOL_WORKER_DECODE_ERRORS_TOTAL,
} from "@sol-fab/obs";

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
