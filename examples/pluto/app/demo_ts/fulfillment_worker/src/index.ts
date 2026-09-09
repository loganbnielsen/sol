import { createServer } from "node:http";
import { Kafka } from "kafkajs";
import { Pushgateway } from "prom-client";

import { wrapEachMessage, wireCrashListener } from "@sol/kafka";
import { makeLokiPusher } from "@sol/obs";
import { decodeOrderPlaced } from "./wire.js";
import { initTracing, startChildSpan } from "./tracing.js";
import { makeWorkerMetrics } from "./metrics.js";
import { makeDb } from "./db.js";

const KAFKA_BROKERS = (process.env.KAFKA_BROKERS ?? "localhost:9092").split(",");
const TOPIC_NAME = process.env.ORDERS_TOPIC ?? "sol-demo-ts-orders";
const GROUP_ID = "sol-demo-ts-fulfillment-worker";
// Same defensive fallback as order_svc/src/index.ts's intEnv — a malformed
// value should fall back to the default, not silently become NaN and
// crash the metrics server's .listen() at startup.
function intEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  const n = Number(raw);
  return Number.isFinite(n) ? n : fallback;
}

const METRICS_PORT = intEnv("METRICS_PORT", 9090);
const LOKI_URL = process.env.LOKI_URL;
const TEMPO_URL = process.env.TEMPO_URL;
const POSTGRES_URL = process.env.POSTGRES_URL;

const log = makeLokiPusher(LOKI_URL, "fulfillment-worker-ts");
const { tracer, shutdown: shutdownTracing } = initTracing("fulfillment-worker-ts", TEMPO_URL);
const { register: metricsRegister, messagesTotal, decodeErrorsTotal, messageDuration } = makeWorkerMetrics();

async function main() {
  const db = POSTGRES_URL ? await makeDb(POSTGRES_URL) : undefined;
  if (!db) console.log("[fulfillment-worker-ts] POSTGRES_URL not set — skipping DB storage");

  const kafka = new Kafka({ clientId: "fulfillment-worker-ts", brokers: KAFKA_BROKERS });
  const consumer = kafka.consumer({ groupId: GROUP_ID });
  // @sol/kafka's wireCrashListener encodes Sol's exit policy: kafkajs
  // already self-heals from retriable errors (payload.restart=true,
  // rescheduling start() itself after a backoff) -- only exit when kafkajs
  // itself has given up, so k8s restarts the pod instead of it quietly
  // stopping progress forever.
  wireCrashListener(consumer, {
    onCrash: (error) => console.error(`[fulfillment-worker-ts] consumer crashed: ${String(error)}`),
  });
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

  // @sol/kafka's wrapEachMessage encodes Sol's decode/reject/retry policy:
  // a decode/validation failure is a rejection (never retried, counted on
  // decodeErrorsTotal, never reaches the handler below); a handler failure
  // on an otherwise-valid message rethrows so kafkajs retries it. The two
  // failure classes can no longer be conflated by construction.
  await consumer.run({
    eachMessage: wrapEachMessage({
      decode: decodeOrderPlaced,
      decodeErrorCounter: decodeErrorsTotal,
      onDecodeError: (err) => {
        console.error(`[worker] rejected message: ${String(err)}`);
        log("error", "rejected message", { error: String(err) });
      },
      handler: async ({ message: order, traceContext }) => {
        const start = process.hrtime.bigint();
        const span = startChildSpan(tracer, "fulfill_order", traceContext);
        try {
          log("info", "fulfilling order", {
            order_id: order.order_id,
            item: order.item,
            quantity: String(order.quantity),
          });

          try {
            if (db) await db.insertFulfilled(order);
          } catch (err) {
            // "error" is worker.ml's real vocabulary for "handler failed on
            // an otherwise-valid message" — decode/validation failures are
            // the only thing split out separately (decodeErrorsTotal above).
            messagesTotal.inc({ status: "error" });
            throw err;
          }

          console.log(`[worker] fulfilled  order=${order.order_id}  item=${order.item}`);
          messagesTotal.inc({ status: "ok" });
        } finally {
          span.end();
          messageDuration.observe(Number(process.hrtime.bigint() - start) / 1e9);
        }
      },
    }),
  });

  const pushgatewayUrl = process.env.PUSHGATEWAY_URL;
  const pushInterval = pushgatewayUrl
    ? setInterval(() => {
        new Pushgateway(pushgatewayUrl, {}, metricsRegister)
          .pushAdd({ jobName: "sol-demo-ts-fulfillment-worker" })
          .catch((err) => console.error(`[fulfillment-worker-ts] pushgateway push failed: ${String(err)}`));
      }, 3000)
    : undefined;

  let shuttingDown = false;
  const shutdown = async () => {
    if (shuttingDown) return; // SIGTERM/SIGINT can both fire; don't drain twice concurrently
    shuttingDown = true;
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
