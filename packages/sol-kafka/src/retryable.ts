/**
 * The retry-capable consumer wrapper — Sol's `RETRYABLE_WORKER` tier
 * (FEAT-078) on the TypeScript side. The Ack-only tier is the existing
 * `wrapEachMessage`: its handler returns `void`, so it cannot express
 * `Retry`/`Dead_letter` at all, and there is no retry strategy to select.
 *
 * FEAT-078 removed the *implicit* retry fallback on the OCaml side. Here the
 * same property holds structurally: a retry-capable worker must name a
 * `retryStrategy`, and `retry-topics` additionally requires a relay — a
 * missing destination is a construction error, never a per-message runtime
 * surprise discovered the first time something fails.
 *
 * The routing/record-shape logic lives here and is exercised by unit tests
 * through an injected `RetryRelay`; the kafkajs wiring is in `relay.ts`.
 */
import type { EachMessagePayload } from "kafkajs";
import { extractTraceparent } from "@sol/obs";
import { decodeWire, WireFormatError } from "./wireFormat.js";
import type { DecodeErrorCounter, MessageHandlerContext } from "./consume.js";
import type { Outcome } from "./outcome.js";
import {
  backoffS,
  deadLetterHeaders,
  decideAction,
  relayTopicName,
  retryRecordHeaders,
  retryTopicsPolicyError,
  solHeadersOf,
  type RetryStrategy,
  type Rng,
  type SolHeaders,
} from "./retry.js";

/** A record to publish to a retry/DLQ topic: the source record's bytes + key. */
export interface RelayRecord {
  readonly topic: string;
  readonly key?: Buffer;
  readonly value: Buffer;
  readonly headers: SolHeaders;
}

/**
 * The publication side, injected so routing is unit-testable without a
 * broker. `publish` rejecting means the durable transfer failed — the offset
 * must then be left uncommitted (fail closed), never acked.
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

export interface RetryableMessageOptions<T> {
  decode: (json: unknown) => T;
  decodeErrorCounter: DecodeErrorCounter;
  onDecodeError?: (err: unknown) => void;
  retryStrategy: RetryStrategy;
  /** The consumer group id; retry/DLQ topics are scoped to it (BUG-030). */
  groupId: string;
  /** The source topic name, for `<source>.<group>.retry|dlq`. */
  sourceTopic: string;
  /** Required by `retry-topics`; ignored by `in-memory`. */
  relay?: RetryRelay;
  metrics?: RetryMetrics;
  /** Injectable sleep/clock/rng (tests). */
  sleep?: (seconds: number) => Promise<void>;
  nowS?: () => number;
  rng?: Rng;
  handler: (ctx: MessageHandlerContext<T> & { readonly attempt: number }) => Promise<Outcome>;
}

const defaultSleep = (seconds: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, Math.max(0, seconds) * 1000));

/** Internal: the decoded record plus its raw bytes/headers, for re-routing. */
interface RawRecord {
  readonly key?: Buffer;
  readonly value: Buffer;
  readonly headers: SolHeaders;
}

/**
 * Route one non-Ack outcome, mirroring `Kafka_service_retry_topics.execute_action`.
 * Returns `true` when the message was durably handled (and may be acked),
 * `false` when it must fail closed (nothing durable to transfer to).
 */
async function route(
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

  if (!relay) return false; // construction guard below prevents this
  try {
    await relay.publish(record);
    metrics?.onRelayPublish?.({ attempt, outcome: "published" });
    return true;
  } catch {
    metrics?.onRelayPublish?.({ attempt, outcome: "failed" });
    return false;
  }
}

function assertStrategyUsable(opts: { retryStrategy: RetryStrategy; relay?: RetryRelay }): void {
  if (opts.retryStrategy.kind !== "retry-topics") return;
  const err = retryTopicsPolicyError(opts.retryStrategy.policy);
  if (err) throw new Error(`sol-kafka: ${err}`);
  if (!opts.relay) {
    throw new Error("sol-kafka: retry-topics strategy requires a relay (no implicit destination)");
  }
}

/**
 * Source-topic consumer: decode, then run the handler. Mirrors
 * `kafka_service_retry_topics.decode_and_handle` (the source path decides at
 * attempt 1). On `retry-topics`, a successfully published retry/DLQ record
 * lets the offset commit; a failed publish throws so the offset is left
 * uncommitted.
 */
export function wrapEachRetryableMessage<T>(opts: RetryableMessageOptions<T>) {
  assertStrategyUsable(opts);
  const sleep = opts.sleep ?? defaultSleep;
  const nowS = opts.nowS ?? (() => Date.now() / 1000);
  const policy = opts.retryStrategy.policy;

  return async ({ message }: EachMessagePayload): Promise<void> => {
    let decoded: T;
    try {
      if (!message.value) throw new WireFormatError("tombstone (message has no value)");
      decoded = opts.decode(decodeWire(message.value).json);
    } catch (err) {
      opts.decodeErrorCounter.inc();
      opts.onDecodeError?.(err);
      return; // reject: never retried, never reaches the handler
    }

    const raw: RawRecord = {
      key: message.key ?? undefined,
      value: message.value,
      headers: solHeadersOf(message.headers),
    };
    const traceContext = extractTraceparent(message.headers?.traceparent?.toString());

    for (let attempt = 1; ; attempt += 1) {
      const outcome = await opts.handler({ message: decoded, traceContext, attempt });
      if (outcome.kind === "ack") return;

      if (opts.retryStrategy.kind === "retry-topics") {
        const acked = await route(
          opts.retryStrategy, opts.relay, opts.groupId, opts.sourceTopic,
          raw, attempt, outcome, opts.metrics, nowS, opts.rng,
        );
        if (acked) return;
        throw new Error(`sol-kafka: retry/DLQ publish failed at attempt ${attempt}; not acking`);
      }

      // In_memory: sleep and re-run within this handler, bounded by maxAttempts.
      if (outcome.kind === "dead-letter" || attempt >= policy.maxAttempts) {
        throw new Error(
          `sol-kafka: ${outcome.kind} at attempt ${attempt} under in-memory retry; not acking`,
        );
      }
      await sleep(backoffS(policy, attempt, opts.rng));
    }
  };
}
