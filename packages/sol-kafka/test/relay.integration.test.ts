import { test } from "node:test";
import assert from "node:assert/strict";
import { Kafka, type Message } from "kafkajs";
import { wrapEachRetryableMessage } from "../src/retryable.js";
import { kafkaRetryRelay, provisionRelayTopics, runRetryRelayConsumer } from "../src/relay.js";
import { ACK, deadLetter, retry } from "../src/outcome.js";
import { encodeWire } from "../src/wireFormat.js";
import { HDR_ATTEMPT, HDR_DECODE_ERROR, HDR_ORIGIN_GROUP, HDR_RETRY_AT, relayTopicName } from "../src/retry.js";

// FEAT-081 broker-backed integration. Local-only, env-gated exactly like the
// OCaml repo's run_kafka() suite: CI has no broker for the `test` job, so
// these skip unless KAFKA_BROKERS is set. Run with:
//
//   KAFKA_BROKERS=localhost:9092 npm test -w @sol/kafka
//
// They prove the real ownership transfer — not merely that kafkajs can
// produce and consume.

const BROKERS = (process.env.KAFKA_BROKERS ?? "").split(",").filter(Boolean);
const it = BROKERS.length > 0 ? test : test.skip;

const policy = { baseDelayS: 0.2, maxDelayS: 5, maxAttempts: 3, jitterRatio: 0 };
const strategy = { kind: "retry-topics", policy } as const;
const suffix = () => `${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
const header = (m: Message, key: string) => m.headers?.[key]?.toString();

async function waitUntil<T>(fn: () => T | undefined, timeoutMs = 30000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const v = fn();
    if (v !== undefined) return v;
    if (Date.now() > deadline) throw new Error("timed out waiting for broker state");
    await new Promise((r) => setTimeout(r, 150));
  }
}

/** A throwaway consumer that records everything it sees on a topic. */
async function collect(kafka: Kafka, topic: string, id: string) {
  const seen: Message[] = [];
  const consumer = kafka.consumer({ groupId: `sol-int-collector-${id}` });
  await consumer.connect();
  await consumer.subscribe({ topic, fromBeginning: true });
  await consumer.run({ eachMessage: async ({ message }) => void seen.push(message) });
  return { seen, close: () => consumer.disconnect() };
}

async function makeTopic(kafka: Kafka, topic: string) {
  const admin = kafka.admin();
  await admin.connect();
  try {
    await admin.createTopics({ topics: [{ topic, numPartitions: 1, replicationFactor: 1 }] });
  } finally {
    await admin.disconnect();
  }
}

it("integration: Retry forwards to the retry topic, the relay re-runs the handler, then Ack commits", async () => {
  const s = suffix();
  const sourceTopic = `sol-int-retry-${s}`;
  const groupId = `sol-int-group-${s}`;
  const kafka = new Kafka({ clientId: `sol-int-${s}`, brokers: BROKERS });
  await makeTopic(kafka, sourceTopic);
  await provisionRelayTopics({ kafka, sourceTopic, groupId });

  const producer = kafka.producer();
  await producer.connect();
  const relay = kafkaRetryRelay(producer);

  // source side: always Retry, so a retry record must be produced and the
  // source handler must return (i.e. the source offset may commit).
  const source = kafka.consumer({ groupId });
  await source.connect();
  await source.subscribe({ topic: sourceTopic, fromBeginning: true });
  await source.run({
    eachMessage: wrapEachRetryableMessage({
      decode: (j) => j as { x: number },
      decodeErrorCounter: { inc() {} },
      retryStrategy: strategy,
      groupId,
      sourceTopic,
      relay,
      handler: async () => retry("first failure"),
    }),
  });

  // relay side: Retry once more (attempt 1), then Ack (attempt 2) -> commit.
  const attempts: number[] = [];
  const relayConsumer = await runRetryRelayConsumer({
    kafka,
    sourceTopic,
    groupId,
    retryStrategy: strategy,
    decode: (j) => j as { x: number },
    relay,
    handler: async ({ attempt }) => {
      attempts.push(attempt);
      return attempt >= 2 ? ACK : retry("again");
    },
  });

  await producer.send({ topic: sourceTopic, messages: [{ key: "k", value: encodeWire(1, { x: 1 }) }] });

  await waitUntil(() => (attempts.length >= 2 ? true : undefined));
  assert.deepEqual(attempts.slice(0, 2), [1, 2], "relay re-ran with the incremented attempt");

  await relayConsumer.disconnect();
  await source.disconnect();
  await producer.disconnect();
});

it("integration: Dead_letter reaches <source>.<group>.dlq carrying X-Sol-Origin-Group", async () => {
  const s = suffix();
  const sourceTopic = `sol-int-dlq-${s}`;
  const groupId = `sol-int-group-${s}`;
  const kafka = new Kafka({ clientId: `sol-int-${s}`, brokers: BROKERS });
  await makeTopic(kafka, sourceTopic);
  await provisionRelayTopics({ kafka, sourceTopic, groupId });

  const producer = kafka.producer();
  await producer.connect();
  const relay = kafkaRetryRelay(producer);
  const dlq = await collect(kafka, relayTopicName(sourceTopic, groupId, "dlq"), s);

  const source = kafka.consumer({ groupId });
  await source.connect();
  await source.subscribe({ topic: sourceTopic, fromBeginning: true });
  await source.run({
    eachMessage: wrapEachRetryableMessage({
      decode: (j) => j as { x: number },
      decodeErrorCounter: { inc() {} },
      retryStrategy: strategy,
      groupId,
      sourceTopic,
      relay,
      handler: async () => deadLetter("unprocessable"),
    }),
  });

  await producer.send({ topic: sourceTopic, messages: [{ key: "k", value: encodeWire(1, { x: 1 }) }] });

  const record = await waitUntil(() => dlq.seen[0]);
  assert.equal(header(record, HDR_ORIGIN_GROUP), groupId);
  assert.equal(header(record, HDR_ATTEMPT), "1");

  await dlq.close();
  await source.disconnect();
  await producer.disconnect();
});

it("integration: an undecodable retry record is transferred to the DLQ before being committed", async () => {
  const s = suffix();
  const sourceTopic = `sol-int-decode-${s}`;
  const groupId = `sol-int-group-${s}`;
  const kafka = new Kafka({ clientId: `sol-int-${s}`, brokers: BROKERS });
  await makeTopic(kafka, sourceTopic);
  await provisionRelayTopics({ kafka, sourceTopic, groupId });

  const producer = kafka.producer();
  await producer.connect();
  const relay = kafkaRetryRelay(producer);
  const dlq = await collect(kafka, relayTopicName(sourceTopic, groupId, "dlq"), s);

  const relayConsumer = await runRetryRelayConsumer({
    kafka,
    sourceTopic,
    groupId,
    retryStrategy: strategy,
    decode: (j) => j as { x: number },
    relay,
    handler: async () => ACK,
  });

  // Publish a malformed retry record directly to the retry topic (not even a
  // valid Confluent wire header), due immediately.
  await producer.send({
    topic: relayTopicName(sourceTopic, groupId, "retry"),
    messages: [{ value: Buffer.from("not-a-wire-record"), headers: { [HDR_ATTEMPT]: "1", [HDR_RETRY_AT]: String(Date.now() / 1000) } }],
  });

  const record = await waitUntil(() => dlq.seen[0]);
  assert.match(header(record, HDR_DECODE_ERROR) ?? "", /./);
  assert.equal(header(record, HDR_ORIGIN_GROUP), groupId);

  await relayConsumer.disconnect();
  await dlq.close();
  await producer.disconnect();
});
