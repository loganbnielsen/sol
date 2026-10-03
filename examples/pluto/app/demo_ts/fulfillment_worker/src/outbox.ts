import { publish, type OutboxContract, type Queryable } from "@sol-fab/outbox";
import type { OrderFulfilled } from "@demo-ts/contract";

export const FULFILLED_KIND = "order_fulfilled";
export const FULFILLED_ORD = 2;

export const FULFILLED_EVENTS: OutboxContract<OrderFulfilled> = {
  kinds: [FULFILLED_KIND],
  kind: () => FULFILLED_KIND,
  encode: (event) => JSON.stringify(event),
};

export async function publishFulfilled(
  client: Queryable,
  event: OrderFulfilled,
  ord = FULFILLED_ORD,
): Promise<void> {
  await publish(client, FULFILLED_EVENTS, event, { key: event.order_id, ord });
}
