import type pg from "pg";
import type { JobContract } from "@sol-fab/jobs";
import type { OrderFulfilled } from "@demo-ts/contract";
import { enqueueConfirmation, type ConfirmationJob } from "./jobs.js";
import { publishFulfilled } from "./outbox.js";

export interface FulfillmentStore {
  insertFulfilled(order: OrderFulfilled, client: pg.PoolClient): Promise<boolean>;
}

export async function fulfillOrder(
  store: FulfillmentStore,
  client: pg.PoolClient,
  order: OrderFulfilled,
  jobs: JobContract<ConfirmationJob>,
): Promise<boolean> {
  const applied = await store.insertFulfilled(order, client);
  if (!applied) return false;
  await enqueueConfirmation(client, jobs, order.order_id);
  await publishFulfilled(client, order);
  return true;
}
