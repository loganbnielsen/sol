import { test } from "node:test";
import assert from "node:assert/strict";
import { runJobs } from "@sol-fab/jobs";
import { makeDb } from "../fulfillment_worker/src/db.js";
import { INVENTORY_KIND, makeOrderJobs, WORKSPACE } from "../fulfillment_worker/src/jobs.js";
import { fulfillOrder } from "../fulfillment_worker/src/fulfill.js";
import { applyMigrations } from "./migrations.js";

const POSTGRES_URL = process.env.POSTGRES_URL;
const withDb = POSTGRES_URL ? test : test.skip;

const ORDER = {
  order_id: "duplicate-delivery-fixture",
  item: "widget",
  quantity: 2,
  correlation_id: "corr-duplicate",
};

let confirmations = 0;
const jobs = makeOrderJobs(() => {}, {
  markConfirmed: async () => {
    confirmations += 1;
  },
});

type Db = Awaited<ReturnType<typeof makeDb>>;

async function clean(db: Db): Promise<void> {
  await db.pool.query("DELETE FROM fulfilled_orders_ts WHERE order_id = $1", [ORDER.order_id]);
  await db.pool.query("DELETE FROM order_confirmations_ts WHERE order_id = $1", [ORDER.order_id]);
  await db.pool.query("DELETE FROM orders_ts WHERE order_id = $1", [ORDER.order_id]);
  await db.pool.query("DELETE FROM sol_jobs WHERE workspace = $1 AND dedupe_key = $2", [
    WORKSPACE,
    ORDER.order_id,
  ]);
  await db.pool.query("DELETE FROM sol_outbox WHERE aggregate_key = $1", [ORDER.order_id]);
}

withDb("a redelivered fact leaves one row, one job and one intent", async () => {
  const db = await makeDb(POSTGRES_URL!);
  await applyMigrations(db.pool);
  const deliver = async () => {
    await db.withTransaction(async (client) => {
      await fulfillOrder(db, client, ORDER, jobs);
    });
  };
  try {
    await clean(db);

    await deliver();
    await deliver();

    const row = await db.pool.query(
      "SELECT count(*)::int AS n FROM fulfilled_orders_ts WHERE order_id = $1",
      [ORDER.order_id],
    );
    assert.equal(row.rows[0].n, 1, "the redelivered fact must not duplicate the row");

    const job = await db.pool.query(
      "SELECT count(*)::int AS n FROM sol_jobs WHERE workspace = $1 AND dedupe_key = $2",
      [WORKSPACE, ORDER.order_id],
    );
    assert.equal(job.rows[0].n, 1, "the redelivered fact must not duplicate the job");

    const outbox = await db.pool.query(
      "SELECT count(*)::int AS n FROM sol_outbox WHERE aggregate_key = $1",
      [ORDER.order_id],
    );
    assert.equal(outbox.rows[0].n, 1, "the redelivered fact must not duplicate the publication intent");

    const outcomes: string[] = [];
    const error = await runJobs({
      pool: db.pool,
      contract: jobs,
      maxJobs: 1,
      pollIntervalS: 0.05,
      onOutcome: (outcome) => {
        outcomes.push(outcome.kind);
      },
    });
    assert.equal(error, undefined);
    assert.deepEqual(outcomes, [INVENTORY_KIND], "the follow-up job runs exactly once");
    assert.equal(confirmations, 0, "no confirmation was enqueued for this order");
  } finally {
    await clean(db);
    await db.close();
  }
});
