import { createServer } from "node:http";
import { Kafka } from "kafkajs";
import { Pushgateway } from "@prometheus-io/client";
import type { SpanContext } from "@opentelemetry/api";

import {
  ACK,
  connectTopic,
  fail,
  kafkaConfigFromEnv,
  publish,
  provisionDlqTopic,
  wireCrashListener,
  wrapEachMessage,
  type Outcome,
} from "@sol-fab/kafka";
import { runJobs } from "@sol-fab/jobs";
import { makeLokiPusher } from "@sol-fab/obs";
import { runRelay } from "@sol-fab/outbox";
import { runWorker } from "@sol-fab/worker";
import { ORDER_FULFILLED } from "@demo-ts/contract";
import { decodeOrderFulfilled, decodeOrderPlaced } from "./wire.js";
import { initTracing, startChildSpan } from "./tracing.js";
import { makeWorkerMetrics } from "./metrics.js";
import { makeDb } from "./db.js";
import { makeConfirmationJobs } from "./jobs.js";
import { fulfillOrder } from "./fulfill.js";

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

function requiredRegistry(): string {
  const value = setting("SCHEMA_REGISTRY_URL");
  if (!value) {
    throw new Error("SCHEMA_REGISTRY_URL is not set: the outbox relay publishes through the registered contract");
  }
  return value;
}

const KAFKA_ENV = kafkaConfigFromEnv();
const TOPIC_NAME = setting("ORDERS_TOPIC") ?? "sol-demo-ts-orders";
const GROUP_ID = "sol-demo-ts-fulfillment-worker";
const PARTITIONS = 3;

const METRICS_PORT = intEnv("METRICS_PORT", 9090);
const LOKI_URL = setting("LOKI_URL");
const TEMPO_URL = setting("TEMPO_URL");
const POSTGRES_URL = setting("POSTGRES_URL");

const log = makeLokiPusher({
  lokiUrl: LOKI_URL,
  service: "fulfillment-worker-ts",
  labels: { team: "demo_ts" },
});
const { tracer, shutdown: shutdownTracing } = initTracing("fulfillment-worker-ts", TEMPO_URL);
const {
  register: metricsRegister,
  messagesTotal,
  decodeErrorsTotal,
  messageDuration,
  outboxPublishedTotal,
  outboxPending,
  outboxOldestPendingSeconds,
} = makeWorkerMetrics();
const confirmationJobs = makeConfirmationJobs(log);

async function handleOrder(
  order: ReturnType<typeof decodeOrderPlaced>,
  traceContext: SpanContext | undefined,
): Promise<Outcome> {
  const start = process.hrtime.bigint();
  const span = startChildSpan(tracer, "fulfill_order", traceContext);
  try {
    log("info", "fulfilling order", {
      order_id: order.order_id,
      item: order.item,
      quantity: String(order.quantity),
    });

    if (db) {
      try {
        await db.withTransaction(async (client) => {
          await fulfillOrder(db!, client, order, confirmationJobs);
        });
      } catch (err) {
        messagesTotal.inc({ status: "fail" });
        return fail(`db: ${String(err)}`);
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

  const kafka = new Kafka({ clientId: "fulfillment-worker-ts", ...KAFKA_ENV });

  const producer = kafka.producer();
  await producer.connect();
  await provisionDlqTopic({
    kafka,
    groupId: GROUP_ID,
    source: { name: TOPIC_NAME, partitions: PARTITIONS },
  });

  const fulfilledTopic = db
    ? await connectTopic({ kafka, registryUrl: requiredRegistry(), contract: ORDER_FULFILLED })
    : undefined;

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

  const onDecodeError = (err: unknown) => {
    console.error(`[worker] undecodable message, dead-lettered: ${String(err)}`);
    log("error", "undecodable message, dead-lettered", { error: String(err) });
  };

  await consumer.run({
    eachMessage: wrapEachMessage({
      decode: decodeOrderPlaced,
      decodeErrorCounter: decodeErrorsTotal,
      onDecodeError,
      dlq: {
        publisher: {
          publish: async (record) => {
            await producer.send({ topic: record.topic, messages: [record] });
          },
        },
        groupId: GROUP_ID,
        sourceTopic: TOPIC_NAME,
      },
      handler: ({ message, traceContext }) => handleOrder(message, traceContext),
    }),
  });

  const pushgatewayUrl = setting("PUSHGATEWAY_URL");
  const pushInterval = pushgatewayUrl
    ? setInterval(() => {
        new Pushgateway(pushgatewayUrl, {}, metricsRegister)
          .pushAdd({ jobName: "sol-demo-ts-fulfillment-worker" })
          .catch((err) => console.error(`[fulfillment-worker-ts] pushgateway push failed: ${String(err)}`));
      }, 3000)
    : undefined;

  const outboxAbort = new AbortController();
  const outboxRunning =
    db && fulfilledTopic
      ? runRelay({
          pool: db.pool,
          publish: async (publication) => {
            const event = decodeOrderFulfilled(JSON.parse(publication.payload));
            const key = fulfilledTopic.key(event);
            if (key !== publication.key) {
              throw new Error(
                `outbox key ${publication.key} does not match the contract key ${key}`,
              );
            }
            await publish(producer, fulfilledTopic, event);
          },
          signal: outboxAbort.signal,
          pollIntervalS: 0.5,
          onPublication: (publication, status) => {
            outboxPublishedTotal.inc({ kind: publication.kind, status });
          },
          onMetrics: (metrics) => {
            outboxPending.reset();
            for (const gauge of metrics.pendingByKind) {
              outboxPending.set({ kind: gauge.kind }, gauge.value);
            }
            outboxOldestPendingSeconds.reset();
            for (const gauge of metrics.oldestPendingSecondsByKind) {
              outboxOldestPendingSeconds.set({ kind: gauge.kind }, gauge.value);
            }
          },
          onWarning: (fields, message) => {
            console.error(`[fulfillment-worker-ts] ${message}`, fields);
            log("error", message, fields);
          },
        }).then((error) => {
          if (error) console.error(`[fulfillment-worker-ts] outbox relay stopped: ${error.message}`);
        })
      : Promise.resolve();

  const jobsAbort = new AbortController();
  const jobsRunning = db
    ? runJobs({
        pool: db.pool,
        contract: confirmationJobs,
        signal: jobsAbort.signal,
        pollIntervalS: 0.5,
        onOutcome: (outcome) => {
          log("info", "job processed", {
            kind: outcome.kind,
            status: outcome.status,
            duration_s: outcome.durationS.toFixed(3),
          });
        },
        onWarning: (fields, message) => {
          console.error(`[fulfillment-worker-ts] ${message}`, fields);
          log("error", message, fields);
        },
      }).then((error) => {
        if (error) console.error(`[fulfillment-worker-ts] jobs stopped: ${error.message}`);
      })
    : Promise.resolve();

  const lifecycle = runWorker({
    drain: async () => {
      outboxAbort.abort();
      jobsAbort.abort();
      await Promise.all([outboxRunning, jobsRunning]);
      await consumer.disconnect();
    },
    onDrainStart: () => {
      console.log("[fulfillment-worker-ts] draining...");
      if (pushInterval) clearInterval(pushInterval);
    },
    shutdownHooks: [
      () => log.flush(),
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

  wireCrashListener(consumer, {
    onCrash: (error) => console.error(`[fulfillment-worker-ts] consumer crashed: ${String(error)}`),
    onFailStop: (reason) => {
      console.error(`[fulfillment-worker-ts] handler failed a fact (fail-stop): ${reason}`);
      return lifecycle.shutdown();
    },
  });
}

main().catch((err) => {
  console.error("[fulfillment-worker-ts] fatal:", err);
  process.exit(1);
});
