import { Counter, Gauge, Histogram, Registry } from "@prometheus-io/client";
import { SOL_SVC_REQUESTS_TOTAL, SOL_SVC_REQUEST_DURATION_SECONDS } from "@sol-fab/obs";
import {
  SOL_OUTBOX_PUBLISHED_TOTAL,
  SOL_OUTBOX_PENDING,
  SOL_OUTBOX_OLDEST_PENDING_SECONDS,
} from "@sol-fab/outbox";

export function makeSvcMetrics() {
  const register = new Registry();
  const requestsTotal = new Counter({
    name: SOL_SVC_REQUESTS_TOTAL,
    help: "Total HTTP requests by method, route, and HTTP status class",
    labelNames: ["method", "route", "status_class"],
    registers: [register],
  });
  const requestDuration = new Histogram({
    name: SOL_SVC_REQUEST_DURATION_SECONDS,
    help: "HTTP request latency in seconds by method and route",
    labelNames: ["method", "route"],
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
    requestsTotal,
    requestDuration,
    outboxPublishedTotal,
    outboxPending,
    outboxOldestPendingSeconds,
  };
}
