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
  return {
    pool,
    insertFulfilled: async (order: FulfilledOrder, client?: pg.PoolClient) => {
      await (client ?? pool).query(
        `INSERT INTO fulfilled_orders_ts (order_id, item, quantity, correlation_id)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (order_id) DO NOTHING`,
        [order.order_id, order.item, order.quantity, order.correlation_id]
      );
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
