// Same Confluent wire format as order_svc/src/schemaRegistry.ts (Sol/Redpanda
// convention, not a kafkajs feature) plus the OrderPlaced.decode port from
// examples/local-demo/lib/events.ml — required-field validation is how the
// OCaml reference actually enforces the contract at consume time (not a
// separate JSON-schema validator call), so this mirrors that exactly.

const MAGIC_BYTE = 0x00;

export function decodeWire(bytes: Buffer): { schemaId: number; json: unknown } {
  if (bytes.length < 5) throw new Error("wire format: message too short");
  if (bytes.readUInt8(0) !== MAGIC_BYTE) throw new Error("wire format: invalid magic byte");
  const schemaId = bytes.readUInt32BE(1);
  const json = JSON.parse(bytes.subarray(5).toString("utf8"));
  return { schemaId, json };
}

export interface OrderPlaced {
  order_id: string;
  item: string;
  quantity: number;
  correlation_id: string;
}

export function decodeOrderPlaced(json: unknown): OrderPlaced {
  if (typeof json !== "object" || json === null) throw new Error("expected object");
  const j = json as Record<string, unknown>;
  const requiredString = (name: string): string => {
    const v = j[name];
    if (typeof v !== "string") throw new Error(`${name} is required and must be a string`);
    return v;
  };
  // ponytail: JSON.parse collapses "5.0" to the integer 5, so this accepts
  // a payload OCaml's Yojson would reject (`Float 5.0` there, not `Int 5`).
  // Fixing that needs a custom JSON parser preserving numeric literal
  // formatting — not worth it for a spike; a real @sol/kafka package
  // would need to actually decide this, since it's genuine cross-language
  // schema-strictness divergence, not a bug in either side alone.
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
