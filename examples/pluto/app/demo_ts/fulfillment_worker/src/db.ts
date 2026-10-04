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
    markFulfilled: async (orderId: string, client?: pg.PoolClient): Promise<void> => {
      await (client ?? pool).query(
        `UPDATE orders_ts
            SET status = 'fulfilled', fulfilled_at = now()
          WHERE order_id = $1 AND fulfilled_at IS NULL`,
        [orderId]
      );
    },
    markConfirmed: async (orderId: string, client?: pg.PoolClient): Promise<void> => {
      const target = client ?? pool;
      await target.query(
        `INSERT INTO order_confirmations_ts (order_id)
         VALUES ($1)
         ON CONFLICT (order_id) DO NOTHING`,
        [orderId]
      );
      await target.query(
        `UPDATE orders_ts
            SET status = 'confirmed', confirmed_at = now()
          WHERE order_id = $1 AND confirmed_at IS NULL`,
        [orderId]
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
