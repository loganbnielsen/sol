// Confluent wire format: a 5-byte header (1-byte magic 0x00 + 4-byte
// big-endian schema ID) prepended to the JSON payload. Matches
// framework/kafka-eio-service/lib/kafka_service_schema.ml's Confluent_wire
// module byte-for-byte -- this is the one piece of the policy layer that's
// actually a wire protocol, not a Sol-specific decision, so getting it wrong
// breaks interop with any OCaml service reading the same topic.

const MAGIC_BYTE = 0x00;
const HEADER_LEN = 5;

export function encodeWire(schemaId: number, json: unknown): Buffer {
  const payload = Buffer.from(JSON.stringify(json), "utf8");
  const header = Buffer.alloc(HEADER_LEN);
  header.writeUInt8(MAGIC_BYTE, 0);
  header.writeUInt32BE(schemaId, 1);
  return Buffer.concat([header, payload]);
}

export class WireFormatError extends Error {}

export function decodeWire(bytes: Buffer): { schemaId: number; json: unknown } {
  if (bytes.length < HEADER_LEN) {
    throw new WireFormatError("wire format: message too short");
  }
  if (bytes.readUInt8(0) !== MAGIC_BYTE) {
    throw new WireFormatError("wire format: invalid magic byte");
  }
  const schemaId = bytes.readUInt32BE(1);
  const jsonStr = bytes.subarray(HEADER_LEN).toString("utf8");
  let json: unknown;
  try {
    json = JSON.parse(jsonStr);
  } catch (err) {
    throw new WireFormatError(`wire format: json parse: ${String(err)}`);
  }
  return { schemaId, json };
}
