import { test } from "node:test";
import assert from "node:assert/strict";
import { makeDb } from "../order_svc/src/db.js";
import { confirmationJobs, WORKSPACE } from "../order_svc/src/jobs.js";
import { placeOrder, placedEvent } from "../order_svc/src/orders.js";
import { publishOrderPlaced } from "../order_svc/src/outbox.js";
import { applyMigrations } from "./migrations.js";

const POSTGRES_URL = process.env.POSTGRES_URL;
const withDb = POSTGRES_URL ? test : test.skip;

function order(orderId: string) {
  return {
    order_id: orderId,
    item: "widget",
    quantity: 2,
    correlation_id: `corr-${orderId}`,
    traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
  };
}

type Db = Awaited<ReturnType<typeof makeDb>>;

async function clean(db: Db, orderId: string): Promise<void> {
  await db.pool.query("DELETE FROM orders_ts WHERE order_id = $1", [orderId]);
  await db.pool.query("DELETE FROM sol_jobs WHERE workspace = $1 AND dedupe_key = $2", [
    WORKSPACE,
    orderId,
  ]);
  await db.pool.query("DELETE FROM sol_outbox WHERE aggregate_key = $1", [orderId]);
}

async function counts(db: Db, orderId: string) {
  const row = await db.pool.query("SELECT count(*)::int AS n FROM orders_ts WHERE order_id = $1", [
    orderId,
  ]);
  const job = await db.pool.query(
    "SELECT count(*)::int AS n FROM sol_jobs WHERE workspace = $1 AND dedupe_key = $2",
    [WORKSPACE, orderId],
  );
  const outbox = await db.pool.query(
    "SELECT count(*)::int AS n FROM sol_outbox WHERE aggregate_key = $1",
    [orderId],
  );
  return { row: row.rows[0].n, job: job.rows[0].n, outbox: outbox.rows[0].n };
}

withDb("one POST commits the order row, its job and its outbox intent together", async () => {
  const db = await makeDb(POSTGRES_URL!);
  const jobs = confirmationJobs();
  try {
    await applyMigrations(db.pool);
    await clean(db, "placement-commit");
    await db.withTransaction(async (client) => {
      const applied = await placeOrder(db, client, order("placement-commit"), jobs);
      assert.equal(applied, true);
    });

    assert.deepEqual(await counts(db, "placement-commit"), { row: 1, job: 1, outbox: 1 });
    assert.deepEqual(await db.readOrder("placement-commit"), {
      order_id: "placement-commit",
      item: "widget",
      quantity: 2,
      status: "accepted",
    });
  } finally {
    await clean(db, "placement-commit");
    await db.close();
  }
});

withDb("a duplicate POST is absorbed at the row, the job and the intent", async () => {
  const db = await makeDb(POSTGRES_URL!);
  const jobs = confirmationJobs();
  try {
    await applyMigrations(db.pool);
    await clean(db, "placement-duplicate");
    let second: boolean | undefined;
    await db.withTransaction(async (client) => {
      await placeOrder(db, client, order("placement-duplicate"), jobs);
    });
    await db.withTransaction(async (client) => {
      second = await placeOrder(db, client, order("placement-duplicate"), jobs);
    });

    assert.equal(second, false, "the second accept finds the row already there");
    assert.deepEqual(await counts(db, "placement-duplicate"), { row: 1, job: 1, outbox: 1 });
  } finally {
    await clean(db, "placement-duplicate");
    await db.close();
  }
});

withDb("a failure after the writes rolls the row, the job and the intent back together", async () => {
  const db = await makeDb(POSTGRES_URL!);
  const jobs = confirmationJobs();
  try {
    await applyMigrations(db.pool);
    await clean(db, "placement-rollback");
    await assert.rejects(
      () =>
        db.withTransaction(async (client) => {
          await placeOrder(db, client, order("placement-rollback"), jobs);
          await publishOrderPlaced(client, placedEvent(order("placement-rollback")));
        }),
      /duplicate key|unique/i,
    );

    assert.deepEqual(await counts(db, "placement-rollback"), { row: 0, job: 0, outbox: 0 });
  } finally {
    await clean(db, "placement-rollback");
    await db.close();
  }
});

withDb("an order nobody accepted has no read-back", async () => {
  const db = await makeDb(POSTGRES_URL!);
  try {
    await applyMigrations(db.pool);
    await clean(db, "placement-unknown");
    assert.equal(await db.readOrder("placement-unknown"), undefined);
  } finally {
    await db.close();
  }
});
