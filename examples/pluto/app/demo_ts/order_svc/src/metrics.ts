// prom-client handles exposition (the ecosystem library); the metric NAMES
// and LABELS below come from @sol/obs, which owns Sol's naming convention
// so this service's metrics land in the same Grafana panels as an OCaml
// sol-svc's would.

import { Counter, Histogram, Registry } from "prom-client";
import { SOL_SVC_REQUESTS_TOTAL, SOL_SVC_REQUEST_DURATION_SECONDS } from "@sol/obs";

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
  return { register, requestsTotal, requestDuration };
}
