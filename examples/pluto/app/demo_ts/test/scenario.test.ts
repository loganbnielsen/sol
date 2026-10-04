import { test } from "node:test";
import assert from "node:assert/strict";
import { runJobs } from "@sol-fab/jobs";
import { makeDb as makeSvcDb } from "../order_svc/src/db.js";
import { confirmationJobs, WORKSPACE } from "../order_svc/src/jobs.js";
import { placeOrder } from "../order_svc/src/orders.js";
import { makeDb as makeWorkerDb } from "../fulfillment_worker/src/db.js";
import {
  CONFIRMATION_KIND,
  INVENTORY_KIND,
  makeOrderJobs,
} from "../fulfillment_worker/src/jobs.js";
import { fulfillOrder } from "../fulfillment_worker/src/fulfill.js";
import { applyMigrations } from "./migrations.js";

const POSTGRES_URL = process.env.POSTGRES_URL;
const withDb = POSTGRES_URL ? test : test.skip;

const ORDER_ID = "scenario-order";
const TRACEPARENT = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";

const accepted = {
  order_id: ORDER_ID,
  item: "widget",
  quantity: 3,
  correlation_id: "corr-scenario",
  traceparent: TRACEPARENT,
};

const placed = {
  order_id: ORDER_ID,
  item: "widget",
  quantity: 3,
  correlation_id: "corr-scenario",
};

type Db = Awaited<ReturnType<typeof makeSvcDb>>;

async function clean(db: Db): Promise<void> {
  for (const table of [
    "orders_ts",
    "fulfilled_orders_ts",
    "order_confirmations_ts",
  ]) {
    await db.pool.query(`DELETE FROM ${table} WHERE order_id = $1`, [ORDER_ID]);
  }
  await db.pool.query("DELETE FROM sol_jobs WHERE workspace = $1 AND dedupe_key = $2", [
    WORKSPACE,
    ORDER_ID,
  ]);
  await db.pool.query("DELETE FROM sol_outbox WHERE aggregate_key = $1", [ORDER_ID]);
}

async function outboxKinds(db: Db): Promise<string[]> {
  const rows = await db.pool.query(
    "SELECT kind FROM sol_outbox WHERE aggregate_key = $1 ORDER BY ord",
    [ORDER_ID],
  );
  return rows.rows.map((row) => row.kind as string);
}

withDb("one accepted order reaches a confirmed read-back with every effect once", async () => {
  const svc = await makeSvcDb(POSTGRES_URL!);
  await applyMigrations(svc.pool);
  const worker = await makeWorkerDb(POSTGRES_URL!);
  const confirmed: string[] = [];
  const workerJobs = makeOrderJobs(() => {}, {
    markConfirmed: async (orderId) => {
      confirmed.push(orderId);
      await worker.markConfirmed(orderId);
    },
  });
  try {
    await clean(svc);

    await svc.withTransaction(async (client) => {
      const applied = await placeOrder(svc, client, accepted, confirmationJobs());
      assert.equal(applied, true);
    });

    assert.equal((await svc.readOrder(ORDER_ID))?.status, "accepted");
    assert.equal(
      await svc.traceparentOf(ORDER_ID),
      TRACEPARENT,
      "the accept keeps the caller's trace context for the relay to publish under",
    );
    assert.deepEqual(await outboxKinds(svc), ["order_placed"]);

    await worker.withTransaction(async (client) => {
      await fulfillOrder(worker, client, placed, workerJobs);
    });

    assert.equal((await svc.readOrder(ORDER_ID))?.status, "fulfilled");
    assert.deepEqual(await outboxKinds(svc), ["order_placed", "order_fulfilled"]);

    const outcomes: string[] = [];
    const error = await runJobs({
      pool: worker.pool,
      contract: workerJobs,
      maxJobs: 2,
      pollIntervalS: 0.05,
      onOutcome: (outcome) => {
        outcomes.push(outcome.kind);
      },
    });
    assert.equal(error, undefined);
    assert.deepEqual(
      [...outcomes].sort(),
      [CONFIRMATION_KIND, INVENTORY_KIND].sort(),
      "the runner executes both kinds",
    );
    assert.deepEqual(confirmed, [ORDER_ID], "the confirmation effect happens once");

    assert.equal((await svc.readOrder(ORDER_ID))?.status, "confirmed");
    const confirmations = await worker.pool.query(
      "SELECT count(*)::int AS n FROM order_confirmations_ts WHERE order_id = $1",
      [ORDER_ID],
    );
    assert.equal(confirmations.rows[0].n, 1);
  } finally {
    await clean(svc);
    await Promise.all([svc.close(), worker.close()]);
  }
});

withDb("a confirmation is refused until the order is fulfilled", async () => {
  const svc = await makeSvcDb(POSTGRES_URL!);
  await applyMigrations(svc.pool);
  const worker = await makeWorkerDb(POSTGRES_URL!);
  const workerJobs = makeOrderJobs(() => {}, {
    markConfirmed: async (orderId) => {
      await worker.markConfirmed(orderId);
    },
  });
  try {
    await clean(svc);

    await svc.withTransaction(async (client) => {
      assert.equal(await placeOrder(svc, client, accepted, confirmationJobs()), true);
    });

    await assert.rejects(
      () => worker.markConfirmed(ORDER_ID),
      /is not fulfilled yet/,
      "a confirmation before fulfilment is refused so the runner retries",
    );
    assert.equal((await svc.readOrder(ORDER_ID))?.status, "accepted");
    const early = await worker.pool.query(
      "SELECT count(*)::int AS n FROM order_confirmations_ts WHERE order_id = $1",
      [ORDER_ID],
    );
    assert.equal(early.rows[0].n, 0, "no confirmation effect is recorded before fulfilment");

    await worker.withTransaction(async (client) => {
      await fulfillOrder(worker, client, placed, workerJobs);
    });
    assert.equal((await svc.readOrder(ORDER_ID))?.status, "fulfilled");

    await worker.markConfirmed(ORDER_ID);
    assert.equal((await svc.readOrder(ORDER_ID))?.status, "confirmed");
    const confirmations = await worker.pool.query(
      "SELECT count(*)::int AS n FROM order_confirmations_ts WHERE order_id = $1",
      [ORDER_ID],
    );
    assert.equal(confirmations.rows[0].n, 1);
  } finally {
    await clean(svc);
    await Promise.all([svc.close(), worker.close()]);
  }
});
