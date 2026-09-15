/**
 * Sol's worker outcome contract (sol-worker.md, FEAT-076/078):
 *
 *   Ack | Retry reason | Dead_letter reason
 *
 * The `reason` is diagnostic text only — the runtime never inspects it to
 * decide delay, routing or retryability (FEAT-078's policy-ownership rule).
 * Never encode policy in the string; introduce a typed concept if one is
 * needed. There is no `ack` to call: the framework commits the offset, and
 * only after the outcome is `ack`.
 */

export type Outcome =
  | { readonly kind: "ack" }
  | { readonly kind: "retry"; readonly reason: string }
  | { readonly kind: "dead-letter"; readonly reason: string };

/** The single `Ack` value; the only outcome an Ack-only worker can produce. */
export const ACK: Outcome = Object.freeze({ kind: "ack" });

/** `Retry reason` — route through the configured retry strategy. */
export function retry(reason: string): Outcome {
  return { kind: "retry", reason };
}

/** `Dead_letter reason` — route straight to the DLQ (retry-topics only). */
export function deadLetter(reason: string): Outcome {
  return { kind: "dead-letter", reason };
}
