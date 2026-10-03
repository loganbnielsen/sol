type compatibility = Confluent_registry.compatibility =
  | Compatible
  | Incompatible
  | No_schema_registered

module Schema : sig
  val check
    :  net:_ Eio.Net.t
    -> clock:_ Eio.Time.clock
    -> registry_url:string
    -> (module Kafka_service_intf.MESSAGE)
    -> (unit, string) result

  val check_all
    :  net:_ Eio.Net.t
    -> clock:_ Eio.Time.clock
    -> registry_url:string
    -> (module Kafka_service_intf.MESSAGE) list
    -> (unit, string) result
end

val register_contract
  :  _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> registry_url:string
  -> topic_name:string
  -> schema:string
  -> (int, string) result

val decode_message
  :  'a Kafka_service_intf.topic
  -> Kafka.Consumer.message
  -> ('a * Obs_trace.t option, string * bytes option) result
