import { createServer } from "node:http";
import { Kafka } from "kafkajs";
import { Pushgateway } from "prom-client";
import type { SpanContext } from "@opentelemetry/api";

import {
  ACK,
  kafkaRetryRelay,
  provisionRelayTopics,
  retry as retryOutcome,
  runRetryRelayConsumer,
  wireCrashListener,
  wrapEachRetryableMessage,
  type Outcome,
  type RetryStrategy,
} from "@sol-fab/kafka";
import { makeLokiPusher } from "@sol-fab/obs";
import { runWorker } from "@sol-fab/worker";
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

// Application *policy*, not Kafka mechanics: a DB failure is retryable, and
// the retry budget is a product decision. How `Retry` is routed, what the
// retry/DLQ topics are called, and when an offset may commit are @sol-fab/kafka's
// job — the demo never names a header or a topic here.
const RETRY_STRATEGY: RetryStrategy = {
  kind: "retry-topics",
  policy: { baseDelayS: 1, maxDelayS: 60, maxAttempts: 5, jitterRatio: 0.1 },
};

const log = makeLokiPusher(LOKI_URL, "fulfillment-worker-ts");
const { tracer, shutdown: shutdownTracing } = initTracing("fulfillment-worker-ts", TEMPO_URL);
const { register: metricsRegister, messagesTotal, decodeErrorsTotal, messageDuration } = makeWorkerMetrics();

// The application handler, shared by the source path and the retry path: it
// returns Sol outcomes and knows nothing about retry topics, headers, or
// offset transfer.
async function handleOrder(
  order: ReturnType<typeof decodeOrderPlaced>,
  traceContext: SpanContext | undefined,
  attempt: number,
): Promise<Outcome> {
  const start = process.hrtime.bigint();
  const span = startChildSpan(tracer, "fulfill_order", traceContext);
  try {
    log("info", "fulfilling order", {
      order_id: order.order_id,
      item: order.item,
      quantity: String(order.quantity),
      attempt: String(attempt),
    });

    if (db) {
      try {
        await db.insertFulfilled(order);
      } catch (err) {
        // A downstream DB failure is retryable on an otherwise-valid message.
        // "retry" is worker.ml's vocabulary for exactly this; decode failures
        // are the separate counter wired below.
        messagesTotal.inc({ status: "retry" });
        return retryOutcome(`db: ${String(err)}`);
      }
    }

    console.log(`[worker] fulfilled  order=${order.order_id}  item=${order.item}`);
    messagesTotal.inc({ status: "ok" });
    return ACK;
  } finally {
    span.end();
    messageDuration.observe(Number(process.hrtime.bigint() - start) / 1e9);
  }
}

let db: Awaited<ReturnType<typeof makeDb>> | undefined;

async function main() {
  db = POSTGRES_URL ? await makeDb(POSTGRES_URL) : undefined;
  if (!db) console.log("[fulfillment-worker-ts] POSTGRES_URL not set — skipping DB storage");

  const kafka = new Kafka({ clientId: "fulfillment-worker-ts", brokers: KAFKA_BROKERS });

  // The relay owns the retry topology: the demo *asks* for retry-topic delivery
  // and @sol-fab/kafka provisions, publishes, and consumes the retry/DLQ topics.
  const producer = kafka.producer();
  await producer.connect();
  const relay = kafkaRetryRelay(producer);
  await provisionRelayTopics({ kafka, sourceTopic: TOPIC_NAME, groupId: GROUP_ID });

  const consumer = kafka.consumer({ groupId: GROUP_ID });
  // @sol-fab/kafka's wireCrashListener encodes Sol's exit policy: kafkajs already
  // self-heals from retriable errors (payload.restart=true, rescheduling
  // start() itself after a backoff) -- only exit when kafkajs itself has given
  // up, so k8s restarts the pod instead of it quietly stopping progress.
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

  const onDecodeError = (err: unknown) => {
    console.error(`[worker] rejected message: ${String(err)}`);
    log("error", "rejected message", { error: String(err) });
  };

  // Source path: decode + handle, expressing retry via the configured strategy.
  await consumer.run({
    eachMessage: wrapEachRetryableMessage({
      decode: decodeOrderPlaced,
      decodeErrorCounter: decodeErrorsTotal,
      onDecodeError,
      retryStrategy: RETRY_STRATEGY,
      groupId: GROUP_ID,
      sourceTopic: TOPIC_NAME,
      relay,
      handler: ({ message, traceContext, attempt }) => handleOrder(message, traceContext, attempt),
    }),
  });

  // Retry path: the same application handler, re-run when a retry record comes
  // due. @sol-fab/kafka owns the delayed consumption and the offset transfer.
  const relayConsumer = await runRetryRelayConsumer({
    kafka,
    sourceTopic: TOPIC_NAME,
    groupId: GROUP_ID,
    retryStrategy: RETRY_STRATEGY,
    decode: decodeOrderPlaced,
    relay,
    onDecodeError,
    handler: ({ message, traceContext, attempt }) => handleOrder(message, traceContext, attempt),
  });

  const pushgatewayUrl = process.env.PUSHGATEWAY_URL;
  const pushInterval = pushgatewayUrl
    ? setInterval(() => {
        new Pushgateway(pushgatewayUrl, {}, metricsRegister)
          .pushAdd({ jobName: "sol-demo-ts-fulfillment-worker" })
          .catch((err) => console.error(`[fulfillment-worker-ts] pushgateway push failed: ${String(err)}`));
      }, 3000)
    : undefined;

  // @sol-fab/worker owns the lifecycle contract (idempotent SIGTERM/SIGINT,
  // an unbounded drain -- sol-worker's worker.mli has no drain_timeout_s,
  // unlike sol-svc) that framework/ocaml/sol-worker/lib/worker.ml defines; this
  // app only supplies what to drain and what to close afterwards.
  runWorker({
    drain: async () => {
      await consumer.disconnect();
      await relayConsumer.disconnect();
    },
    onDrainStart: () => {
      console.log("[fulfillment-worker-ts] draining...");
      if (pushInterval) clearInterval(pushInterval);
    },
    shutdownHooks: [
      () => producer.disconnect(),
      async () => {
        metricsServer.close();
      },
      async () => {
        if (db) await db.close();
      },
      () => shutdownTracing(),
    ],
  });
}

main().catch((err) => {
  console.error("[fulfillment-worker-ts] fatal:", err);
  process.exit(1);
});
