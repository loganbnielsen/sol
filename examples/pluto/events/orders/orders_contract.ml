[@@@ocamlformat "disable"]

module OrderPlaced = struct
  let topic_name = Kafka_service.topic_name_exn "orders.v1"
  let schema = "{\n  \"type\": \"object\",\n  \"properties\": {\n    \"order_id\":       { \"type\": \"string\"  },\n    \"item\":           { \"type\": \"string\"  },\n    \"quantity\":       { \"type\": \"integer\" },\n    \"correlation_id\": { \"type\": \"string\"  }\n  },\n  \"required\": [\"order_id\", \"item\", \"quantity\", \"correlation_id\"]\n}"
  let partitions = 3
  let key_field = Some "order_id"
end

module OrderFulfilled = struct
  let topic_name = Kafka_service.topic_name_exn "orders-fulfilled.v1"
  let schema = "{\n  \"type\": \"object\",\n  \"properties\": {\n    \"order_id\":       { \"type\": \"string\"  },\n    \"item\":           { \"type\": \"string\"  },\n    \"quantity\":       { \"type\": \"integer\" },\n    \"correlation_id\": { \"type\": \"string\"  }\n  },\n  \"required\": [\"order_id\", \"item\", \"quantity\", \"correlation_id\"]\n}"
  let partitions = 3
  let key_field = Some "order_id"
end
