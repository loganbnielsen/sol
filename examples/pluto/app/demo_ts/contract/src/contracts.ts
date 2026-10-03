import type { NamedContract, TopicContract } from "@sol-fab/kafka";

export interface OrderPlaced {
  order_id: string;
  item: string;
  quantity: number;
  correlation_id: string;
}

const ORDERS_TOPIC = process.env.ORDERS_TOPIC?.trim() || "sol-demo-ts-orders";

const ORDER_PLACED_SCHEMA = JSON.stringify({
  type: "object",
  properties: {
    order_id: { type: "string" },
    item: { type: "string" },
    quantity: { type: "integer" },
    correlation_id: { type: "string" },
  },
  required: ["order_id", "item", "quantity", "correlation_id"],
});

export const ORDER_PLACED: TopicContract<OrderPlaced> = {
  name: ORDERS_TOPIC,
  schema: ORDER_PLACED_SCHEMA,
  partitions: 3,
  key: (order) => order.order_id,
};

export const CONTRACT_EVENTS: NamedContract[] = [
  { module: "OrderPlaced", contract: ORDER_PLACED },
];
