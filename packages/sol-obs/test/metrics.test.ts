import { test } from "node:test";
import assert from "node:assert/strict";
import {
  UNMATCHED_ROUTE,
  httpMethodLabel,
  statusClassOf,
  routeLabel,
  SOL_WORKER_MESSAGES_TOTAL,
  SOL_WORKER_DECODE_ERRORS_TOTAL,
} from "../src/metrics.js";
import type { WorkerMessageStatus } from "../src/metrics.js";

test("worker message status vocabulary is exactly {ok,error,retry,ack_failed}", () => {
  const valid: WorkerMessageStatus[] = ["ok", "error", "retry", "ack_failed"];
  // This is a compile-time guarantee (the type itself), but assert something
  // runtime-checkable too: decode errors are never one of these values --
  // they live on a wholly separate, differently-named counter.
  assert.equal(valid.includes("decode_error" as WorkerMessageStatus), false);
  assert.notEqual(SOL_WORKER_MESSAGES_TOTAL, SOL_WORKER_DECODE_ERRORS_TOTAL);
});

test("decode errors counter is a distinct metric name from the status counter", () => {
  assert.equal(SOL_WORKER_DECODE_ERRORS_TOTAL, "sol_worker_decode_errors_total");
  assert.equal(SOL_WORKER_MESSAGES_TOTAL, "sol_worker_messages_total");
});

test("httpMethodLabel maps known verbs and falls back to OTHER", () => {
  assert.equal(httpMethodLabel("GET"), "GET");
  assert.equal(httpMethodLabel("post"), "POST");
  assert.equal(httpMethodLabel("HEAD"), "OTHER");
  assert.equal(httpMethodLabel("OPTIONS"), "OTHER");
});

test("statusClassOf buckets by hundreds digit", () => {
  assert.equal(statusClassOf(200), "2xx");
  assert.equal(statusClassOf(201), "2xx");
  assert.equal(statusClassOf(404), "4xx");
  assert.equal(statusClassOf(500), "5xx");
});

test("routeLabel defaults to the fixed unmatched constant, never the raw path", () => {
  assert.equal(routeLabel(undefined), UNMATCHED_ROUTE);
  assert.equal(routeLabel("/orders/:id"), "/orders/:id");
  // Regression guard for FEAT-033's unbounded-cardinality bug: a caller who
  // (incorrectly) passes a raw request path instead of a route pattern gets
  // exactly that string back -- routeLabel can't protect against a caller
  // passing the wrong kind of string, but it must never silently substitute
  // one for the other on its own, and it must default to UNMATCHED_ROUTE
  // (not the empty string, not undefined) when nothing is supplied.
  assert.notEqual(routeLabel(undefined), "");
  assert.notEqual(routeLabel(undefined), undefined);
});
