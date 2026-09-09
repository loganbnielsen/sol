import { test } from "node:test";
import assert from "node:assert/strict";
import { extractTraceparent } from "../src/tracing.js";

// Bug 5: W3C traceparent flags-byte handling. FEAT-033's port used
// `parseInt(flags, 16) || 1`, which incorrectly coerces a legitimate
// unsampled trace (flags "00" -> 0) into "sampled" (1), since 0 is falsy
// in JS. Only a genuine parse failure (NaN) should fall back to 1.

const TRACE_ID = "0af7651916cd43dd8448eb211c80319c";
const SPAN_ID = "b7ad6b7169203331";

test("extractTraceparent: preserves flags=00 (unsampled) as 0, not falsy-coerced to 1", () => {
  const ctx = extractTraceparent(`00-${TRACE_ID}-${SPAN_ID}-00`);
  assert.ok(ctx);
  assert.equal(ctx.traceFlags, 0);
});

test("extractTraceparent: preserves flags=01 (sampled) as 1", () => {
  const ctx = extractTraceparent(`00-${TRACE_ID}-${SPAN_ID}-01`);
  assert.ok(ctx);
  assert.equal(ctx.traceFlags, 1);
});

test("extractTraceparent: falls back to sampled only on genuine parse failure", () => {
  const ctx = extractTraceparent(`00-${TRACE_ID}-${SPAN_ID}-zz`);
  assert.ok(ctx);
  assert.equal(ctx.traceFlags, 1);
});

test("extractTraceparent: returns undefined for missing header", () => {
  assert.equal(extractTraceparent(undefined), undefined);
});

test("extractTraceparent: returns undefined for malformed header shape", () => {
  assert.equal(extractTraceparent("not-a-traceparent"), undefined);
  assert.equal(extractTraceparent(`00-short-${SPAN_ID}-01`), undefined);
});
