import { test } from "node:test";
import assert from "node:assert/strict";
import { makeLokiPusher } from "../src/loki.js";

test("with no lokiUrl, falls back to structured console.log, no fetch", () => {
  const logs: string[] = [];
  const originalLog = console.log;
  console.log = (line: string) => logs.push(line);
  try {
    const push = makeLokiPusher(undefined, "order-svc");
    push("info", "hello", { orderId: "123" });
  } finally {
    console.log = originalLog;
  }
  assert.equal(logs.length, 1);
  const parsed = JSON.parse(logs[0]);
  assert.equal(parsed.service, "order-svc");
  assert.equal(parsed.level, "info");
  assert.equal(parsed.msg, "hello");
  assert.equal(parsed.orderId, "123");
});

test("with a lokiUrl, pushes to the Loki HTTP push API with the expected stream shape", async () => {
  const calls: { url: string; body: unknown }[] = [];
  const originalFetch = globalThis.fetch;
  // @ts-expect-error -- test stub, narrower than the real fetch signature
  globalThis.fetch = async (url: string, opts: { body: string }) => {
    calls.push({ url, body: JSON.parse(opts.body) });
    return { ok: true } as Response;
  };
  try {
    const push = makeLokiPusher("http://loki.local", "fulfillment-worker");
    push("error", "boom", { orderId: "456" });
    await new Promise((resolve) => setTimeout(resolve, 0));
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "http://loki.local/loki/api/v1/push");
  const body = calls[0].body as { streams: { stream: Record<string, string>; values: string[][] }[] };
  assert.equal(body.streams[0].stream.service, "fulfillment-worker");
  assert.match(body.streams[0].values[0][1], /level="error"/);
  assert.match(body.streams[0].values[0][1], /orderId="456"/);
});
