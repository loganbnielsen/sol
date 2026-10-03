import Fastify from "fastify";
import { makeLokiPusher, routeLabel, statusClassOf } from "@sol-fab/obs";
import { runService, type ServiceLifecycle } from "@sol-fab/svc";
import { makeSvcMetrics } from "./metrics.js";

function intEnv(name: string, fallback: number): number {
  const raw = process.env[name]?.trim();
  if (!raw) return fallback;
  const n = Number(raw);
  return Number.isInteger(n) ? n : fallback;
}

const PORT = intEnv("PORT", 8080);
const log = makeLokiPusher({ lokiUrl: process.env.LOKI_URL, service: "{{binary}}" });
const { register, requestsTotal, requestDuration } = makeSvcMetrics();

const app = Fastify({ logger: false });
let lifecycle: ServiceLifecycle | undefined;

app.addHook("onResponse", async (req, reply) => {
  const route = routeLabel(req.routeOptions?.url);
  requestsTotal.inc({ method: req.method, route, status_class: statusClassOf(reply.statusCode) });
  requestDuration.observe({ method: req.method, route }, reply.elapsedTime / 1000);
});

app.get("/healthz", async () => ({ status: "ok" }));

app.get("/readyz", async (_req, reply) => {
  if (lifecycle?.isReady() ?? true) return { status: "ready" };
  return reply.code(503).send({ status: "shutting down" });
});

app.get("/metrics", async (_req, reply) => {
  reply.header("content-type", register.contentType);
  return register.metrics();
});

app.get("/", async () => ({ status: "ok" }));

async function main() {
  await app.listen({ port: PORT, host: "0.0.0.0" });
  log("info", "listening", { port: String(PORT) });
  lifecycle = runService({
    drain: () => app.close(),
    shutdownHooks: [() => log.flush()],
  });
}

main().catch((err) => {
  console.error(String(err));
  process.exit(1);
});
