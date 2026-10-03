import { Counter, Gauge, Histogram, Registry } from "@prometheus-io/client";
import {
  SOL_WORKER_MESSAGES_TOTAL,
  SOL_WORKER_MESSAGE_DURATION_SECONDS,
  SOL_WORKER_DECODE_ERRORS_TOTAL,
} from "@sol-fab/obs";
import {
  SOL_OUTBOX_PUBLISHED_TOTAL,
  SOL_OUTBOX_PENDING,
  SOL_OUTBOX_OLDEST_PENDING_SECONDS,
} from "@sol-fab/outbox";

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
  const outboxPublishedTotal = new Counter({
    name: SOL_OUTBOX_PUBLISHED_TOTAL,
    help: "Total outbox publications by kind and status",
    labelNames: ["kind", "status"],
    registers: [register],
  });
  const outboxPending = new Gauge({
    name: SOL_OUTBOX_PENDING,
    help: "Outbox rows waiting to be published, by kind",
    labelNames: ["kind"],
    registers: [register],
  });
  const outboxOldestPendingSeconds = new Gauge({
    name: SOL_OUTBOX_OLDEST_PENDING_SECONDS,
    help: "Age of the oldest unpublished outbox row in seconds, by kind",
    labelNames: ["kind"],
    registers: [register],
  });
  return {
    register,
    messagesTotal,
    decodeErrorsTotal,
    messageDuration,
    outboxPublishedTotal,
    outboxPending,
    outboxOldestPendingSeconds,
  };
}
