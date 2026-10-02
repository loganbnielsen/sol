import { enqueue, type JobContract } from "@sol-fab/jobs";
import type pg from "pg";

export interface ConfirmationJob {
  order_id: string;
}

export function makeConfirmationJobs(log: (level: string, msg: string, fields: Record<string, string>) => void) {
  const contract: JobContract<ConfirmationJob> = {
    workspace: "pluto.demo_ts",
    kinds: ["send_confirmation"],
    kind: () => "send_confirmation",
    encode: (job) => JSON.stringify(job),
    decode: (payload) => JSON.parse(payload) as ConfirmationJob,
    handle: async (job) => {
      log("info", "confirmation sent", { order_id: job.order_id });
    },
  };
  return contract;
}

export async function enqueueConfirmation(
  client: pg.PoolClient,
  contract: JobContract<ConfirmationJob>,
  orderId: string,
): Promise<void> {
  await enqueue(client, contract, { order_id: orderId }, { dedupeKey: orderId });
}
