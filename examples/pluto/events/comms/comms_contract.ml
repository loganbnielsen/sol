[@@@ocamlformat "disable"]

module Notification_sent = struct
  let topic_name = Kafka_service.topic_name_exn "pluto-comms-notifications"
  let schema = "{\n  \"type\": \"object\",\n  \"properties\": {\n    \"charge_id\":    { \"type\": \"string\"  },\n    \"customer_id\":  { \"type\": \"string\"  },\n    \"amount_cents\": { \"type\": \"integer\" },\n    \"currency\":     { \"type\": \"string\"  }\n  },\n  \"required\": [\"charge_id\", \"customer_id\", \"amount_cents\", \"currency\"]\n}"
  let partitions = 3
  let key_field = Some "charge_id"
end
