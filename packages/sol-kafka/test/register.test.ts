import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { registerTopic } from "../src/register.js";
import type { Kafka } from "kafkajs";

// Bugs 1 + 2: registerTopic must, in this exact order:
//   1. createTopics (topic provisioning) -- BEFORE any schema-registry call
//   2. registerSchema -- FATAL, must propagate on failure
//   3. setSubjectCompatibility -- NON-FATAL, must swallow failure (warn only)
// FEAT-033's hand-rolled port got the order and fatality backwards on its
// first draft (compatibility-check-then-register, both fatal).

function fakeKafka(createTopics: () => Promise<boolean>): Kafka {
  return {
    admin: () => ({
      connect: async () => {},
      disconnect: async () => {},
      createTopics,
    }),
  } as unknown as Kafka;
}

test("registerTopic: provisions the topic before touching the schema registry", async (t) => {
  const calls: string[] = [];
  const kafka = fakeKafka(async () => {
    calls.push("createTopics");
    return true;
  });
  const fetchMock = t.mock.method(global, "fetch", async (url: string, init: RequestInit) => {
    calls.push(init.method === "POST" ? "registerSchema" : "setCompatibility");
    if ((init.method as string) === "POST") {
      return new Response(JSON.stringify({ id: 7 }), { status: 200 });
    }
    return new Response("", { status: 204 });
  });

  const result = await registerTopic({
    kafka,
    registryUrl: "http://registry",
    topicName: "orders",
    schema: "{}",
  });

  assert.deepEqual(calls, ["createTopics", "registerSchema", "setCompatibility"]);
  assert.equal(result.schemaId, 7);
  fetchMock.mock.restore();
});

test("registerTopic: registerSchema failure is FATAL and propagates", async (t) => {
  const kafka = fakeKafka(async () => true);
  const fetchMock = t.mock.method(global, "fetch", async () => new Response("boom", { status: 500 }));

  await assert.rejects(() =>
    registerTopic({ kafka, registryUrl: "http://registry", topicName: "orders", schema: "{}" })
  );
  fetchMock.mock.restore();
});

test("registerTopic: setSubjectCompatibility failure is NON-FATAL and does not throw", async (t) => {
  const kafka = fakeKafka(async () => true);
  let call = 0;
  const fetchMock = t.mock.method(global, "fetch", async () => {
    call += 1;
    if (call === 1) return new Response(JSON.stringify({ id: 3 }), { status: 200 }); // registerSchema ok
    return new Response("registry does not support this", { status: 500 }); // setSubjectCompatibility fails
  });

  const result = await registerTopic({
    kafka,
    registryUrl: "http://registry",
    topicName: "orders",
    schema: "{}",
  });
  assert.equal(result.schemaId, 3); // did not throw despite compatibility failure
  fetchMock.mock.restore();
});
