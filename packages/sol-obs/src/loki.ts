/**
 * Sol's structured-log shape, pushed straight to Loki's HTTP push API.
 * A structured logger like pino turned out not to earn its keep for this
 * (see FEAT-033's findings, "Friction log": the interesting logic is
 * entirely the Loki push shape/labels, not log formatting/performance) --
 * plain console/fetch is used instead. Same wiring the OCaml side's Sol_obs
 * facade does internally.
 *
 * This is a straight extraction of demo_ts/{order_svc,fulfillment_worker}
 * /src/loki.ts, which were byte-for-byte identical duplicates of each
 * other -- this module is now the single shared source of truth.
 */

export type LogFields = Record<string, string>;

export function makeLokiPusher(lokiUrl: string | undefined, service: string) {
  if (!lokiUrl) {
    return (level: string, msg: string, fields: LogFields) => {
      console.log(JSON.stringify({ service, level, msg, ...fields }));
    };
  }

  return (level: string, msg: string, fields: LogFields) => {
    const line = Object.entries({ level, msg, ...fields })
      .map(([k, v]) => `${k}="${String(v).replace(/"/g, '\\"')}"`)
      .join(" ");
    const nanos = String(Date.now()) + "000000";
    const body = {
      streams: [
        {
          stream: { service },
          values: [[nanos, line]],
        },
      ],
    };
    fetch(`${lokiUrl}/loki/api/v1/push`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }).catch((err) => {
      console.error(`[${service}] loki push failed: ${String(err)}`);
    });
  };
}
