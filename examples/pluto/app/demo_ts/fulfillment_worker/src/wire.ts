import type { OrderFulfilled, OrderPlaced } from "@demo-ts/contract";

function decodeOrder(json: unknown): OrderPlaced {
  if (typeof json !== "object" || json === null) throw new Error("expected object");
  const j = json as Record<string, unknown>;
  const requiredString = (name: string): string => {
    const v = j[name];
    if (typeof v !== "string") throw new Error(`${name} is required and must be a string`);
    return v;
  };
  const requiredInt = (name: string): number => {
    const v = j[name];
    if (typeof v !== "number" || !Number.isInteger(v)) {
      throw new Error(`${name} is required and must be an integer`);
    }
    return v;
  };
  return {
    order_id: requiredString("order_id"),
    item: requiredString("item"),
    quantity: requiredInt("quantity"),
    correlation_id: requiredString("correlation_id"),
  };
}

export function decodeOrderPlaced(json: unknown): OrderPlaced {
  return decodeOrder(json);
}

export function decodeOrderFulfilled(json: unknown): OrderFulfilled {
  return decodeOrder(json);
}
