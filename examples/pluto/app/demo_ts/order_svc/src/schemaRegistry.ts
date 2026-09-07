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

/** Mirrors kafka_service_schema.ml's set_subject_compatibility. */
export async function setSubjectCompatibility(registryUrl: string, topicName: string): Promise<void> {
  const subject = `${topicName}-value`;
  const { status, body } = await registryRequest(registryUrl, "PUT", `/config/${subject}`, {
    compatibility: "FULL",
  });
  if (status !== 200 && status !== 204) {
    throw new Error(`set compatibility: HTTP ${status}: ${body}`);
  }
}

/** Mirrors kafka_service_schema.ml's Schema.check — compatibility-check-then-register. */
export async function registerSchema(
  registryUrl: string,
  topicName: string,
  schema: string
): Promise<number> {
  const subject = `${topicName}-value`;

  const compat = await registryRequest(
    registryUrl,
    "POST",
    `/compatibility/subjects/${subject}/versions/latest`,
    { schemaType: "JSON", schema }
  );
  if (compat.status === 200) {
    const parsed = JSON.parse(compat.body) as { is_compatible: boolean };
    if (!parsed.is_compatible) {
      throw new Error(`schema for topic '${topicName}' is not compatible with the registered version`);
    }
  } else if (compat.status !== 404) {
    throw new Error(`schema registry HTTP ${compat.status}: ${compat.body}`);
  }

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
