import Fastify from "fastify";
import { Kafka } from "kafkajs";
import { Pushgateway } from "prom-client";
import { SpanStatusCode } from "@opentelemetry/api";
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

  // Order matches Kafka_service.register (kafka_service.ml:167-177) exactly:
  // register_schema is fatal (let it throw, unguarded); set_subject_compatibility
  // is best-effort and must never block startup on a registry that doesn't
  // support it.
  const schemaId = await registerSchema(SCHEMA_REGISTRY_URL, TOPIC_NAME, ORDER_PLACED_SCHEMA);
  console.log(`[order-svc-ts] schema registered, id=${schemaId}`);
  try {
    await setSubjectCompatibility(SCHEMA_REGISTRY_URL, TOPIC_NAME);
  } catch (err) {
    console.warn(`[order-svc-ts] warn: could not set schema compatibility for ${TOPIC_NAME}: ${String(err)}`);
  }

  const kafka = new Kafka({ clientId: "order-svc-ts", brokers: KAFKA_BROKERS });
  const producer = kafka.producer();
  await producer.connect();

  const app = Fastify({ logger: false });

  // Sol convention: every request gets a metric, success or failure — mirrors
  // framework/sol-svc/lib/service.ml's dispatch wrapper, which records
  // metrics for every response generically rather than leaving it to each
  // handler to remember. A hook is the correct place for this in Fastify;
  // recording inline in the handler (an earlier version of this file did)
  // silently drops metrics for any request that throws.
  app.addHook("onResponse", async (req, reply) => {
    // sol-svc's dispatcher (service.ml:113-114) uses a fixed "unmatched"
    // label for any request that never matched a route — an unbounded,
    // caller-controlled path as a label value is a Prometheus cardinality
    // bomb under real internet traffic (scanners, retries with varying
    // paths). routeOptions is only set once Fastify has matched a route.
    const route = req.routeOptions?.url ?? "unmatched";
    const statusClass = `${Math.floor(reply.statusCode / 100)}xx`;
    requestsTotal.inc({ method: req.method, route, status_class: statusClass });
    requestDuration.observe({ method: req.method, route }, reply.elapsedTime / 1000);
  });

  // Internal error details (a Kafka publish failure, a stack trace) must
  // never reach an external caller verbatim — Fastify's default handler
  // serializes error.message straight into the response body otherwise.
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
  app.get("/metrics", async (_req, reply) => {
    reply.header("content-type", metricsRegister.contentType);
    return metricsRegister.metrics();
  });

  app.post(
    "/orders",
    {
      // Fastify's built-in AJV validation (ecosystem-covered, not a Sol
      // convention) — a malformed body (missing/wrong-typed fields) is
      // rejected with 400 before the handler ever runs, instead of being
      // silently coerced via `?? ""`/`?? 0` and published anyway.
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

    const span = tracer.startSpan("receive_order", { kind: SpanKind.PRODUCER });
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

      const message = {
        order_id: body.order_id,
        item: body.item,
        quantity: body.quantity,
        correlation_id: correlationId,
      };
      const wire = encodeWire(schemaId, message);

      // Unlike examples/local-demo/bin/demo.ml (which logs a Kafka publish
      // error but still returns 202), a publish failure here is allowed to
      // propagate and return 500 — telling the client an order succeeded
      // when the event never reached Kafka is a worse contract than the
      // demo script's convenience shortcut.
      await producer.send({
        topic: TOPIC_NAME,
        messages: [{ value: wire, headers: { traceparent } }],
      });

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

  const DRAIN_TIMEOUT_MS = 30_000; // matches sol-svc's default drain_timeout_s (service.ml)
  let shuttingDown = false;
  const shutdown = async () => {
    if (shuttingDown) return; // SIGTERM/SIGINT can both fire; don't drain twice concurrently
    shuttingDown = true;
    console.log("[order-svc-ts] draining...");
    if (pushInterval) clearInterval(pushInterval);
    // sol-svc races the drain against drain_timeout_s and force-cancels
    // (Drain_timeout, service.ml:290-303) rather than hanging forever on a
    // client holding a connection open — app.close() alone has no such bound.
    const drainTimeout = new Promise<void>((resolve) => {
      const t = setTimeout(() => {
        console.error("[order-svc-ts] drain timeout reached, forcing shutdown");
        resolve();
      }, DRAIN_TIMEOUT_MS);
      t.unref();
    });
    await Promise.race([app.close(), drainTimeout]);
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
