import type { NamedContract, TopicContract } from "@sol-fab/kafka";

import {
  OrderFulfilledSpec,
  OrderPlacedSpec,
  generatedContract,
} from "./demo_ts_contract.js";

export interface OrderPlaced {
  order_id: string;
  item: string;
  quantity: number;
  correlation_id: string;
}

export interface OrderFulfilled {
  order_id: string;
  item: string;
  quantity: number;
  correlation_id: string;
}

export const ORDER_PLACED: TopicContract<OrderPlaced> = generatedContract<OrderPlaced>(OrderPlacedSpec);
export const ORDER_FULFILLED: TopicContract<OrderFulfilled> = generatedContract<OrderFulfilled>(OrderFulfilledSpec);

export const CONTRACT_EVENTS: NamedContract[] = [
  { module: "OrderPlaced", contract: ORDER_PLACED },
  { module: "OrderFulfilled", contract: ORDER_FULFILLED },
];
