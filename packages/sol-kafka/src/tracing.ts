import type { Span, SpanContext } from "@opentelemetry/api";

/**
 * OpenTelemetry has no official carrier for Kafka (unlike HTTP/gRPC) -- this
 * glue has to exist somewhere. FEAT-033's hand-rolled port got the span
 * linkage right but the flags byte wrong twice: the producer hardcoded "01"
 * regardless of actual sampled state, and the consumer's parser used
 * `parseInt(flags, 16) || 1`, which incorrectly treats a legitimate
 * unsampled trace (flags "00" -> 0) as sampled, since 0 is falsy in JS.
 *
 * TEMPORARY HOME: FEAT-035 (@sol/obs) is the intended long-term owner of
 * general tracing/metrics primitives -- this ticket's own non-goals section
 * anticipates @sol/kafka depending on @sol/obs for exactly this. Since
 * @sol/obs doesn't exist yet as of this pass, these two functions live here
 * for now; move them to @sol/obs and re-export (or depend on it directly)
 * once it's built, rather than duplicating this logic in two packages.
 */

/** Producer side: format a span's context as a W3C traceparent header value. */
export function traceparentOf(span: Span): string {
  const ctx = span.spanContext();
  const flags = ctx.traceFlags.toString(16).padStart(2, "0");
  return `00-${ctx.traceId}-${ctx.spanId}-${flags}`;
}

/** Consumer side: parse an inbound traceparent header back into a remote SpanContext. */
export function extractTraceparent(value: string | undefined): SpanContext | undefined {
  if (!value) return undefined;
  const parts = value.split("-");
  if (parts.length !== 4) return undefined;
  const [, traceId, spanId, flags] = parts;
  if (traceId.length !== 32 || spanId.length !== 16) return undefined;
  // Only fall back to sampled (1) when the field genuinely failed to parse
  // (NaN) -- never let a legitimate 0 (unsampled) fall through `|| 1`.
  const parsedFlags = parseInt(flags, 16);
  return { traceId, spanId, traceFlags: Number.isNaN(parsedFlags) ? 1 : parsedFlags, isRemote: true };
}
