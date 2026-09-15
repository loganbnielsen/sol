import { test } from "node:test";
import assert from "node:assert/strict";
import type { EachMessagePayload } from "kafkajs";
import { wrapEachRetryableMessage, type RelayRecord, type RetryRelay } from "../src/retryable.js";
import { ACK, deadLetter, retry } from "../src/outcome.js";
import { HDR_ATTEMPT, HDR_ORIGIN_GROUP, HDR_RETRY_AT, type RetryStrategy } from "../src/retry.js";
import { encodeWire } from "../src/wireFormat.js";

// FEAT-081: the routing/record-shape behaviour of the retry-capable wrapper,
// exercised without a broker through an injected RetryRelay. The kafkajs
// wiring itself is covered by the opt-in broker integration test.

function payload(value: Buffer): EachMessagePayload {
  return { message: { value, headers: {}, key: Buffer.from("k") } } as unknown as EachMessagePayload;
}

function collector(): { relay: RetryRelay; records: RelayRecord[] } {
  const records: RelayRecord[] = [];
  return {
    records,
    relay: {
      publish: async (record) => {
        records.push(record);
      },
    },
  };
}

const base = { baseDelayS: 1, maxDelayS: 600, maxAttempts: 3, jitterRatio: 0 };
const retryTopics = (over: Partial<typeof base> = {}): RetryStrategy => ({
  kind: "retry-topics",
  policy: { ...base, ...over },
});
const inMemory = (over: Partial<typeof base> = {}): RetryStrategy => ({
  kind: "in-memory",
  policy: { ...base, ...over },
});

const decodeOk = (json: unknown) => json as { x: number };
function counter(): { inc(): void; readonly value: number } {
  let n = 0;
  return { inc: () => (n += 1), get value() { return n; } };
}

test("retry-topics: Retry forwards to <source>.<group>.retry with attempt/retry-at and commits", async () => {
  const { relay, records } = collector();
  let calls = 0;
  const wrapped = wrapEachRetryableMessage({
    decode: decodeOk,
    decodeErrorCounter: counter(),
    retryStrategy: retryTopics(),
    groupId: "fulfillment",
    sourceTopic: "orders",
    relay,
    nowS: () => 1000,
    handler: async () => {
      calls += 1;
      return retry("db down");
    },
  });

  await wrapped(payload(encodeWire(1, { x: 1 })));

  assert.equal(calls, 1, "source path runs the handler once, then forwards");
  assert.equal(records.length, 1);
  assert.equal(records[0].topic, "orders.fulfillment.retry");
  assert.equal(records[0].headers[HDR_ATTEMPT], "1");
  assert.equal(records[0].headers[HDR_RETRY_AT], "1001"); // now + backoff(attempt 1) = 1s
  assert.equal(records[0].key?.toString(), "k", "the source key travels with the record");
});

test("retry-topics: Dead_letter forwards straight to <source>.<group>.dlq with origin group", async () => {
  const { relay, records } = collector();
  const wrapped = wrapEachRetryableMessage({
    decode: decodeOk,
    decodeErrorCounter: counter(),
    retryStrategy: retryTopics(),
    groupId: "fulfillment",
    sourceTopic: "orders",
    relay,
    nowS: () => 1000,
    handler: async () => deadLetter("unprocessable"),
  });

  await wrapped(payload(encodeWire(1, { x: 1 })));

  assert.equal(records.length, 1);
  assert.equal(records[0].topic, "orders.fulfillment.dlq");
  assert.equal(records[0].headers[HDR_ORIGIN_GROUP], "fulfillment");
  assert.equal(records[0].headers[HDR_RETRY_AT], "1000"); // dead letters are immediate
});

test("retry-topics: maxAttempts=1 means no retry -- Retry goes straight to the DLQ", async () => {
  const { relay, records } = collector();
  const wrapped = wrapEachRetryableMessage({
    decode: decodeOk,
    decodeErrorCounter: counter(),
    retryStrategy: retryTopics({ maxAttempts: 1 }),
    groupId: "fulfillment",
    sourceTopic: "orders",
    relay,
    nowS: () => 1000,
    handler: async () => retry("nope"),
  });

  await wrapped(payload(encodeWire(1, { x: 1 })));
  assert.equal(records.length, 1);
  assert.equal(records[0].topic, "orders.fulfillment.dlq");
  assert.equal(records[0].headers[HDR_ATTEMPT], "1");
});

test("retry-topics: a failed publish fails closed (throws, never acked)", async () => {
  const failing: RetryRelay = { publish: async () => { throw new Error("broker down"); } };
  const wrapped = wrapEachRetryableMessage({
    decode: decodeOk,
    decodeErrorCounter: counter(),
    retryStrategy: retryTopics(),
    groupId: "g",
    sourceTopic: "t",
    relay: failing,
    handler: async () => retry("boom"),
  });
  await assert.rejects(() => wrapped(payload(encodeWire(1, { x: 1 }))), /not acking/);
});

test("retry-topics: construction fails without a relay or with maxAttempts < 1", () => {
  const common = {
    decode: decodeOk,
    decodeErrorCounter: counter(),
    groupId: "g",
    sourceTopic: "t",
    handler: async () => ACK,
  };
  assert.throws(
    () => wrapEachRetryableMessage({ ...common, retryStrategy: retryTopics() }),
    /requires a relay/,
  );
  assert.throws(
    () => wrapEachRetryableMessage({ ...common, relay: collector().relay, retryStrategy: retryTopics({ maxAttempts: -1 }) }),
    /maxAttempts must be >= 1/,
  );
});

test("decode failure increments the counter, never runs the handler, never publishes", async () => {
  const { relay, records } = collector();
  const errors = counter();
  let handlerCalled = false;
  const wrapped = wrapEachRetryableMessage({
    decode: () => {
      throw new Error("bad shape");
    },
    decodeErrorCounter: errors,
    retryStrategy: retryTopics(),
    groupId: "g",
    sourceTopic: "t",
    relay,
    handler: async () => {
      handlerCalled = true;
      return ACK;
    },
  });

  await wrapped(payload(encodeWire(1, { x: 1 })));
  assert.equal(errors.value, 1);
  assert.equal(handlerCalled, false);
  assert.equal(records.length, 0);
});

test("in-memory: Retry sleeps the policy backoff and re-runs the handler; a later Ack commits", async () => {
  const sleeps: number[] = [];
  const outcomes = [retry("transient"), ACK];
  const wrapped = wrapEachRetryableMessage({
    decode: decodeOk,
    decodeErrorCounter: counter(),
    retryStrategy: inMemory(),
    groupId: "g",
    sourceTopic: "t",
    sleep: async (s) => {
      sleeps.push(s);
    },
    handler: async () => outcomes.shift()!,
  });

  await wrapped(payload(encodeWire(1, { x: 1 })));
  assert.deepEqual(sleeps, [1]); // backoff(attempt 1)
});

test("in-memory: Dead_letter and retry exhaustion fail closed (throw)", async () => {
  const dl = wrapEachRetryableMessage({
    decode: decodeOk,
    decodeErrorCounter: counter(),
    retryStrategy: inMemory(),
    groupId: "g",
    sourceTopic: "t",
    sleep: async () => {},
    handler: async () => deadLetter("nope"),
  });
  await assert.rejects(() => dl(payload(encodeWire(1, { x: 1 }))), /not acking/);

  const exhausted = wrapEachRetryableMessage({
    decode: decodeOk,
    decodeErrorCounter: counter(),
    retryStrategy: inMemory({ maxAttempts: 2 }),
    groupId: "g",
    sourceTopic: "t",
    sleep: async () => {},
    handler: async () => retry("always"),
  });
  await assert.rejects(() => exhausted(payload(encodeWire(1, { x: 1 }))), /not acking/);
});

test("retry-topics: retry/relay metrics are reported", async () => {
  const scheduled: Array<{ attempt: number; delayS: number }> = [];
  const published: string[] = [];
  const { relay } = collector();
  const wrapped = wrapEachRetryableMessage({
    decode: decodeOk,
    decodeErrorCounter: counter(),
    retryStrategy: retryTopics(),
    groupId: "g",
    sourceTopic: "t",
    relay,
    nowS: () => 0,
    metrics: {
      onSchedule: (i) => scheduled.push(i),
      onRelayPublish: (i) => published.push(i.outcome),
    },
    handler: async () => retry("x"),
  });
  await wrapped(payload(encodeWire(1, { x: 1 })));
  assert.deepEqual(scheduled, [{ attempt: 1, delayS: 1 }]);
  assert.deepEqual(published, ["published"]);
});
