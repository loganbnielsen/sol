import type { Kafka } from "kafkajs";
import { registerSchema, setSubjectCompatibility } from "./schemaRegistry.js";

export interface RegisterTopicOptions {
  kafka: Kafka;
  registryUrl: string;
  topicName: string;
  schema: string;
  partitions?: number; // matches Kafka_service_config's default of 1 (kafka_service_config.ml:16)
  replicationFactor?: number;
}

export interface RegisteredTopic {
  topicName: string;
  schemaId: number;
}

/**
 * The single entry point for bringing a topic into existence and registering
 * its schema, in the exact order and fatality split Kafka_service.register
 * requires (kafka_service.ml:144-178):
 *
 *   1. ensure_topic (idempotent create) -- BEFORE touching the schema
 *      registry. Relying on broker auto-create-on-produce works locally
 *      (Redpanda has it on by default) but fails hard with
 *      UNKNOWN_TOPIC_OR_PARTITION on any cluster with
 *      auto.create.topics.enable=false.
 *   2. register_schema -- FATAL. A caller MUST let this throw; there is no
 *      valid way to publish to this topic without a registered schema.
 *   3. set_subject_compatibility -- NON-FATAL. Some registries don't support
 *      configuring compatibility; failure here is logged as a warning and
 *      registration proceeds regardless.
 *
 * This is deliberately one function, not three independently-callable steps
 * exported at this ordering -- FEAT-033's hand-rolled TS port got the order
 * and fatality backwards on its first draft (compatibility-check-then-
 * register, both treated as fatal), and only caught it via adversarial
 * review reading the OCaml source line by line. Encoding the policy in the
 * function's own control flow removes the chance to get it wrong.
 */
export async function registerTopic(opts: RegisterTopicOptions): Promise<RegisteredTopic> {
  const partitions = opts.partitions ?? 1;
  const replicationFactor = opts.replicationFactor ?? 1;

  const admin = opts.kafka.admin();
  await admin.connect();
  try {
    // createTopics resolves false (not an error) if the topic already
    // exists -- same idempotent shape as ensure_topic.
    await admin.createTopics({
      topics: [{ topic: opts.topicName, numPartitions: partitions, replicationFactor }],
    });
  } finally {
    await admin.disconnect();
  }

  const schemaId = await registerSchema(opts.registryUrl, opts.topicName, opts.schema);

  try {
    await setSubjectCompatibility(opts.registryUrl, opts.topicName);
  } catch (err) {
    console.warn(
      `[sol-kafka] warn: could not set schema compatibility for ${opts.topicName}: ${String(err)}`
    );
  }

  return { topicName: opts.topicName, schemaId };
}
