import { publish, type OutboxContract, type Queryable } from "@sol-fab/outbox";
import type { OrderPlaced } from "@demo-ts/contract";

export const ORDER_PLACED_KIND = "order_placed";

export const ORDER_PLACED_EVENTS: OutboxContract<OrderPlaced> = {
  kinds: [ORDER_PLACED_KIND],
  kind: () => ORDER_PLACED_KIND,
  encode: (event) => JSON.stringify(event),
};

export async function publishOrderPlaced(
  client: Queryable,
  event: OrderPlaced,
  ord = 1,
): Promise<void> {
  await publish(client, ORDER_PLACED_EVENTS, event, { key: event.order_id, ord });
}
