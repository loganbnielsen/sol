import { test } from "node:test";
import assert from "node:assert/strict";
import {
  DEFAULT_RETRY_POLICY,
  HDR_ATTEMPT,
  HDR_DECODE_ERROR,
  HDR_ORIGIN_GROUP,
  HDR_RETRY_AT,
  MAX_GROUP_SEGMENT_LEN,
  backoffS,
  canonicalGroupSegment,
  deadLetterHeaders,
  decideAction,
  parseAttemptHeader,
  parseRetryAtHeader,
  relayTopicName,
  retryConsumerGroupId,
  retryDecodeFailureHeaders,
  retryRecordHeaders,
  retryTopicsPolicyError,
  sanitizeGroupId,
  type RetryPolicy,
} from "../src/retry.js";

// FEAT-081: parity with the OCaml retry/DLQ conventions
// (framework/kafka-eio-service/lib/kafka_service_retry_topics.ml and
// kafka-eio's Kafka.Consumer.backoff_s). These assertions pin the exact
// values the OCaml side produces, so a drift on either side fails here rather
// than silently splitting retry/DLQ topics or header semantics between
// languages.

const policy = (over: Partial<RetryPolicy> = {}): RetryPolicy => ({ ...DEFAULT_RETRY_POLICY, ...over });

test("sanitizeGroupId: alphanumerics and '-' survive; everything else becomes '-'; empty is 'unscoped'", () => {
  assert.equal(sanitizeGroupId("orders.worker"), "orders-worker");
  assert.equal(sanitizeGroupId("a_b/c d"), "a-b-c-d");
  assert.equal(sanitizeGroupId("keep-ALREADY-123"), "keep-ALREADY-123");
  assert.equal(sanitizeGroupId(""), "unscoped");
  assert.equal(sanitizeGroupId("._."), "---");
});

test("canonicalGroupSegment: at/below the cap the sanitized id is used unchanged", () => {
  assert.equal(canonicalGroupSegment("orders.worker"), "orders-worker");
  const exactly64 = "x".repeat(MAX_GROUP_SEGMENT_LEN);
  assert.equal(canonicalGroupSegment(exactly64), exactly64);
});

test("canonicalGroupSegment: over-length ids truncate to 55 chars + '-' + first 8 hex of MD5", () => {
  // Fixtures computed independently (python3 hashlib.md5), not by this code.
  assert.equal(
    canonicalGroupSegment("g".repeat(70)),
    "g".repeat(55) + "-d63aff78",
  );
  assert.equal(
    canonicalGroupSegment("Group.One_" + "x".repeat(60)),
    "Group-One-" + "x".repeat(45) + "-237aac25",
  );
  // Distinct overlong ids must never truncate to the same segment.
  const a = canonicalGroupSegment("a".repeat(64) + "1");
  const b = canonicalGroupSegment("a".repeat(64) + "2");
  assert.notEqual(a, b);
});

test("relayTopicName / retryConsumerGroupId match the OCaml naming", () => {
  assert.equal(relayTopicName("orders", "payments", "retry"), "orders.payments.retry");
  assert.equal(relayTopicName("orders", "payments", "dlq"), "orders.payments.dlq");
  assert.equal(relayTopicName("orders", "orders.worker", "retry"), "orders.orders-worker.retry");
  assert.equal(retryConsumerGroupId("payments"), "payments-sol-retry");
});

test("backoffS: jitterRatio 0 is the un-jittered exponential, and never consults the RNG", () => {
  let calls = 0;
  const rng = () => {
    calls += 1;
    return 0.5;
  };
  const p = policy({ baseDelayS: 1.0, maxDelayS: 600.0, jitterRatio: 0.0 });
  assert.equal(backoffS(p, 1, rng), 1);
  assert.equal(backoffS(p, 2, rng), 2);
  assert.equal(backoffS(p, 3, rng), 4);
  assert.equal(calls, 0, "the zero-jitter fast path must not touch the RNG");
});

test("backoffS: symmetric jitter is applied before the clamp", () => {
  const p = policy({ baseDelayS: 1.0, maxDelayS: 600.0, jitterRatio: 0.1 });
  // rng()=0 -> U(0, 0.2)=0 -> raw*(1-0.1); rng()=1 -> raw*(1+0.1)
  assert.equal(backoffS(p, 1, () => 0), 0.9);
  assert.ok(Math.abs(backoffS(p, 1, () => 1) - 1.1) < 1e-12);
});

test("backoffS: never exceeds maxDelayS, never below 0, and is deterministic given an rng", () => {
  const p = policy({ baseDelayS: 1.0, maxDelayS: 10.0, jitterRatio: 0.5 });
  for (let attempt = 1; attempt <= 20; attempt += 1) {
    for (const u of [0, 0.25, 0.5, 0.75, 0.999999]) {
      const d = backoffS(p, attempt, () => u);
      assert.ok(d >= 0, `delay ${d} < 0`);
      assert.ok(d <= p.maxDelayS, `delay ${d} > maxDelayS`);
    }
  }
  const seq = [0.1, 0.9, 0.4];
  let i = 0;
  const rng = () => seq[i++ % seq.length];
  const first = backoffS(p, 3, rng);
  i = 0;
  assert.equal(backoffS(p, 3, rng), first, "same rng sequence -> same delay");
});

test("retryTopicsPolicyError rejects maxAttempts < 1 (kafka_service_retry_topics.ml)", () => {
  assert.equal(retryTopicsPolicyError(policy({ maxAttempts: -1 })), "Retry_topics retry_policy.maxAttempts must be >= 1 (got -1)");
  assert.equal(retryTopicsPolicyError(policy({ maxAttempts: 0 })), "Retry_topics retry_policy.maxAttempts must be >= 1 (got 0)");
  assert.equal(retryTopicsPolicyError(policy({ maxAttempts: 1 })), undefined);
  assert.equal(retryTopicsPolicyError(policy({ maxAttempts: 5 })), undefined);
});

test("retryRecordHeaders: strips stale Sol attempt/retry-at and stamps fresh ones, keeping other headers", () => {
  const headers = retryRecordHeaders({
    originalHeaders: {
      [HDR_ATTEMPT]: "3",
      [HDR_RETRY_AT]: "1",
      [HDR_ORIGIN_GROUP]: "keep-me",
      "x-correlation-id": "abc",
    },
    attempt: 4,
    delayS: 2,
    nowS: 1000,
  });
  assert.equal(headers[HDR_ATTEMPT], "4");
  assert.equal(headers[HDR_RETRY_AT], "1002");
  assert.equal(headers[HDR_ORIGIN_GROUP], "keep-me");
  assert.equal(headers["x-correlation-id"], "abc");
});

test("deadLetterHeaders: zero delay plus X-Sol-Origin-Group", () => {
  const headers = deadLetterHeaders({ attempt: 2, groupId: "orders.worker", originalHeaders: { a: "b" }, nowS: 500 });
  assert.equal(headers[HDR_ORIGIN_GROUP], "orders.worker");
  assert.equal(headers[HDR_ATTEMPT], "2");
  assert.equal(headers[HDR_RETRY_AT], "500"); // delay 0 -> due now
  assert.equal(headers.a, "b");
});

test("retryDecodeFailureHeaders: preserves the original headers untouched (not another scheduled attempt)", () => {
  const headers = retryDecodeFailureHeaders({
    originalHeaders: { [HDR_ATTEMPT]: "2", [HDR_RETRY_AT]: "999", keep: "yes" },
    decodeError: "quantity is required",
    groupId: "orders.worker",
  });
  assert.equal(headers[HDR_DECODE_ERROR], "quantity is required");
  assert.equal(headers[HDR_ORIGIN_GROUP], "orders.worker");
  // untouched: the original attempt/retry-at survive this path
  assert.equal(headers[HDR_ATTEMPT], "2");
  assert.equal(headers[HDR_RETRY_AT], "999");
  assert.equal(headers.keep, "yes");
});

test("parseAttemptHeader / parseRetryAtHeader: missing and malformed values are rejected", () => {
  assert.equal(parseAttemptHeader({}), undefined);
  assert.equal(parseAttemptHeader({ [HDR_ATTEMPT]: "0" }), undefined);
  assert.equal(parseAttemptHeader({ [HDR_ATTEMPT]: "abc" }), undefined);
  assert.equal(parseAttemptHeader({ [HDR_ATTEMPT]: "1" }), 1);
  assert.equal(parseRetryAtHeader({}), undefined);
  assert.equal(parseRetryAtHeader({ [HDR_RETRY_AT]: "NaN" }), undefined);
  assert.equal(parseRetryAtHeader({ [HDR_RETRY_AT]: "Infinity" }), undefined);
  assert.equal(parseRetryAtHeader({ [HDR_RETRY_AT]: "1758000000.25" }), 1758000000.25);
});

test("decideAction: forwards to retry below max attempts, dead-letters at/after it", () => {
  const p = policy({ baseDelayS: 1.0, maxDelayS: 600.0, maxAttempts: 3, jitterRatio: 0.0 });
  const opts = { retryTopic: "orders.orders-worker.retry", dlqTopic: "orders.orders-worker.dlq", policy: p };
  assert.deepEqual(decideAction({ ...opts, attempt: 1 }), { kind: "forward-retry", target: opts.retryTopic, delayS: 1 });
  assert.deepEqual(decideAction({ ...opts, attempt: 2 }), { kind: "forward-retry", target: opts.retryTopic, delayS: 2 });
  assert.deepEqual(decideAction({ ...opts, attempt: 3 }), { kind: "forward-dlq", target: opts.dlqTopic });
  assert.deepEqual(decideAction({ ...opts, attempt: 4 }), { kind: "forward-dlq", target: opts.dlqTopic });
});
