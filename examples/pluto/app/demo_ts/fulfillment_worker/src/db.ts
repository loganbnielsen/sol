// pg is the ecosystem Postgres client (TS equivalent of pg-eio) — plain
// SQL, nothing Sol-specific here. Separate table name (`fulfilled_orders_ts`)
// so this spike never collides with rows the OCaml examples/local-demo
// writes to the same POSTGRES_URL.

import pg from "pg";

export async function makeDb(postgresUrl: string) {
  const pool = new pg.Pool({ connectionString: postgresUrl });
  // pg emits 'error' on an idle client that dies underneath it (Postgres
  // restart, failover, network blip) — with no listener, that's an
  // unhandled event and Node crashes the whole process even with no query
  // in flight. Log and let the pool reconnect on next use.
  pool.on("error", (err) => {
    console.error(`[fulfillment-worker-ts] idle pg client error: ${String(err)}`);
  });
  await pool.query(`
    CREATE TABLE IF NOT EXISTS fulfilled_orders_ts (
      order_id       TEXT        PRIMARY KEY,
      item           TEXT        NOT NULL,
      quantity       INT         NOT NULL,
      correlation_id TEXT        NOT NULL,
      fulfilled_at   TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);
  return {
    insertFulfilled: async (order: { order_id: string; item: string; quantity: number; correlation_id: string }) => {
      await pool.query(
        `INSERT INTO fulfilled_orders_ts (order_id, item, quantity, correlation_id)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (order_id) DO NOTHING`,
        [order.order_id, order.item, order.quantity, order.correlation_id]
      );
    },
    close: () => pool.end(),
  };
}
