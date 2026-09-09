import { test } from "node:test";
import assert from "node:assert/strict";
import { encodeWire, decodeWire, WireFormatError } from "../src/wireFormat.js";

// Bug 3: Confluent wire format -- 5-byte header (magic 0x00 + big-endian
// schema ID), must match kafka_service_schema.ml's Confluent_wire byte-for-byte.

test("wireFormat: round-trips schemaId and json", () => {
  const { schemaId, json } = decodeWire(encodeWire(42, { hello: "world" }));
  assert.equal(schemaId, 42);
  assert.deepEqual(json, { hello: "world" });
});

test("wireFormat: header is exactly magic byte 0x00 + big-endian uint32 schema id", () => {
  const wire = encodeWire(0x01020304, { a: 1 });
  assert.equal(wire.readUInt8(0), 0x00);
  assert.equal(wire.readUInt32BE(1), 0x01020304);
});

test("wireFormat: rejects a message shorter than the 5-byte header", () => {
  assert.throws(() => decodeWire(Buffer.from([0x00, 0x01])), WireFormatError);
});

test("wireFormat: rejects a wrong magic byte", () => {
  const wire = encodeWire(1, { a: 1 });
  wire.writeUInt8(0xff, 0);
  assert.throws(() => decodeWire(wire), WireFormatError);
});

test("wireFormat: rejects malformed JSON payload", () => {
  const header = Buffer.alloc(5);
  header.writeUInt32BE(1, 1);
  const wire = Buffer.concat([header, Buffer.from("not json{", "utf8")]);
  assert.throws(() => decodeWire(wire), WireFormatError);
});
