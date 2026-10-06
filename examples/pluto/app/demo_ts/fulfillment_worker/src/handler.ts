import type { SpanContext, trace } from "@opentelemetry/api";
import type pg from "pg";
import type { JobContract } from "@sol-fab/jobs";
import { ACK, fail, type Outcome } from "@sol-fab/kafka";
import { retry, type RetryPolicy } from "@sol-fab/retry";
import type { OrderPlaced } from "@demo-ts/contract";

import { fulfillOrder, type FulfillmentStore } from "./fulfill.js";
import type { LogLine, OrderJob } from "./jobs.js";
import { startChildSpan } from "./tracing.js";

export interface OrderStore extends FulfillmentStore {
  withTransaction<T>(body: (client: pg.PoolClient) => Promise<T>): Promise<T>;
}

/**
 * The worker's bounded retry for a transient Postgres failure, mirroring the
 * OCaml `notify_worker` policy. The transaction is idempotent (`ON CONFLICT DO
 * NOTHING` plus a dedupe-keyed job), so retrying the operation in place is safe.
 */
export const DB_RETRY_POLICY: RetryPolicy = {
  baseDelayS: 0.25,
  maxDelayS: 5.0,
  maxAttempts: 4,
  jitterRatio: 0.25,
};

export interface OrderHandlerDeps {
  store: OrderStore;
  jobs: JobContract<OrderJob>;
  log: LogLine;
  tracer: ReturnType<typeof trace.getTracer>;
  messagesTotal: { inc(labels?: Record<string, string | number>): void };
  messageDuration: { observe(value: number): void };
  /** Overridable for tests; defaults to `DB_RETRY_POLICY`. */
  retryPolicy?: RetryPolicy;
}

export async function handleOrder(
  order: OrderPlaced,
  traceContext: SpanContext | undefined,
  {
    store,
    jobs,
    log,
    tracer,
    messagesTotal,
    messageDuration,
    retryPolicy = DB_RETRY_POLICY,
  }: OrderHandlerDeps,
): Promise<Outcome> {
  const start = process.hrtime.bigint();
  const span = startChildSpan(tracer, "fulfill_order", traceContext);
  try {
    log("info", "fulfilling order", {
      order_id: order.order_id,
      item: order.item,
      quantity: String(order.quantity),
    });

    try {
      await retry(
        () =>
          store.withTransaction(async (client) => {
            await fulfillOrder(store, client, order, jobs);
          }),
        { policy: retryPolicy },
      );
    } catch (err) {
      messagesTotal.inc({ status: "fail" });
      return fail(`db transaction failed after retries: ${String(err)}`);
    }

    console.log(`[worker] fulfilled  order=${order.order_id}  item=${order.item}`);
    messagesTotal.inc({ status: "ok" });
    return ACK;
  } finally {
    span.end();
    messageDuration.observe(Number(process.hrtime.bigint() - start) / 1e9);
  }
}
