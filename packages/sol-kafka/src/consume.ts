import type { Consumer, EachMessagePayload } from "kafkajs";
import type { SpanContext } from "@opentelemetry/api";
import { decodeWire, WireFormatError } from "./wireFormat.js";
import { extractTraceparent } from "@sol/obs";

export interface DecodeErrorCounter {
  inc(): void;
}

export interface MessageHandlerContext<T> {
  message: T;
  traceContext: SpanContext | undefined;
}

/**
 * Wraps a kafkajs eachMessage handler with Sol's decode/reject/retry policy
 * (kafka_service_intf.ml's wrap_on_decode_error + worker.ml's messages_total
 * split), so the two failure classes below can't be conflated by a caller:
 *
 *   - Decode/validation failure: the message will never become valid no
 *     matter how many times it's redelivered. This is a REJECTION, not a
 *     crash and not a retry -- decodeErrorCounter.inc() fires, the offset is
 *     implicitly committed (this function returns normally, kafkajs commits),
 *     and `decode`/`handler` is never invoked for this message. It is NOT a
 *     messages_total status value -- real worker.ml intercepts it before the
 *     handler ever runs, so it must not share a label with success/failure.
 *   - Handler failure (e.g. a downstream DB error) on an otherwise-valid
 *     message: this function re-throws, so kafkajs's own retry policy
 *     retries the message rather than silently treating it as rejected.
 *
 * FEAT-033's hand-rolled TS port got this wrong twice across two independent
 * adversarial review rounds -- first conflating both failure classes under
 * one label, then (separately, see wireCrashListener below) exiting on every
 * consumer crash including ones kafkajs was already self-healing from. This
 * is the single clearest piece of evidence that this policy doesn't transfer
 * by "just writing idiomatic TypeScript" -- it's worth encoding once.
 */
export function wrapEachMessage<T>(opts: {
  /** Validate/transform the decoded wire JSON into T; throw (or return an Error) to reject. */
  decode: (json: unknown) => T;
  decodeErrorCounter: DecodeErrorCounter;
  onDecodeError?: (err: unknown) => void;
  handler: (ctx: MessageHandlerContext<T>) => Promise<void>;
}) {
  return async ({ message }: EachMessagePayload): Promise<void> => {
    let decoded: T;
    try {
      if (!message.value) throw new WireFormatError("tombstone (message has no value)");
      const { json } = decodeWire(message.value);
      decoded = opts.decode(json);
    } catch (err) {
      opts.decodeErrorCounter.inc();
      opts.onDecodeError?.(err);
      return; // reject: never retried, never reaches the handler
    }

    const traceparent = message.headers?.traceparent?.toString();
    // handler failures propagate (rethrow) so kafkajs retries; decode
    // failures never reach this point at all.
    await opts.handler({ message: decoded, traceContext: extractTraceparent(traceparent) });
  };
}

/**
 * Wires a consumer's CRASH listener with Sol's exit policy: kafkajs already
 * self-heals from retriable errors (it sets payload.restart=true and
 * reschedules start() itself after a backoff). Exiting unconditionally on
 * every crash -- as an earlier draft of FEAT-033's port did -- kills the
 * process on crashes kafkajs was already about to recover from on its own.
 * Only exit when kafkajs itself has given up (payload.restart === false),
 * so k8s restarts the pod instead of it quietly stopping progress forever.
 */
export function wireCrashListener(consumer: Consumer, opts?: { onCrash?: (error: unknown) => void }): void {
  consumer.on(consumer.events.CRASH, ({ payload }) => {
    opts?.onCrash?.(payload.error);
    if (!payload.restart) process.exit(1);
  });
}
