/**
 * Sol's retry/DLQ policy and record-shape conventions, byte-compatible with
 * the OCaml worker side (FEAT-081). The names and formats here are matched
 * against the OCaml source, not inferred:
 *
 *   - backoff:            framework/kafka-eio-service/lib/kafka_service_retry_topics.ml
 *                         (message_backoff_s) delegating to kafka-eio's
 *                         Kafka.Consumer.backoff_s (lib/kafka_consumer.ml:354)
 *   - topic naming:       kafka_service_retry_topics.ml `relay_topic_name` /
 *                         `canonical_group_segment` / `sanitize_group_id`
 *                         (BUG-030's group-scoping)
 *   - record headers:     kafka_service_retry_topics.ml `retry_message` /
 *                         `dead_letter_message` / `retry_decode_failure_message`
 *
 * Nothing here talks to a broker; the consumer wiring builds on these so the
 * policy and on-the-wire shapes have exactly one implementation.
 */
import { createHash } from "node:crypto";
import type { IHeaders } from "kafkajs";

// ---------------------------------------------------------------------------
// Retry policy
// ---------------------------------------------------------------------------

/** Mirrors kafka-eio's `Kafka.Consumer.retry_policy` (kafka_consumer.ml:333). */
export interface RetryPolicy {
  /** Initial backoff in seconds; doubles on each consecutive failure. */
  readonly baseDelayS: number;
  /** Backoff cap, even after jitter. Worker default: 600 (10 minutes). */
  readonly maxDelayS: number;
  /**
   * Maximum handler invocations, including the initial one. Negative = retry
   * indefinitely; 1 = no retry. Worker default: -1.
   */
  readonly maxAttempts: number;
  /**
   * Symmetric jitter as a fraction of the raw delay, applied *before* the
   * maxDelayS clamp (0.1 = ±10%). 0 disables jitter. Worker default: 0.1.
   */
  readonly jitterRatio: number;
}

/** `Kafka.Consumer.default_retry` (kafka_consumer.ml:340). */
export const DEFAULT_RETRY_POLICY: RetryPolicy = {
  baseDelayS: 1.0,
  maxDelayS: 600.0,
  maxAttempts: -1,
  jitterRatio: 0.1,
};

/**
 * The two explicit retry strategies (FEAT-078: no implicit fallback). There is
 * no third "whatever kafkajs does by default" option — a retry-capable
 * consumer must name one.
 */
export type RetryStrategy =
  | { readonly kind: "in-memory"; readonly policy: RetryPolicy }
  | { readonly kind: "retry-topics"; readonly policy: RetryPolicy };

/** A [0, 1) uniform source; injectable so tests are deterministic. */
export type Rng = () => number;

/**
 * kafka-eio's `Kafka.Consumer.backoff_s` (kafka_consumer.ml:354), reproduced
 * exactly — including the `jitterRatio <= 0` fast path that does not consult
 * the RNG at all, and jitter applied before the clamp:
 *
 *   raw      = baseDelayS * 2^(attempt - 1)
 *   jittered = raw * (1 + (U(0, 2*ratio) - ratio))
 *   delay    = clamp(jittered, 0, maxDelayS)
 */
export function backoffS(policy: RetryPolicy, attempt: number, rng: Rng = Math.random): number {
  const raw = policy.baseDelayS * 2 ** (attempt - 1);
  const clamped = (v: number) => Math.min(policy.maxDelayS, Math.max(0.0, v));
  if (policy.jitterRatio <= 0.0) return clamped(raw);
  const jitterUnit = rng() * (2.0 * policy.jitterRatio);
  const jittered = raw * (1.0 + (jitterUnit - policy.jitterRatio));
  return clamped(jittered);
}

/**
 * `Retry_topics` requires a bounded-ish policy: kafka_service_retry_topics.ml's
 * `consume` rejects `max_attempts < 1` up front, before touching a broker.
 * Returns the error message, or undefined when the policy is valid.
 */
export function retryTopicsPolicyError(policy: RetryPolicy): string | undefined {
  return policy.maxAttempts >= 1
    ? undefined
    : `Retry_topics retry_policy.maxAttempts must be >= 1 (got ${policy.maxAttempts})`;
}

// ---------------------------------------------------------------------------
// Group-scoped retry / DLQ topic naming (BUG-030)
// ---------------------------------------------------------------------------

/** kafka_service_retry_topics.ml `max_group_segment_len`. */
export const MAX_GROUP_SEGMENT_LEN = 64;

/** `sanitize_group_id`: alphanumerics and '-' only; empty becomes "unscoped". */
export function sanitizeGroupId(groupId: string): string {
  const sanitized = groupId.replace(/[^a-zA-Z0-9-]/g, "-");
  return sanitized === "" ? "unscoped" : sanitized;
}

/**
 * `canonical_group_segment`: over-length ids are truncated and given a short
 * MD5 content-hash suffix (first 8 hex chars of `Digest.string`, which is
 * MD5), always — not only on a detected collision — so two different overlong
 * ids can never truncate to the same segment.
 */
export function canonicalGroupSegment(groupId: string): string {
  const sanitized = sanitizeGroupId(groupId);
  if (sanitized.length <= MAX_GROUP_SEGMENT_LEN) return sanitized;
  const hashSuffix = createHash("md5").update(groupId).digest("hex").slice(0, 8);
  const prefixLen = MAX_GROUP_SEGMENT_LEN - hashSuffix.length - 1;
  return `${sanitized.slice(0, prefixLen)}-${hashSuffix}`;
}

/** `relay_topic_name`: `<source>.<canonical-group>.<retry|dlq>`. */
export function relayTopicName(source: string, groupId: string, suffix: "retry" | "dlq"): string {
  return `${source}.${canonicalGroupSegment(groupId)}.${suffix}`;
}

/** The retry consumer's group id (`<group_id>-sol-retry`). */
export function retryConsumerGroupId(groupId: string): string {
  return `${groupId}-sol-retry`;
}

// ---------------------------------------------------------------------------
// Retry record headers
// ---------------------------------------------------------------------------

export const HDR_ATTEMPT = "X-Sol-Attempt";
export const HDR_RETRY_AT = "X-Sol-Retry-At";
export const HDR_DECODE_ERROR = "X-Sol-Decode-Error";
export const HDR_ORIGIN_GROUP = "X-Sol-Origin-Group";

/** Sol's headers, reduced to the single-string form its own records use. */
export type SolHeaders = Record<string, string>;

/**
 * Resolve a kafkajs `IHeaders` down to Sol's flat string form. Multi-valued
 * and Buffer headers are not part of Sol's own contract; the first value wins
 * and Buffers are UTF-8 decoded.
 */
export function solHeadersOf(headers: IHeaders | undefined): SolHeaders {
  const out: SolHeaders = {};
  if (!headers) return out;
  for (const [key, value] of Object.entries(headers)) {
    if (value === undefined) continue;
    const one = Array.isArray(value) ? value[0] : value;
    if (one === undefined) continue;
    out[key] = Buffer.isBuffer(one) ? one.toString("utf8") : one;
  }
  return out;
}

/** `strip_sol_hdrs`: drop a stale attempt / retry-at, keep everything else. */
function stripSolHeaders(headers: SolHeaders): SolHeaders {
  const { [HDR_ATTEMPT]: _attempt, [HDR_RETRY_AT]: _retryAt, ...rest } = headers;
  return rest;
}

/**
 * The numeric seconds since epoch written to `X-Sol-Retry-At`. OCaml writes
 * `string_of_float` and reads with `float_of_string`; the cross-language
 * contract is "parses to the same seconds", not "byte-identical text", so a
 * plain decimal rendering is used. `nowS` is injectable for tests.
 */
export function epochSeconds(nowS: number = Date.now() / 1000): string {
  return String(nowS);
}

export interface RetryRecordOptions {
  /** The source record's headers, before Sol's own are (re)stamped. */
  readonly originalHeaders?: SolHeaders;
  /** The attempt number this record represents (>= 1). */
  readonly attempt: number;
  /** Seconds from now until the record is due. */
  readonly delayS: number;
  /** Injectable "now" in epoch seconds, for deterministic tests. */
  readonly nowS?: number;
}

/**
 * `retry_message`: strip any stale `X-Sol-Attempt`/`X-Sol-Retry-At` from the
 * original headers and stamp fresh ones, attempt first then retry-at.
 */
export function retryRecordHeaders(opts: RetryRecordOptions): SolHeaders {
  const nowS = opts.nowS ?? Date.now() / 1000;
  return {
    [HDR_ATTEMPT]: String(opts.attempt),
    [HDR_RETRY_AT]: epochSeconds(nowS + opts.delayS),
    ...stripSolHeaders(opts.originalHeaders ?? {}),
  };
}

/**
 * `dead_letter_message`: a zero-delay retry record plus `X-Sol-Origin-Group`.
 * Dead-lettering is a statement about *this consumer group's* processing
 * attempt, not an intrinsic property of the event (BUG-030), so the group is
 * recorded even though the topic name is already group-scoped.
 */
export function deadLetterHeaders(
  opts: Omit<RetryRecordOptions, "delayS"> & { readonly groupId: string },
): SolHeaders {
  return {
    [HDR_ORIGIN_GROUP]: opts.groupId,
    ...retryRecordHeaders({ ...opts, delayS: 0.0 }),
  };
}

/**
 * `retry_decode_failure_message`: a retry record that couldn't even be
 * decoded. Its original headers are preserved *untouched* (it is not another
 * scheduled attempt), and the decode diagnostic plus origin group are
 * prepended.
 */
export function retryDecodeFailureHeaders(opts: {
  readonly originalHeaders?: SolHeaders;
  readonly decodeError: string;
  readonly groupId: string;
}): SolHeaders {
  return {
    [HDR_DECODE_ERROR]: opts.decodeError,
    [HDR_ORIGIN_GROUP]: opts.groupId,
    ...(opts.originalHeaders ?? {}),
  };
}

/** `parse_int_hdr`: present, integer, >= 1. */
export function parseAttemptHeader(headers: SolHeaders): number | undefined {
  const raw = headers[HDR_ATTEMPT];
  if (raw === undefined) return undefined;
  const n = Number(raw);
  return Number.isInteger(n) && n >= 1 ? n : undefined;
}

/** `parse_float_hdr`: present, finite. */
export function parseRetryAtHeader(headers: SolHeaders): number | undefined {
  const raw = headers[HDR_RETRY_AT];
  if (raw === undefined) return undefined;
  const n = Number.parseFloat(raw);
  return Number.isFinite(n) ? n : undefined;
}

// ---------------------------------------------------------------------------
// Routing decision
// ---------------------------------------------------------------------------

export type RetryAction =
  | { readonly kind: "ack" }
  | { readonly kind: "forward-retry"; readonly target: string; readonly delayS: number }
  | { readonly kind: "forward-dlq"; readonly target: string };

/**
 * `decide_action`: [attempt] is the already-incremented attempt number that
 * will be committed to the target topic. At or past `maxAttempts`, the
 * message is dead-lettered; otherwise it is forwarded to the retry topic with
 * the policy's backoff for that attempt.
 */
export function decideAction(opts: {
  readonly retryTopic: string;
  readonly dlqTopic: string;
  readonly policy: RetryPolicy;
  readonly attempt: number;
  readonly rng?: Rng;
}): RetryAction {
  if (opts.attempt >= opts.policy.maxAttempts) {
    return { kind: "forward-dlq", target: opts.dlqTopic };
  }
  return {
    kind: "forward-retry",
    target: opts.retryTopic,
    delayS: backoffS(opts.policy, opts.attempt, opts.rng),
  };
}
