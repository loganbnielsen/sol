import Fastify from "fastify";
import { Kafka } from "kafkajs";
import { Pushgateway } from "prom-client";
import { randomBytes } from "node:crypto";

import { encodeWire, registerSchema, setSubjectCompatibility } from "./schemaRegistry.js";
import { makeLokiPusher } from "./loki.js";
import { initTracing, traceparentOf, SpanKind } from "./tracing.js";
import { makeSvcMetrics } from "./metrics.js";

const PORT = Number(process.env.PORT ?? 8080);
const KAFKA_BROKERS = (process.env.KAFKA_BROKERS ?? "localhost:9092").split(",");
const SCHEMA_REGISTRY_URL = process.env.SCHEMA_REGISTRY_URL ?? "http://localhost:8081";
const LOKI_URL = process.env.LOKI_URL;
const TEMPO_URL = process.env.TEMPO_URL;
const TOPIC_NAME = process.env.ORDERS_TOPIC ?? "sol-demo-ts-orders";

const ORDER_PLACED_SCHEMA = JSON.stringify({
  type: "object",
  properties: {
    order_id: { type: "string" },
    item: { type: "string" },
    quantity: { type: "integer" },
    correlation_id: { type: "string" },
  },
  required: ["order_id", "item", "quantity", "correlation_id"],
});

const log = makeLokiPusher(LOKI_URL, "order-svc-ts");
const { tracer, shutdown: shutdownTracing } = initTracing("order-svc-ts", TEMPO_URL);
const { register: metricsRegister, requestsTotal, requestDuration } = makeSvcMetrics();

async function main() {
  console.log(`[order-svc-ts] brokers=${KAFKA_BROKERS} registry=${SCHEMA_REGISTRY_URL} topic=${TOPIC_NAME}`);

  await setSubjectCompatibility(SCHEMA_REGISTRY_URL, TOPIC_NAME);
  const schemaId = await registerSchema(SCHEMA_REGISTRY_URL, TOPIC_NAME, ORDER_PLACED_SCHEMA);
  console.log(`[order-svc-ts] schema registered, id=${schemaId}`);

  const kafka = new Kafka({ clientId: "order-svc-ts", brokers: KAFKA_BROKERS });
  const producer = kafka.producer();
  await producer.connect();

  const app = Fastify({ logger: false });

  app.get("/healthz", async () => ({ status: "ok" }));
  app.get("/metrics", async (_req, reply) => {
    reply.header("content-type", metricsRegister.contentType);
    return metricsRegister.metrics();
  });

  app.post("/orders", async (req, reply) => {
    const start = process.hrtime.bigint();
    const body = req.body as { order_id?: string; item?: string; quantity?: number };
    const correlationId =
      (req.headers["x-correlation-id"] as string | undefined) ?? randomBytes(4).toString("hex");

    const span = tracer.startSpan("receive_order", { kind: SpanKind.PRODUCER });
    span.setAttribute("order_id", body.order_id ?? "");
    span.setAttribute("item", body.item ?? "");

    const traceparent = traceparentOf(span);
    log("info", "order received", {
      order_id: body.order_id ?? "",
      item: body.item ?? "",
      correlation_id: correlationId,
      trace_id: span.spanContext().traceId,
    });

    const message = {
      order_id: body.order_id ?? "",
      item: body.item ?? "",
      quantity: body.quantity ?? 0,
      correlation_id: correlationId,
    };
    const wire = encodeWire(schemaId, message);

    await producer.send({
      topic: TOPIC_NAME,
      messages: [{ value: wire, headers: { traceparent } }],
    });

    span.end();

    const durationS = Number(process.hrtime.bigint() - start) / 1e9;
    requestsTotal.inc({ method: "POST", route: "/orders", status_class: "2xx" });
    requestDuration.observe({ method: "POST", route: "/orders" }, durationS);

    reply.code(202);
    return { accepted: true };
  });

  await app.listen({ port: PORT, host: "0.0.0.0" });
  console.log(`[order-svc-ts] listening on :${PORT}`);

  // The local Prometheus container in this repo is configured to scrape
  // Pushgateway only (see platform/local/config/prometheus.yml) — matching
  // examples/local-demo's own local-run model, not the k8s-native path
  // where prometheus.io/scrape annotations hit /metrics directly. Push
  // periodically since, unlike the OCaml demo, this is a long-running
  // service rather than a one-shot binary.
  const pushgatewayUrl = process.env.PUSHGATEWAY_URL;
  const pushInterval = pushgatewayUrl
    ? setInterval(() => {
        new Pushgateway(pushgatewayUrl, {}, metricsRegister)
          .pushAdd({ jobName: "sol-demo-ts-order-svc" })
          .catch((err) => console.error(`[order-svc-ts] pushgateway push failed: ${String(err)}`));
      }, 3000)
    : undefined;

  const shutdown = async () => {
    console.log("[order-svc-ts] draining...");
    if (pushInterval) clearInterval(pushInterval);
    await app.close();
    await producer.disconnect();
    await shutdownTracing();
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((err) => {
  console.error("[order-svc-ts] fatal:", err);
  process.exit(1);
});
