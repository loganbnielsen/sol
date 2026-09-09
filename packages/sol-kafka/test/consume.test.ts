import { test } from "node:test";
import assert from "node:assert/strict";
import { wrapEachMessage, wireCrashListener } from "../src/consume.js";
import { encodeWire } from "../src/wireFormat.js";
import type { Consumer, EachMessagePayload } from "kafkajs";

// Bug 4: decode/validation failures must be REJECTED (counted, never
// retried, handler never invoked); downstream handler failures must be
// RETRIED (rethrown, so kafkajs retries); the consumer must only exit when
// kafkajs itself has given up (payload.restart === false). FEAT-033 got this
// wrong twice across two independent adversarial review rounds.

function fakePayload(value: Buffer | null): EachMessagePayload {
  return { message: { value, headers: {} } } as unknown as EachMessagePayload;
}

test("wrapEachMessage: decode failure increments the counter and never calls the handler", async () => {
  let count = 0;
  let handlerCalled = false;
  const wrapped = wrapEachMessage<{ x: number }>({
    decode: () => {
      throw new Error("invalid shape");
    },
    decodeErrorCounter: { inc: () => (count += 1) },
    handler: async () => {
      handlerCalled = true;
    },
  });

  await wrapped(fakePayload(encodeWire(1, { x: 1 })));
  assert.equal(count, 1);
  assert.equal(handlerCalled, false);
});

test("wrapEachMessage: a tombstone (null value) is a decode failure, not a crash", async () => {
  let count = 0;
  const wrapped = wrapEachMessage<{ x: number }>({
    decode: (json) => json as { x: number },
    decodeErrorCounter: { inc: () => (count += 1) },
    handler: async () => {
      throw new Error("should not be called");
    },
  });

  await wrapped(fakePayload(null));
  assert.equal(count, 1);
});

test("wrapEachMessage: handler failure on a validly-decoded message propagates (retried by kafkajs)", async () => {
  let count = 0;
  const wrapped = wrapEachMessage<{ x: number }>({
    decode: (json) => json as { x: number },
    decodeErrorCounter: { inc: () => (count += 1) },
    handler: async () => {
      throw new Error("downstream DB error");
    },
  });

  await assert.rejects(() => wrapped(fakePayload(encodeWire(1, { x: 1 }))), /downstream DB error/);
  assert.equal(count, 0); // not a decode error -- must not be conflated with the decode-error counter
});

test("wireCrashListener: exits only when kafkajs has given up (payload.restart === false)", () => {
  const listeners: Record<string, (arg: unknown) => void> = {};
  const fakeConsumer = {
    events: { CRASH: "consumer.crash" },
    on: (event: string, cb: (arg: unknown) => void) => {
      listeners[event] = cb;
    },
  } as unknown as Consumer;

  const originalExit = process.exit;
  let exitCalled = false;
  // @ts-expect-error -- intentionally stubbing for the test
  process.exit = () => {
    exitCalled = true;
  };
  try {
    wireCrashListener(fakeConsumer);
    listeners["consumer.crash"]({ payload: { error: new Error("retriable"), restart: true } });
    assert.equal(exitCalled, false, "must not exit when kafkajs is restarting on its own");

    listeners["consumer.crash"]({ payload: { error: new Error("fatal"), restart: false } });
    assert.equal(exitCalled, true, "must exit once kafkajs has given up");
  } finally {
    process.exit = originalExit;
  }
});
