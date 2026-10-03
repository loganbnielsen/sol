import type pg from "pg";
import type { JobContract } from "@sol-fab/jobs";
import type { OrderPlaced } from "@demo-ts/contract";
import type { AcceptedOrder } from "./db.js";
import { enqueueConfirmation, type ConfirmationJob } from "./jobs.js";
import { publishOrderPlaced } from "./outbox.js";

export interface OrderStore {
  insertOrder(order: AcceptedOrder, client: pg.PoolClient): Promise<boolean>;
}

export function placedEvent(order: AcceptedOrder): OrderPlaced {
  return {
    order_id: order.order_id,
    item: order.item,
    quantity: order.quantity,
    correlation_id: order.correlation_id,
  };
}

export async function placeOrder(
  store: OrderStore,
  client: pg.PoolClient,
  order: AcceptedOrder,
  jobs: JobContract<ConfirmationJob>,
): Promise<boolean> {
  const applied = await store.insertOrder(order, client);
  if (!applied) return false;
  await enqueueConfirmation(client, jobs, order.order_id);
  await publishOrderPlaced(client, placedEvent(order));
  return true;
}
