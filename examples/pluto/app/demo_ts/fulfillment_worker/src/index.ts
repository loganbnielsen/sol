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
const { register: metricsRegister, messagesTotal, decodeErrorsTotal, messageDuration } = makeWorkerMetrics();

async function main() {
  const db = POSTGRES_URL ? await makeDb(POSTGRES_URL) : undefined;
  if (!db) console.log("[fulfillment-worker-ts] POSTGRES_URL not set — skipping DB storage");

  const kafka = new Kafka({ clientId: "fulfillment-worker-ts", brokers: KAFKA_BROKERS });
  const consumer = kafka.consumer({ groupId: GROUP_ID });
  // Without this, an eachMessage error that exhausts kafkajs's internal
  // retries stops the consumer silently — no crash, no exit, just a worker
  // that quietly stops making progress. Fail loudly instead so an operator
  // (or k8s) notices and restarts the pod, rather than a zombie process
  // that still passes /healthz-equivalent liveness checks.
  consumer.on(consumer.events.CRASH, ({ payload }) => {
    console.error(`[fulfillment-worker-ts] consumer crashed: ${String(payload.error)}`);
    process.exit(1);
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

  await consumer.run({
    eachMessage: async ({ message }) => {
      const start = process.hrtime.bigint();
      const traceparent = message.headers?.traceparent?.toString();
      const parent = parseTraceparent(traceparent);
      const span = startChildSpan(tracer, "fulfill_order", parent);

      try {
        // Decode/validation failure vs. downstream (DB) failure are
        // different failure classes and must not share a status label or
        // a swallow-vs-retry policy: a malformed message should never be
        // retried (it will never become valid), but a transient Postgres
        // error on an otherwise-valid message should be retried by kafkajs
        // rather than silently treated as "rejected" and offset-committed.
        let order;
        try {
          if (!message.value) throw new Error("tombstone (message has no value)");
          const { json } = decodeWire(message.value);
          order = decodeOrderPlaced(json);
        } catch (err) {
          // Sol convention: decode/validation failure is a rejection, not a
          // crash, and is NOT a messages_total status — real worker.ml never
          // routes a decode failure through its handler at all
          // (kafka_service_intf.ml's wrap_on_decode_error intercepts it
          // earlier), so it gets its own counter instead of an invented
          // status label value.
          console.error(`[worker] rejected message: ${String(err)}`);
          log("error", "rejected message", { error: String(err) });
          decodeErrorsTotal.inc();
          return;
        }

        log("info", "fulfilling order", {
          order_id: order.order_id,
          item: order.item,
          quantity: String(order.quantity),
        });

        try {
          if (db) await db.insertFulfilled(order);
        } catch (err) {
          // "error" is worker.ml's real vocabulary for "handler failed on an
          // otherwise-valid message" (W.handle returning Error, worker.ml:121-124)
          // — decode/validation failures are the only thing split out
          // separately (see decodeErrorsTotal above).
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
