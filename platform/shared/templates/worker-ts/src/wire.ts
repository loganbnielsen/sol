export interface Message {
  id: string;
}

export function decodePayload(json: unknown): Message {
  if (typeof json !== "object" || json === null) throw new Error("expected object");
  const j = json as Record<string, unknown>;
  const id = j.id;
  if (typeof id !== "string") throw new Error("id is required and must be a string");
  return { id };
}
