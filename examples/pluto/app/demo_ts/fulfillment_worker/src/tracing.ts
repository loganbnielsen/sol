// Same OTel setup as order_svc; the consumer-side half of the hand-rolled
// propagation glue lives here — turning an inbound W3C traceparent header
// back into an OTel remote parent context, so "fulfill_order" nests under
// "receive_order" in Tempo the way examples/local-demo/bin/demo.ml's OCaml
// side does via Obs_trace.extract_from_headers.

import { NodeTracerProvider } from "@opentelemetry/sdk-trace-node";
import { BatchSpanProcessor } from "@opentelemetry/sdk-trace-base";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { Resource } from "@opentelemetry/resources";
import { ATTR_SERVICE_NAME } from "@opentelemetry/semantic-conventions";
import { trace, context, SpanKind, type SpanContext } from "@opentelemetry/api";

export function initTracing(serviceName: string, tempoUrl: string | undefined) {
  const exporter = tempoUrl
    ? new OTLPTraceExporter({ url: `${tempoUrl}/v1/traces` })
    : undefined;

  const provider = new NodeTracerProvider({
    resource: new Resource({ [ATTR_SERVICE_NAME]: serviceName }),
    spanProcessors: exporter ? [new BatchSpanProcessor(exporter)] : [],
  });
  provider.register();

  return {
    tracer: trace.getTracer(serviceName),
    shutdown: () => provider.shutdown(),
  };
}

export function parseTraceparent(value: string | undefined): SpanContext | undefined {
  if (!value) return undefined;
  const parts = value.split("-");
  if (parts.length !== 4) return undefined;
  const [, traceId, spanId, flags] = parts;
  if (traceId.length !== 32 || spanId.length !== 16) return undefined;
  // `parseInt(flags, 16) || 1` would incorrectly treat a legitimate
  // unsampled trace (flags "00" -> 0) as sampled, since 0 is falsy in JS.
  // Only fall back to sampled when the field genuinely failed to parse.
  const parsedFlags = parseInt(flags, 16);
  return { traceId, spanId, traceFlags: Number.isNaN(parsedFlags) ? 1 : parsedFlags, isRemote: true };
}

export function startChildSpan(
  tracer: ReturnType<typeof trace.getTracer>,
  name: string,
  parent: SpanContext | undefined
) {
  const parentCtx = parent ? trace.setSpanContext(context.active(), parent) : context.active();
  return tracer.startSpan(name, { kind: SpanKind.CONSUMER }, parentCtx);
}
