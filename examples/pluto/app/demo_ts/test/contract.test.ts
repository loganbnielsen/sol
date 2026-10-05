import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ORDER_FULFILLED,
  ORDER_PLACED,
  decodeOrderFulfilled,
  decodeOrderPlaced,
} from "../contract/src/index.js";

const placed = { order_id: "o-1", item: "widget", quantity: 3, correlation_id: "c-1" };
const fulfilled = { order_id: "o-1", item: "widget", quantity: 3, correlation_id: "c-1" };

test("OrderPlaced decoder accepts a complete event", () => {
  assert.deepEqual(decodeOrderPlaced(placed), placed);
});

test("OrderFulfilled decoder accepts a complete event", () => {
  assert.deepEqual(decodeOrderFulfilled(fulfilled), fulfilled);
});

test("the publishing contracts come from the same package as the decoders", () => {
  assert.equal(ORDER_PLACED.name, "sol-demo-ts-orders");
  assert.equal(ORDER_FULFILLED.name, "sol-demo-ts-fulfilled");
});

test("OrderPlaced decoder rejects non-objects", () => {
  assert.throws(() => decodeOrderPlaced(null), /expected object/);
  assert.throws(() => decodeOrderPlaced("nope"), /expected object/);
  assert.throws(() => decodeOrderPlaced(undefined), /expected object/);
});

test("OrderFulfilled decoder rejects non-objects", () => {
  assert.throws(() => decodeOrderFulfilled(null), /expected object/);
  assert.throws(() => decodeOrderFulfilled(42), /expected object/);
});

test("OrderPlaced decoder rejects a missing field", () => {
  const missing: Record<string, unknown> = { ...placed };
  delete missing.item;
  assert.throws(() => decodeOrderPlaced(missing), /item is required and must be a string/);
});

test("OrderPlaced decoder rejects a wrong-typed field", () => {
  assert.throws(() => decodeOrderPlaced({ ...placed, quantity: "3" }), /quantity is required and must be an integer/);
  assert.throws(() => decodeOrderPlaced({ ...placed, item: 7 }), /item is required and must be a string/);
});

test("OrderFulfilled decoder rejects a missing field", () => {
  const missing: Record<string, unknown> = { ...fulfilled };
  delete missing.correlation_id;
  assert.throws(
    () => decodeOrderFulfilled(missing),
    /correlation_id is required and must be a string/,
  );
});

test("OrderFulfilled decoder rejects a wrong-typed field", () => {
  assert.throws(
    () => decodeOrderFulfilled({ ...fulfilled, quantity: 2.5 }),
    /quantity is required and must be an integer/,
  );
  assert.throws(
    () => decodeOrderFulfilled({ ...fulfilled, order_id: null }),
    /order_id is required and must be a string/,
  );
});
