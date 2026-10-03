import pg from "pg";

export interface FulfilledOrder {
  order_id: string;
  item: string;
  quantity: number;
  correlation_id: string;
}

export async function makeDb(postgresUrl: string) {
  const pool = new pg.Pool({ connectionString: postgresUrl });
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
  await pool.query(`
    CREATE TABLE IF NOT EXISTS sol_jobs (
      id           SERIAL      PRIMARY KEY,
      workspace    TEXT        NOT NULL,
      kind         TEXT        NOT NULL,
      payload      TEXT        NOT NULL,
      status       TEXT        NOT NULL DEFAULT 'pending',
      attempts     INT         NOT NULL DEFAULT 0,
      run_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
      locked_until TIMESTAMPTZ,
      last_error   TEXT,
      dedupe_key   TEXT,
      inserted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
      finished_at  TIMESTAMPTZ
    )
  `);
  await pool.query(`
    CREATE INDEX IF NOT EXISTS sol_jobs_claim_idx
      ON sol_jobs (workspace, run_at) WHERE status = 'pending'
  `);
  await pool.query(`
    CREATE UNIQUE INDEX IF NOT EXISTS sol_jobs_dedupe_idx
      ON sol_jobs (workspace, kind, dedupe_key) WHERE dedupe_key IS NOT NULL
  `);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS sol_outbox (
      id            BIGSERIAL   PRIMARY KEY,
      kind          TEXT        NOT NULL,
      aggregate_key TEXT        NOT NULL,
      ord           BIGINT      NOT NULL,
      payload       TEXT        NOT NULL,
      created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);
  await pool.query(`
    CREATE UNIQUE INDEX IF NOT EXISTS sol_outbox_key_ord_idx
      ON sol_outbox (aggregate_key, ord)
  `);
  return {
    pool,
    insertFulfilled: async (order: FulfilledOrder, client?: pg.PoolClient): Promise<boolean> => {
      const result = await (client ?? pool).query(
        `INSERT INTO fulfilled_orders_ts (order_id, item, quantity, correlation_id)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (order_id) DO NOTHING`,
        [order.order_id, order.item, order.quantity, order.correlation_id]
      );
      return (result.rowCount ?? 0) > 0;
    },
    withTransaction: async <T>(body: (client: pg.PoolClient) => Promise<T>): Promise<T> => {
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        const result = await body(client);
        await client.query("COMMIT");
        return result;
      } catch (err) {
        await client.query("ROLLBACK").catch(() => {});
        throw err;
      } finally {
        client.release();
      }
    },
    close: () => pool.end(),
  };
}
