// OpenTelemetry gives us spans + OTLP export "for free" (the ecosystem
// library, not a Sol convention). What's hand-rolled here is Sol-specific:
// OTel has no built-in notion of "propagate a trace onto a Kafka message" —
// that only exists for HTTP/gRPC carriers in the ecosystem packages. Writing
// the W3C traceparent string onto a Kafka header, and continuing it on the
// consumer side, is exactly the kind of glue a `@sol/obs`-for-TS package
// would want to absorb.

import { NodeTracerProvider } from "@opentelemetry/sdk-trace-node";
import { BatchSpanProcessor } from "@opentelemetry/sdk-trace-base";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { Resource } from "@opentelemetry/resources";
import { ATTR_SERVICE_NAME } from "@opentelemetry/semantic-conventions";
import { trace, SpanKind, type Span } from "@opentelemetry/api";

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

/** Sol convention: format a span's context as a W3C traceparent header value. */
export function traceparentOf(span: Span): string {
  const ctx = span.spanContext();
  const flags = ctx.traceFlags.toString(16).padStart(2, "0");
  return `00-${ctx.traceId}-${ctx.spanId}-${flags}`;
}

export { SpanKind };
