[@@@ocamlformat "disable"]

module Charged = struct
  let topic_name = Kafka_service.topic_name_exn "{{name}}-payments-charges"
  let schema = "{\n  \"type\": \"object\",\n  \"properties\": {\n    \"id\":             { \"type\": \"string\"  },\n    \"amount_cents\":   { \"type\": \"integer\" },\n    \"customer_id\":    { \"type\": \"string\"  },\n    \"currency\":       { \"type\": \"string\"  },\n    \"correlation_id\": { \"type\": \"string\"  }\n  },\n  \"required\": [\"id\", \"amount_cents\", \"customer_id\", \"currency\", \"correlation_id\"]\n}"
  let partitions = 3
  let key_field = Some "id"
end
