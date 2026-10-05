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

function requireObject(json: unknown): Record<string, unknown> {
  if (typeof json !== "object" || json === null) throw new Error("expected object");
  return json as Record<string, unknown>;
}

function requireString(fields: Record<string, unknown>, name: string): string {
  const value = fields[name];
  if (typeof value !== "string") throw new Error(`${name} is required and must be a string`);
  return value;
}

function requireInteger(fields: Record<string, unknown>, name: string): number {
  const value = fields[name];
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new Error(`${name} is required and must be an integer`);
  }
  return value;
}

export function decodeOrderPlaced(json: unknown): OrderPlaced {
  const fields = requireObject(json);
  return {
    order_id: requireString(fields, "order_id"),
    item: requireString(fields, "item"),
    quantity: requireInteger(fields, "quantity"),
    correlation_id: requireString(fields, "correlation_id"),
  };
}

export function decodeOrderFulfilled(json: unknown): OrderFulfilled {
  const fields = requireObject(json);
  return {
    order_id: requireString(fields, "order_id"),
    item: requireString(fields, "item"),
    quantity: requireInteger(fields, "quantity"),
    correlation_id: requireString(fields, "correlation_id"),
  };
}
