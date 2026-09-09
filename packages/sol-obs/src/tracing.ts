import type { Span, SpanContext } from "@opentelemetry/api";

/**
 * OpenTelemetry has no official carrier for any Sol-internal transport
 * (Kafka, or a future non-HTTP transport) -- this glue has to exist
 * somewhere, and it's Sol-specific regardless of transport, so it lives
 * here rather than duplicated per-transport package.
 *
 * FEAT-033's hand-rolled port got the span linkage right but the flags byte
 * wrong twice: the producer hardcoded "01" regardless of actual sampled
 * state, and the consumer's parser used `parseInt(flags, 16) || 1`, which
 * incorrectly treats a legitimate unsampled trace (flags "00" -> 0) as
 * sampled, since 0 is falsy in JS.
 *
 * @sol/kafka (FEAT-034) originally carried a copy of these two functions
 * with a comment anticipating this move -- once @sol/kafka can depend on
 * @sol/obs, it should import these from here instead of its own copy.
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
