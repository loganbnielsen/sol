import { createServer } from "node:http";
import { Kafka } from "kafkajs";
import { Pushgateway } from "@prometheus-io/client";
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

function requiredEnv(name: string): string {
  const value = setting(name);
  if (!value) {
    throw new Error(`${name} is not set: state the Kafka substrate addresses explicitly`);
  }
  return value;
}

const KAFKA_BROKERS = requiredEnv("KAFKA_BROKERS").split(",");
const TOPIC_NAME = setting("ORDERS_TOPIC") ?? "sol-demo-ts-orders";
const GROUP_ID = "sol-demo-ts-fulfillment-worker";

const METRICS_PORT = intEnv("METRICS_PORT", 9090);
const LOKI_URL = setting("LOKI_URL");
const TEMPO_URL = setting("TEMPO_URL");
const POSTGRES_URL = setting("POSTGRES_URL");

const RETRY_STRATEGY: RetryStrategy = {
  kind: "retry-topics",
  policy: { baseDelayS: 1, maxDelayS: 60, maxAttempts: 5, jitterRatio: 0.1 },
};

const log = makeLokiPusher(LOKI_URL, "fulfillment-worker-ts");
const { tracer, shutdown: shutdownTracing } = initTracing("fulfillment-worker-ts", TEMPO_URL);
const { register: metricsRegister, messagesTotal, decodeErrorsTotal, messageDuration } = makeWorkerMetrics();

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

  const producer = kafka.producer();
  await producer.connect();
  const relay = kafkaRetryRelay(producer);
  await provisionRelayTopics({ kafka, sourceTopic: TOPIC_NAME, groupId: GROUP_ID });

  const consumer = kafka.consumer({ groupId: GROUP_ID });
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
    console.error(`[worker] undecodable message, dead-lettered: ${String(err)}`);
    log("error", "undecodable message, dead-lettered", { error: String(err) });
  };

  await consumer.run({
    eachMessage: wrapEachRetryableMessage({
      decode: decodeOrderPlaced,
      decodeErrorCounter: decodeErrorsTotal,
      onDecodeError,
      decodeErrorPolicy: "route-to-dlq",
      retryStrategy: RETRY_STRATEGY,
      groupId: GROUP_ID,
      sourceTopic: TOPIC_NAME,
      relay,
      handler: ({ message, traceContext, attempt }) => handleOrder(message, traceContext, attempt),
    }),
  });

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

  const pushgatewayUrl = setting("PUSHGATEWAY_URL");
  const pushInterval = pushgatewayUrl
    ? setInterval(() => {
        new Pushgateway(pushgatewayUrl, {}, metricsRegister)
          .pushAdd({ jobName: "sol-demo-ts-fulfillment-worker" })
          .catch((err) => console.error(`[fulfillment-worker-ts] pushgateway push failed: ${String(err)}`));
      }, 3000)
    : undefined;

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
