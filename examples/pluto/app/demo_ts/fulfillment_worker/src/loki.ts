// Identical shape to order_svc/src/loki.ts. Duplicated on purpose for this
// spike — see the FEAT-033 findings doc on whether that duplication is
// itself a candidate-helper signal.

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
