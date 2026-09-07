import { createServer } from "node:http";
import { Kafka } from "kafkajs";
import { Pushgateway } from "prom-client";

import { decodeWire, decodeOrderPlaced } from "./wire.js";
import { makeLokiPusher } from "./loki.js";
import { initTracing, parseTraceparent, startChildSpan } from "./tracing.js";
import { makeWorkerMetrics } from "./metrics.js";
import { makeDb } from "./db.js";

const KAFKA_BROKERS = (process.env.KAFKA_BROKERS ?? "localhost:9092").split(",");
const TOPIC_NAME = process.env.ORDERS_TOPIC ?? "sol-demo-ts-orders";
const GROUP_ID = "sol-demo-ts-fulfillment-worker";
const METRICS_PORT = Number(process.env.METRICS_PORT ?? 9090);
const LOKI_URL = process.env.LOKI_URL;
const TEMPO_URL = process.env.TEMPO_URL;
const POSTGRES_URL = process.env.POSTGRES_URL;

const log = makeLokiPusher(LOKI_URL, "fulfillment-worker-ts");
const { tracer, shutdown: shutdownTracing } = initTracing("fulfillment-worker-ts", TEMPO_URL);
const { register: metricsRegister, messagesTotal, messageDuration } = makeWorkerMetrics();

async function main() {
  const db = POSTGRES_URL ? await makeDb(POSTGRES_URL) : undefined;
  if (!db) console.log("[fulfillment-worker-ts] POSTGRES_URL not set — skipping DB storage");

  const kafka = new Kafka({ clientId: "fulfillment-worker-ts", brokers: KAFKA_BROKERS });
  const consumer = kafka.consumer({ groupId: GROUP_ID });
  await consumer.connect();
  await consumer.subscribe({ topic: TOPIC_NAME, fromBeginning: false });

  const metricsServer = createServer((req, res) => {
    if (req.url === "/metrics") {
      metricsRegister.metrics().then((body) => {
        res.writeHead(200, { "content-type": metricsRegister.contentType });
        res.end(body);
      });
      return;
    }
    res.writeHead(404);
    res.end();
  });
  metricsServer.listen(METRICS_PORT, () => {
    console.log(`[fulfillment-worker-ts] metrics on :${METRICS_PORT}`);
  });

  await consumer.run({
    eachMessage: async ({ message }) => {
      const start = process.hrtime.bigint();
      const traceparent = message.headers?.traceparent?.toString();
      const parent = parseTraceparent(traceparent);
      const span = startChildSpan(tracer, "fulfill_order", parent);

      try {
        if (!message.value) throw new Error("tombstone (message has no value)");
        const { json } = decodeWire(message.value);
        const order = decodeOrderPlaced(json);

        log("info", "fulfilling order", {
          order_id: order.order_id,
          item: order.item,
          quantity: String(order.quantity),
        });

        if (db) await db.insertFulfilled(order);

        console.log(`[worker] fulfilled  order=${order.order_id}  item=${order.item}`);
        messagesTotal.inc({ status: "ok" });
      } catch (err) {
        // Sol convention: decode/validation failure is a rejection, not a
        // crash — mirrors kafka_service_retry_topics.ml's decode-error path.
        console.error(`[worker] rejected message: ${String(err)}`);
        log("error", "rejected message", { error: String(err) });
        messagesTotal.inc({ status: "decode_error" });
      } finally {
        span.end();
        messageDuration.observe(Number(process.hrtime.bigint() - start) / 1e9);
      }
    },
  });

  const pushgatewayUrl = process.env.PUSHGATEWAY_URL;
  const pushInterval = pushgatewayUrl
    ? setInterval(() => {
        new Pushgateway(pushgatewayUrl, {}, metricsRegister)
          .pushAdd({ jobName: "sol-demo-ts-fulfillment-worker" })
          .catch((err) => console.error(`[fulfillment-worker-ts] pushgateway push failed: ${String(err)}`));
      }, 3000)
    : undefined;

  const shutdown = async () => {
    console.log("[fulfillment-worker-ts] draining...");
    if (pushInterval) clearInterval(pushInterval);
    await consumer.disconnect();
    metricsServer.close();
    if (db) await db.close();
    await shutdownTracing();
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((err) => {
  console.error("[fulfillment-worker-ts] fatal:", err);
  process.exit(1);
});
