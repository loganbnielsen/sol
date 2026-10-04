import type pg from "pg";
import type { JobContract } from "@sol-fab/jobs";
import type { OrderFulfilled } from "@demo-ts/contract";
import { enqueueOrderJob, INVENTORY_KIND, type OrderJob } from "./jobs.js";
import { publishFulfilled } from "./outbox.js";

export interface FulfillmentStore {
  insertFulfilled(order: OrderFulfilled, client: pg.PoolClient): Promise<boolean>;
  markFulfilled(orderId: string, client: pg.PoolClient): Promise<void>;
}

export async function fulfillOrder(
  store: FulfillmentStore,
  client: pg.PoolClient,
  order: OrderFulfilled,
  jobs: JobContract<OrderJob>,
): Promise<boolean> {
  const applied = await store.insertFulfilled(order, client);
  if (!applied) return false;
  await enqueueOrderJob(client, jobs, { kind: INVENTORY_KIND, order_id: order.order_id });
  await publishFulfilled(client, order);
  await store.markFulfilled(order.order_id, client);
  return true;
}
