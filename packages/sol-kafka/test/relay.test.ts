import { test } from "node:test";
import assert from "node:assert/strict";
import { handleRetryRecord, type RetryRelayProcessorOptions } from "../src/relay.js";
import { ACK, deadLetter, retry } from "../src/outcome.js";
import { encodeWire } from "../src/wireFormat.js";
import {
  HDR_ATTEMPT,
  HDR_DECODE_ERROR,
  HDR_ORIGIN_GROUP,
  HDR_RETRY_AT,
  type RetryStrategy,
} from "../src/retry.js";
import type { RelayRecord, RetryRelay } from "../src/retryable.js";

// FEAT-081: the relay path's delivery semantics, broker-free. Throwing means
// "do not commit"; every successful path returns normally.

const strategy: RetryStrategy = {
  kind: "retry-topics",
  policy: { baseDelayS: 1, maxDelayS: 600, maxAttempts: 3, jitterRatio: 0 },
};

function collector(): { relay: RetryRelay; records: RelayRecord[] } {
  const records: RelayRecord[] = [];
  return { records, relay: { publish: async (r) => { records.push(r); } } };
}

type Over = Partial<RetryRelayProcessorOptions<{ x: number }>>;
function opts(over: Over = {}): RetryRelayProcessorOptions<{ x: number }> {
  return {
    sourceTopic: "orders",
    groupId: "g",
    retryStrategy: strategy,
    decode: (j) => j as { x: number },
    handler: async () => ACK,
    relay: collector().relay,
    nowS: () => 1000,
    sleep: async () => {},
    ...over,
  };
}

const record = (headers: Record<string, string>, value = encodeWire(1, { x: 1 })) => ({
  key: Buffer.from("k"),
  value,
  headers,
});

test("relay: an undecodable retry record is transferred to the DLQ with the diagnostic", async () => {
  const { relay, records } = collector();
  await handleRetryRecord(
    opts({
      relay,
      decode: () => {
        throw new Error("bad json");
      },
    }),
    record({ [HDR_ATTEMPT]: "1", [HDR_RETRY_AT]: "1000" }),
  );

  assert.equal(records.length, 1);
  assert.equal(records[0].topic, "orders.g.dlq");
  assert.match(records[0].headers[HDR_DECODE_ERROR], /bad json/);
  assert.equal(records[0].headers[HDR_ORIGIN_GROUP], "g");
  assert.equal(records[0].headers[HDR_ATTEMPT], "1", "original headers are preserved untouched");
});

test("relay: a failed DLQ publish on an undecodable record throws (not committed)", async () => {
  const failing: RetryRelay = { publish: async () => { throw new Error("broker down"); } };
  await assert.rejects(
    () =>
      handleRetryRecord(
        opts({ relay: failing, decode: () => { throw new Error("bad"); } }),
        record({ [HDR_ATTEMPT]: "1", [HDR_RETRY_AT]: "1000" }),
      ),
    /broker down/,
  );
});

test("relay: malformed retry metadata dead-letters at the terminal attempt (no reschedule)", async () => {
  const { relay, records } = collector();
  await handleRetryRecord(opts({ relay }), record({}));

  assert.equal(records.length, 1);
  assert.equal(records[0].topic, "orders.g.dlq");
  assert.equal(records[0].headers[HDR_ATTEMPT], "3"); // max(1, maxAttempts)
  assert.equal(records[0].headers[HDR_ORIGIN_GROUP], "g");
});

test("relay: Retry forwards to the retry topic with the incremented attempt and backoff", async () => {
  const { relay, records } = collector();
  await handleRetryRecord(
    opts({ relay, handler: async () => retry("again") }),
    record({ [HDR_ATTEMPT]: "1", [HDR_RETRY_AT]: "1000" }),
  );

  assert.equal(records.length, 1);
  assert.equal(records[0].topic, "orders.g.retry");
  assert.equal(records[0].headers[HDR_ATTEMPT], "2");
  assert.equal(records[0].headers[HDR_RETRY_AT], "1002"); // now + backoff(attempt 2) = 2s
});

test("relay: Retry at the attempt budget dead-letters instead of rescheduling", async () => {
  const { relay, records } = collector();
  await handleRetryRecord(
    opts({ relay, handler: async () => retry("again") }),
    record({ [HDR_ATTEMPT]: "3", [HDR_RETRY_AT]: "1000" }),
  );

  assert.equal(records.length, 1);
  assert.equal(records[0].topic, "orders.g.dlq");
  assert.equal(records[0].headers[HDR_ATTEMPT], "4");
});

test("relay: Dead_letter goes to the DLQ at the current attempt", async () => {
  const { relay, records } = collector();
  await handleRetryRecord(
    opts({ relay, handler: async () => deadLetter("nope") }),
    record({ [HDR_ATTEMPT]: "2", [HDR_RETRY_AT]: "1000" }),
  );

  assert.equal(records.length, 1);
  assert.equal(records[0].topic, "orders.g.dlq");
  assert.equal(records[0].headers[HDR_ATTEMPT], "2");
});

test("relay: Ack publishes nothing", async () => {
  const { relay, records } = collector();
  await handleRetryRecord(opts({ relay }), record({ [HDR_ATTEMPT]: "1", [HDR_RETRY_AT]: "1000" }));
  assert.equal(records.length, 0);
});

test("relay: waits until X-Sol-Retry-At before running the handler", async () => {
  const sleeps: number[] = [];
  const { relay } = collector();
  let handlerAttempt: number | undefined;
  await handleRetryRecord(
    opts({
      relay,
      sleep: async (s) => { sleeps.push(s); },
      handler: async ({ attempt }) => { handlerAttempt = attempt; return ACK; },
    }),
    record({ [HDR_ATTEMPT]: "2", [HDR_RETRY_AT]: "1002" }), // due 2s after now(1000)
  );
  assert.deepEqual(sleeps, [2]);
  assert.equal(handlerAttempt, 2, "the handler sees the attempt carried by the record");
});
