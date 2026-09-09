import { test } from "node:test";
import assert from "node:assert/strict";
import { traceparentOf, extractTraceparent } from "../src/tracing.js";
import type { Span } from "@opentelemetry/api";

function fakeSpan(traceId: string, spanId: string, traceFlags: number): Span {
  return {
    spanContext: () => ({ traceId, spanId, traceFlags, isRemote: false }),
  } as unknown as Span;
}

const TRACE_ID = "0af7651916cd43dd8448eb211c80319c";
const SPAN_ID = "b7ad6b7169203331";

test("traceparentOf formats the sampled flag byte from real span state, not a hardcoded value", () => {
  const sampled = traceparentOf(fakeSpan(TRACE_ID, SPAN_ID, 1));
  assert.equal(sampled, `00-${TRACE_ID}-${SPAN_ID}-01`);

  const unsampled = traceparentOf(fakeSpan(TRACE_ID, SPAN_ID, 0));
  assert.equal(unsampled, `00-${TRACE_ID}-${SPAN_ID}-00`);
  // The regression this guards: FEAT-033's first draft hardcoded "01"
  // regardless of the span's actual sampled state.
  assert.notEqual(unsampled, `00-${TRACE_ID}-${SPAN_ID}-01`);
});

test("extractTraceparent preserves a legitimate unsampled trace (flags=0)", () => {
  const ctx = extractTraceparent(`00-${TRACE_ID}-${SPAN_ID}-00`);
  assert.ok(ctx);
  assert.equal(ctx!.traceFlags, 0);
  // The regression this guards: `parseInt(flags, 16) || 1` treats 0 as
  // falsy and silently upgrades an unsampled trace to sampled.
  assert.notEqual(ctx!.traceFlags, 1);
});

test("extractTraceparent treats a sampled trace correctly", () => {
  const ctx = extractTraceparent(`00-${TRACE_ID}-${SPAN_ID}-01`);
  assert.equal(ctx!.traceFlags, 1);
});

test("extractTraceparent falls back to sampled only on a genuine parse failure", () => {
  const ctx = extractTraceparent(`00-${TRACE_ID}-${SPAN_ID}-zz`);
  assert.equal(ctx!.traceFlags, 1);
});

test("extractTraceparent rejects malformed input", () => {
  assert.equal(extractTraceparent(undefined), undefined);
  assert.equal(extractTraceparent("not-a-traceparent"), undefined);
  assert.equal(extractTraceparent(`00-short-${SPAN_ID}-01`), undefined);
});
