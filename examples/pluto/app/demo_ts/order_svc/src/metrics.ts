// prom-client handles exposition (the ecosystem library); the metric NAMES
// and LABELS below are Sol's convention, ported by hand from
// framework/sol-svc/lib/service.ml so this service's metrics land in the
// same Grafana panels as an OCaml sol-svc's would.

import { Counter, Histogram, Registry } from "prom-client";

export function makeSvcMetrics() {
  const register = new Registry();
  const requestsTotal = new Counter({
    name: "sol_svc_requests_total",
    help: "Total HTTP requests by method, route, and HTTP status class",
    labelNames: ["method", "route", "status_class"],
    registers: [register],
  });
  const requestDuration = new Histogram({
    name: "sol_svc_request_duration_seconds",
    help: "HTTP request latency in seconds by method and route",
    labelNames: ["method", "route"],
    registers: [register],
  });
  return { register, requestsTotal, requestDuration };
}
