/**
 * The shared retry/DLQ routing decision: outcome + attempt + policy → which
 * topic the record goes to, with which headers and delay.
 *
 * This is its own module on purpose. There is exactly ONE implementation of
 * the routing decision, used by both the source consumer (`retryable.ts`) and
 * the retry-topic relay (`relay.ts`) — neither owns the rule, so the two paths
 * cannot drift. The dependency graph is:
 *
 *   outcome.ts ─┐
 *   retry.ts   ─┴─→ routing.ts ─→ { retryable.ts, relay.ts }
 */
import {
  deadLetterHeaders,
  decideAction,
  relayTopicName,
  retryRecordHeaders,
  type Rng,
  type RetryStrategy,
  type SolHeaders,
} from "./retry.js";
import type { Outcome } from "./outcome.js";

/** The record as received: raw bytes/headers, for re-routing. */
export interface RawRecord {
  readonly key?: Buffer;
  readonly value: Buffer;
  readonly headers: SolHeaders;
}

/** A record to publish to a retry/DLQ topic: the source record's bytes + key. */
export interface RelayRecord {
  readonly topic: string;
  readonly key?: Buffer;
  readonly value: Buffer;
  readonly headers: SolHeaders;
}

/**
 * The publication side, injected so routing is unit-testable without a broker.
 * `publish` rejecting means the durable transfer failed — the input must then
 * be left uncommitted (fail closed), never acked.
 */
export interface RetryRelay {
  publish(record: RelayRecord): Promise<void>;
}

export interface RetryMetrics {
  /** `retry` status: a retry was scheduled (before publication is attempted). */
  onSchedule?: (info: { readonly attempt: number; readonly delayS: number }) => void;
  /** `relay_published` / `relay_failed`: did the relay's own publish land? */
  onRelayPublish?: (info: {
    readonly attempt: number;
    readonly outcome: "published" | "failed";
  }) => void;
}

/**
 * Route one non-Ack outcome, mirroring `Kafka_service_retry_topics.execute_action`.
 * Returns `true` when the message was durably handled (and may be acked),
 * `false` when it must fail closed (nothing durable to transfer to).
 *
 * `attempt` is the already-resolved attempt to record on the target: the
 * source path passes 1; the relay path passes the incremented attempt for a
 * `Retry` and the current attempt for a `Dead_letter` (see the callers).
 */
export async function routeOutcome(
  strategy: RetryStrategy,
  relay: RetryRelay | undefined,
  groupId: string,
  sourceTopic: string,
  raw: RawRecord,
  attempt: number,
  outcome: Outcome,
  metrics: RetryMetrics | undefined,
  nowS: () => number,
  rng: Rng | undefined,
): Promise<boolean> {
  if (strategy.kind === "in-memory") {
    // In_memory has no DLQ: a Dead_letter, or an exhausted retry, fails
    // closed — never acknowledged-and-discarded (acknowledgement-ownership).
    return false;
  }
  const retryTopic = relayTopicName(sourceTopic, groupId, "retry");
  const dlqTopic = relayTopicName(sourceTopic, groupId, "dlq");
  const decision =
    outcome.kind === "dead-letter"
      ? ({ kind: "forward-dlq", target: dlqTopic } as const)
      : decideAction({ retryTopic, dlqTopic, policy: strategy.policy, attempt, rng });

  // decideAction forwards or dead-letters; it never acks (attempt is always
  // >= 1, and at/after maxAttempts it dead-letters). Narrow for the compiler.
  if (decision.kind === "ack") return true;

  const record: RelayRecord =
    decision.kind === "forward-retry"
      ? {
          topic: decision.target,
          key: raw.key,
          value: raw.value,
          headers: retryRecordHeaders({
            originalHeaders: raw.headers,
            attempt,
            delayS: decision.delayS,
            nowS: nowS(),
          }),
        }
      : {
          topic: decision.target,
          key: raw.key,
          value: raw.value,
          headers: deadLetterHeaders({
            originalHeaders: raw.headers,
            attempt,
            groupId,
            nowS: nowS(),
          }),
        };
  if (decision.kind === "forward-retry") {
    metrics?.onSchedule?.({ attempt, delayS: decision.delayS });
  }

  if (!relay) return false; // construction guard in the callers prevents this
  try {
    await relay.publish(record);
    metrics?.onRelayPublish?.({ attempt, outcome: "published" });
    return true;
  } catch {
    metrics?.onRelayPublish?.({ attempt, outcome: "failed" });
    return false;
  }
}
