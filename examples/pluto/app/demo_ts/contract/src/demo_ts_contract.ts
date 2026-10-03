import type { TopicContract } from "@sol-fab/kafka";

export interface EventContractSpec {
  readonly name: string;
  readonly schema: string;
  readonly partitions: number;
  readonly keyField: string | null;
}

export function generatedContract<T>(spec: EventContractSpec): TopicContract<T> {
  return {
    name: spec.name,
    schema: spec.schema,
    partitions: spec.partitions,
    key: (message) => {
      if (spec.keyField === null) return undefined;
      const value = (message as unknown as Record<string, unknown>)[spec.keyField];
      return value === undefined || value === null ? undefined : String(value);
    },
  };
}

export const OrderPlacedSpec: EventContractSpec = {
  name: "sol-demo-ts-orders",
  schema: "{\n  \"type\": \"object\",\n  \"properties\": {\n    \"order_id\":       { \"type\": \"string\"  },\n    \"item\":           { \"type\": \"string\"  },\n    \"quantity\":       { \"type\": \"integer\" },\n    \"correlation_id\": { \"type\": \"string\"  }\n  },\n  \"required\": [\"order_id\", \"item\", \"quantity\", \"correlation_id\"]\n}",
  partitions: 3,
  keyField: "order_id",
};

export const OrderFulfilledSpec: EventContractSpec = {
  name: "sol-demo-ts-fulfilled",
  schema: "{\n  \"type\": \"object\",\n  \"properties\": {\n    \"order_id\":       { \"type\": \"string\"  },\n    \"item\":           { \"type\": \"string\"  },\n    \"quantity\":       { \"type\": \"integer\" },\n    \"correlation_id\": { \"type\": \"string\"  }\n  },\n  \"required\": [\"order_id\", \"item\", \"quantity\", \"correlation_id\"]\n}",
  partitions: 3,
  keyField: "order_id",
};
