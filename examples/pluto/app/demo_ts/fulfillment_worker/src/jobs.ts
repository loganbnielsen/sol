import { enqueue, type JobContract } from "@sol-fab/jobs";
import type pg from "pg";

export const WORKSPACE = "pluto.demo_ts";
export const CONFIRMATION_KIND = "send_confirmation";
export const INVENTORY_KIND = "release_inventory";
export const JOB_KINDS = [CONFIRMATION_KIND, INVENTORY_KIND] as const;

export type OrderJob =
  | { kind: typeof CONFIRMATION_KIND; order_id: string }
  | { kind: typeof INVENTORY_KIND; order_id: string };

export type LogLine = (level: string, msg: string, fields: Record<string, string>) => void;

export interface OrderJobEffects {
  markConfirmed(orderId: string): Promise<void>;
}

export function makeOrderJobs(log: LogLine, effects: OrderJobEffects): JobContract<OrderJob> {
  return {
    workspace: WORKSPACE,
    kinds: JOB_KINDS,
    kind: (job) => job.kind,
    encode: (job) => JSON.stringify(job),
    decode: (payload) => {
      const job = JSON.parse(payload) as OrderJob;
      if (!JOB_KINDS.includes(job.kind)) {
        throw new Error(`unknown job kind ${JSON.stringify(job.kind)}`);
      }
      return job;
    },
    handle: async (job) => {
      if (job.kind === CONFIRMATION_KIND) {
        await effects.markConfirmed(job.order_id);
        log("info", "confirmation sent", { order_id: job.order_id });
        return;
      }
      log("info", "inventory released", { order_id: job.order_id });
    },
  };
}

export async function enqueueOrderJob(
  client: pg.PoolClient,
  contract: JobContract<OrderJob>,
  job: OrderJob,
): Promise<void> {
  await enqueue(client, contract, job, { dedupeKey: job.order_id });
}
