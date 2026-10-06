import { test } from "node:test";
import assert from "node:assert/strict";
import { trace } from "@opentelemetry/api";
import type pg from "pg";
import { ACK } from "@sol-fab/kafka";
import type { RetryPolicy } from "@sol-fab/retry";
import { requiredPostgresUrl } from "../fulfillment_worker/src/config.js";
import {
  handleOrder,
  type OrderHandlerDeps,
  type OrderStore,
} from "../fulfillment_worker/src/handler.js";
import { decodeOrderPlaced } from "../contract/src/index.js";
import { makeOrderJobs } from "../fulfillment_worker/src/jobs.js";

const ORDER = {
  order_id: "storage-fixture",
  item: "widget",
  quantity: 2,
  correlation_id: "corr-storage",
};

function withPostgres(value: string | undefined, body: () => void): void {
  const previous = process.env.POSTGRES_URL;
  if (value === undefined) delete process.env.POSTGRES_URL;
  else process.env.POSTGRES_URL = value;
  try {
    body();
  } finally {
    if (previous === undefined) delete process.env.POSTGRES_URL;
    else process.env.POSTGRES_URL = previous;
  }
}

/** No delay, so the retry cases stay fast; the worker uses `DB_RETRY_POLICY`. */
const FAST_RETRY: RetryPolicy = { baseDelayS: 0, maxDelayS: 0, maxAttempts: 4, jitterRatio: 0 };

function deps(store: OrderStore, retryPolicy: RetryPolicy = FAST_RETRY): OrderHandlerDeps {
  return {
    store,
    jobs: makeOrderJobs(
      () => {},
      {
        markConfirmed: async () => {},
      },
    ),
    log: () => {},
    tracer: trace.getTracer("storage-test"),
    messagesTotal: { inc: () => {} },
    messageDuration: { observe: () => {} },
    retryPolicy,
  };
}

test("storage is required before the worker can consume", () => {
  for (const value of [undefined, "", "   "]) {
    withPostgres(value, () => {
      assert.throws(() => requiredPostgresUrl(), /POSTGRES_URL is not set/);
    });
  }
  withPostgres("postgres://example/db", () => {
    assert.equal(requiredPostgresUrl(), "postgres://example/db");
  });
});

test("an already-applied fact acknowledges without a second effect", async () => {
  const store: OrderStore = {
    insertFulfilled: async () => false,
    markFulfilled: async () => {},
    withTransaction: async <T>(
      body: (client: pg.PoolClient) => Promise<T>,
    ): Promise<T> => body({} as pg.PoolClient),
  };
  const outcome = await handleOrder(decodeOrderPlaced(ORDER), undefined, deps(store));
  assert.equal(outcome, ACK);
});

test("a failed transaction returns failure without acknowledgement", async () => {
  const store: OrderStore = {
    insertFulfilled: async () => true,
    markFulfilled: async () => {},
    withTransaction: async <T>(
      _body: (client: pg.PoolClient) => Promise<T>,
    ): Promise<T> => {
      throw new Error("db down");
    },
  };
  const outcome = await handleOrder(decodeOrderPlaced(ORDER), undefined, deps(store));
  assert.notEqual(outcome, ACK);
});

test("a transient transaction failure is retried in place and then acknowledged", async () => {
  let attempts = 0;
  const store: OrderStore = {
    insertFulfilled: async () => {
      attempts += 1;
      if (attempts === 1) throw new Error("serialization failure");
      return false;
    },
    markFulfilled: async () => {},
    withTransaction: async <T>(
      body: (client: pg.PoolClient) => Promise<T>,
    ): Promise<T> => body({} as pg.PoolClient),
  };
  const outcome = await handleOrder(decodeOrderPlaced(ORDER), undefined, deps(store));
  assert.equal(outcome, ACK);
  assert.equal(attempts, 2, "the failed operation is retried exactly once");
});

test("an operation that keeps failing is retried to the policy budget and then fails", async () => {
  let attempts = 0;
  const store: OrderStore = {
    insertFulfilled: async () => {
      attempts += 1;
      throw new Error("db down");
    },
    markFulfilled: async () => {},
    withTransaction: async <T>(
      body: (client: pg.PoolClient) => Promise<T>,
    ): Promise<T> => body({} as pg.PoolClient),
  };
  const policy: RetryPolicy = { baseDelayS: 0, maxDelayS: 0, maxAttempts: 3, jitterRatio: 0 };
  const outcome = await handleOrder(decodeOrderPlaced(ORDER), undefined, deps(store, policy));
  assert.notEqual(outcome, ACK);
  assert.equal(attempts, 3, "the operation is attempted exactly maxAttempts times");
});
