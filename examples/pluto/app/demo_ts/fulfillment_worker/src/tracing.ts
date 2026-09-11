// Same OTel setup as order_svc; SDK bootstrap is app-specific wiring. The
// W3C traceparent glue (turning an inbound header back into an OTel remote
// parent context) has moved to @sol/obs — the shared owner now that this
// is a real dogfooded consumer, not a one-off hand port (see FEAT-038).
// startChildSpan stays here: it's this service's own OTel usage pattern
// (nest "fulfill_order" under the producer's remote context), not a Sol
// naming/shape convention.

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

export function startChildSpan(
  tracer: ReturnType<typeof trace.getTracer>,
  name: string,
  parent: SpanContext | undefined
) {
  const parentCtx = parent ? trace.setSpanContext(context.active(), parent) : context.active();
  return tracer.startSpan(name, { kind: SpanKind.CONSUMER }, parentCtx);
}
