// Hand-rolled port of integrations/kafka/kafka-eio-service/lib/kafka_service_schema.ml.
// This is Sol's convention on top of the Confluent-compatible schema registry
// Redpanda exposes on :8081 — kafkajs has no opinion on schema registries at all,
// so every line here is glue a TS app author would have to write themselves.

const MAGIC_BYTE = 0x00;

export function encodeWire(schemaId: number, json: unknown): Buffer {
  const payload = Buffer.from(JSON.stringify(json), "utf8");
  const header = Buffer.alloc(5);
  header.writeUInt8(MAGIC_BYTE, 0);
  header.writeUInt32BE(schemaId, 1);
  return Buffer.concat([header, payload]);
}

async function registryRequest(
  registryUrl: string,
  method: string,
  path: string,
  body: unknown
): Promise<{ status: number; body: string }> {
  const resp = await fetch(`${registryUrl}${path}`, {
    method,
    headers: { "content-type": "application/vnd.schemaregistry.v1+json" },
    body: JSON.stringify(body),
  });
  return { status: resp.status, body: await resp.text() };
}

/**
 * Mirrors kafka_service_schema.ml's set_subject_compatibility exactly — a
 * plain PUT, nothing else. Note: in the real runtime path
 * (Kafka_service.register, kafka_service.ml:172-177) a failure here is
 * NON-FATAL — logged as a warning and ignored, registration proceeds
 * without it. Callers must replicate that: catch and warn, don't let this
 * throw propagate.
 */
export async function setSubjectCompatibility(registryUrl: string, topicName: string): Promise<void> {
  const subject = `${topicName}-value`;
  const { status, body } = await registryRequest(registryUrl, "PUT", `/config/${subject}`, {
    compatibility: "FULL",
  });
  if (status !== 200 && status !== 204) {
    throw new Error(`set compatibility: HTTP ${status}: ${body}`);
  }
}

/**
 * Mirrors kafka_service_schema.ml's register_schema exactly: a plain POST
 * to /subjects/{subject}/versions, nothing composed with it. There is no
 * compatibility-check-then-register flow in the OCaml runtime path — that
 * would be `Schema.check`, which exists only as a standalone CI gate
 * (the generated test_schemas.ml script) and is never called from
 * Kafka_service.register. In the real runtime path this call's failure
 * IS fatal (Kafka_service.register propagates it as an Error) — callers
 * should let it throw.
 */
export async function registerSchema(
  registryUrl: string,
  topicName: string,
  schema: string
): Promise<number> {
  const subject = `${topicName}-value`;
  const reg = await registryRequest(registryUrl, "POST", `/subjects/${subject}/versions`, {
    schemaType: "JSON",
    schema,
  });
  if (reg.status !== 200 && reg.status !== 201) {
    throw new Error(`schema registry: HTTP ${reg.status}: ${reg.body}`);
  }
  const parsed = JSON.parse(reg.body) as { id: number };
  return parsed.id;
}
