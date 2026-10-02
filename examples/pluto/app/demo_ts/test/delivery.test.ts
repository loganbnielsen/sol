import { test } from "node:test";
import assert from "node:assert/strict";
import { runJobs } from "@sol-fab/jobs";
import { makeDb } from "../fulfillment_worker/src/db.js";
import { enqueueConfirmation, makeConfirmationJobs } from "../fulfillment_worker/src/jobs.js";

const POSTGRES_URL = process.env.POSTGRES_URL;
const withDb = POSTGRES_URL ? test : test.skip;

const WORKSPACE = "pluto.demo_ts";
const ORDER = {
  order_id: "duplicate-delivery-fixture",
  item: "widget",
  quantity: 2,
  correlation_id: "corr-duplicate",
};

let handled = 0;
const jobs = makeConfirmationJobs(() => {
  handled += 1;
});

withDb("a redelivered fact leaves one row, one job and one effect", async () => {
  const db = await makeDb(POSTGRES_URL!);
  const deliver = async () => {
    await db.withTransaction(async (client) => {
      await db.insertFulfilled(ORDER, client);
      await enqueueConfirmation(client, jobs, ORDER.order_id);
    });
  };
  try {
    await db.pool.query("DELETE FROM fulfilled_orders_ts WHERE order_id = $1", [ORDER.order_id]);
    await db.pool.query("DELETE FROM sol_jobs WHERE workspace = $1 AND dedupe_key = $2", [
      WORKSPACE,
      ORDER.order_id,
    ]);

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

    const controller = new AbortController();
    const error = await runJobs({
      pool: db.pool,
      contract: jobs,
      signal: controller.signal,
      pollIntervalS: 0.05,
      onOutcome: (outcome) => {
        if (outcome.status === "ok") controller.abort();
      },
    });
    assert.equal(error, undefined);
    assert.equal(handled, 1, "the follow-up effect must happen exactly once");
  } finally {
    await db.pool.query("DELETE FROM fulfilled_orders_ts WHERE order_id = $1", [ORDER.order_id]);
    await db.pool.query("DELETE FROM sol_jobs WHERE workspace = $1 AND dedupe_key = $2", [
      WORKSPACE,
      ORDER.order_id,
    ]);
    await db.close();
  }
});
