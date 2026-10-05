export function setting(name: string): string | undefined {
  const value = process.env[name]?.trim();
  return value ? value : undefined;
}

export function intEnv(name: string, fallback: number): number {
  const raw = setting(name);
  if (raw === undefined) return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n)) {
    throw new Error(`${name}=${JSON.stringify(raw)} is not a number`);
  }
  return n;
}

export function requiredPostgresUrl(): string {
  const value = setting("POSTGRES_URL");
  if (!value) {
    throw new Error(
      "POSTGRES_URL is not set: fulfillment records order state, its publication intent and its job intent in one transaction, so storage is required",
    );
  }
  return value;
}

export function requiredRegistry(): string {
  const value = setting("SCHEMA_REGISTRY_URL");
  if (!value) {
    throw new Error("SCHEMA_REGISTRY_URL is not set: the outbox relay publishes through the registered contract");
  }
  return value;
}
