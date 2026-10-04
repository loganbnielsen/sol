import { enqueue, type JobContract } from "@sol-fab/jobs";
import type pg from "pg";

export const WORKSPACE = "pluto.demo_ts";
export const CONFIRMATION_KIND = "send_confirmation";

export interface ConfirmationJob {
  kind: typeof CONFIRMATION_KIND;
  order_id: string;
}

export function confirmationJobs(): JobContract<ConfirmationJob> {
  return {
    workspace: WORKSPACE,
    kinds: [CONFIRMATION_KIND],
    kind: () => CONFIRMATION_KIND,
    encode: (job) => JSON.stringify(job),
    decode: (payload) => JSON.parse(payload) as ConfirmationJob,
    handle: async () => {
      throw new Error("order_svc enqueues send_confirmation; the fulfillment_worker's job runner executes it");
    },
  };
}

export async function enqueueConfirmation(
  client: pg.PoolClient,
  jobs: JobContract<ConfirmationJob>,
  orderId: string,
): Promise<void> {
  const job: ConfirmationJob = { kind: CONFIRMATION_KIND, order_id: orderId };
  await enqueue(client, jobs, job, { dedupeKey: orderId });
}
