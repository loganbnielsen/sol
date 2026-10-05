import type { SpanContext, trace } from "@opentelemetry/api";
import type pg from "pg";
import type { JobContract } from "@sol-fab/jobs";
import { ACK, fail, type Outcome } from "@sol-fab/kafka";
import type { OrderPlaced } from "@demo-ts/contract";

import { fulfillOrder, type FulfillmentStore } from "./fulfill.js";
import type { LogLine, OrderJob } from "./jobs.js";
import { startChildSpan } from "./tracing.js";

export interface OrderStore extends FulfillmentStore {
  withTransaction<T>(body: (client: pg.PoolClient) => Promise<T>): Promise<T>;
}

export interface OrderHandlerDeps {
  store: OrderStore;
  jobs: JobContract<OrderJob>;
  log: LogLine;
  tracer: ReturnType<typeof trace.getTracer>;
  messagesTotal: { inc(labels?: Record<string, string | number>): void };
  messageDuration: { observe(value: number): void };
}

export async function handleOrder(
  order: OrderPlaced,
  traceContext: SpanContext | undefined,
  { store, jobs, log, tracer, messagesTotal, messageDuration }: OrderHandlerDeps,
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
      await store.withTransaction(async (client) => {
        await fulfillOrder(store, client, order, jobs);
      });
    } catch (err) {
      messagesTotal.inc({ status: "fail" });
      return fail(`db: ${String(err)}`);
    }

    console.log(`[worker] fulfilled  order=${order.order_id}  item=${order.item}`);
    messagesTotal.inc({ status: "ok" });
    return ACK;
  } finally {
    span.end();
    messageDuration.observe(Number(process.hrtime.bigint() - start) / 1e9);
  }
}
