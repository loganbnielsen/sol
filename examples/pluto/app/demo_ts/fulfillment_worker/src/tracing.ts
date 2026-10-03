import { NodeTracerProvider } from "@opentelemetry/sdk-trace-node";
import { BatchSpanProcessor } from "@opentelemetry/sdk-trace-base";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { resourceFromAttributes } from "@opentelemetry/resources";
import { trace, context, SpanKind, type SpanContext } from "@opentelemetry/api";

import { resourceAttributes } from "@sol-fab/obs";

export function initTracing(serviceName: string, tempoUrl: string | undefined) {
  const exporter = tempoUrl
    ? new OTLPTraceExporter({ url: `${tempoUrl}/v1/traces` })
    : undefined;

  const provider = new NodeTracerProvider({
    resource: resourceFromAttributes(resourceAttributes(serviceName)),
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
