import Fastify from "fastify";
import { Kafka } from "kafkajs";
import { Pushgateway } from "@prometheus-io/client";
import { context, propagation, SpanStatusCode } from "@opentelemetry/api";
import { randomBytes } from "node:crypto";

import { kafkaConfigFromEnv, registerTopic, publish, type TopicContract } from "@sol-fab/kafka";
import { traceparentOf, routeLabel, statusClassOf, makeLokiPusher } from "@sol-fab/obs";
import { runService, type ServiceLifecycle } from "@sol-fab/svc";
import { initTracing, SpanKind } from "./tracing.js";
import { makeSvcMetrics } from "./metrics.js";

function setting(name: string): string | undefined {
  const value = process.env[name]?.trim();
  return value ? value : undefined;
}

function intEnv(name: string, fallback: number): number {
  const raw = setting(name);
  if (raw === undefined) return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n)) {
    throw new Error(`${name}=${JSON.stringify(raw)} is not a number`);
  }
  return n;
}

const PORT = intEnv("PORT", 8080);
function requiredEnv(name: string): string {
  const value = setting(name);
  if (!value) {
    throw new Error(`${name} is not set: state the Kafka substrate addresses explicitly`);
  }
  return value;
}

const KAFKA_ENV = kafkaConfigFromEnv();
const SCHEMA_REGISTRY_URL = requiredEnv("SCHEMA_REGISTRY_URL");
const LOKI_URL = setting("LOKI_URL");
const TEMPO_URL = setting("TEMPO_URL");
const TOPIC_NAME = setting("ORDERS_TOPIC") ?? "sol-demo-ts-orders";
const PARTITIONS = 3;

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

interface OrderPlaced {
  order_id: string;
  item: string;
  quantity: number;
  correlation_id: string;
}

const ORDER_PLACED: TopicContract<OrderPlaced> = {
  name: TOPIC_NAME,
  schema: ORDER_PLACED_SCHEMA,
  partitions: PARTITIONS,
  key: (order) => order.order_id,
};

const log = makeLokiPusher({
  lokiUrl: LOKI_URL,
  service: "order-svc-ts",
  labels: { team: "demo_ts" },
});
const { tracer, shutdown: shutdownTracing } = initTracing("order-svc-ts", TEMPO_URL);
const { register: metricsRegister, requestsTotal, requestDuration } = makeSvcMetrics();

async function main() {
  console.log(`[order-svc-ts] brokers=${KAFKA_ENV.brokers} registry=${SCHEMA_REGISTRY_URL} topic=${TOPIC_NAME}`);

  const kafka = new Kafka({ clientId: "order-svc-ts", ...KAFKA_ENV });

  const topic = await registerTopic({
    kafka,
    registryUrl: SCHEMA_REGISTRY_URL,
    contract: ORDER_PLACED,
  });
  console.log(`[order-svc-ts] schema registered, id=${topic.schemaId}`);

  const producer = kafka.producer();
  await producer.connect();

  const app = Fastify({ logger: false });

  let lifecycle: ServiceLifecycle | undefined;

  app.addHook("onResponse", async (req, reply) => {
    const route = routeLabel(req.routeOptions?.url);
    const statusClass = statusClassOf(reply.statusCode);
    requestsTotal.inc({ method: req.method, route, status_class: statusClass });
    requestDuration.observe({ method: req.method, route }, reply.elapsedTime / 1000);
  });

  app.setErrorHandler((err, _req, reply) => {
    console.error(`[order-svc-ts] request error: ${String(err)}`);
    const status = (err as { statusCode?: number }).statusCode ?? 500;
    if (status >= 500) {
      reply.code(status).send({ error: "internal server error" });
    } else {
      reply.code(status).send({ error: (err as Error).message });
    }
  });

  app.get("/healthz", async () => ({ status: "ok" }));
  app.get("/readyz", async (_req, reply) => {
    if (lifecycle?.isReady() ?? true) return { status: "ready" };
    return reply.code(503).send({ status: "shutting down" });
  });
  app.get("/metrics", async (_req, reply) => {
    reply.header("content-type", metricsRegister.contentType);
    return metricsRegister.metrics();
  });

  app.post(
    "/orders",
    {
      schema: {
        body: {
          type: "object",
          required: ["order_id", "item", "quantity"],
          properties: {
            order_id: { type: "string", minLength: 1 },
            item: { type: "string", minLength: 1 },
            quantity: { type: "integer" },
          },
        },
      },
    },
    async (req, reply) => {
    const body = req.body as { order_id: string; item: string; quantity: number };
    const correlationId =
      (req.headers["x-correlation-id"] as string | undefined) ?? randomBytes(4).toString("hex");

    const parentContext = propagation.extract(context.active(), req.headers);
    const span = tracer.startSpan(
      "receive_order",
      { kind: SpanKind.PRODUCER },
      parentContext,
    );
    try {
      span.setAttribute("order_id", body.order_id);
      span.setAttribute("item", body.item);

      const traceparent = traceparentOf(span);
      log("info", "order received", {
        order_id: body.order_id,
        item: body.item,
        correlation_id: correlationId,
        trace_id: span.spanContext().traceId,
      });

      const message: OrderPlaced = {
        order_id: body.order_id,
        item: body.item,
        quantity: body.quantity,
        correlation_id: correlationId,
      };
      await publish(producer, topic, message, { headers: { traceparent } });

      reply.code(202);
      return { accepted: true };
    } catch (err) {
      span.recordException(err as Error);
      span.setStatus({ code: SpanStatusCode.ERROR });
      throw err;
    } finally {
      span.end();
    }
    }
  );

  await app.listen({ port: PORT, host: "0.0.0.0" });
  console.log(`[order-svc-ts] listening on :${PORT}`);

  const pushgatewayUrl = setting("PUSHGATEWAY_URL");
  const pushInterval = pushgatewayUrl
    ? setInterval(() => {
        new Pushgateway(pushgatewayUrl, {}, metricsRegister)
          .pushAdd({ jobName: "sol-demo-ts-order-svc" })
          .catch((err) => console.error(`[order-svc-ts] pushgateway push failed: ${String(err)}`));
      }, 3000)
    : undefined;

  lifecycle = runService({
    drain: () => app.close(),
    onDrainStart: () => {
      console.log("[order-svc-ts] draining...");
      if (pushInterval) clearInterval(pushInterval);
    },
    shutdownHooks: [() => log.flush(), () => producer.disconnect(), () => shutdownTracing()],
  });
}

main().catch((err) => {
  console.error("[order-svc-ts] fatal:", err);
  process.exit(1);
});
