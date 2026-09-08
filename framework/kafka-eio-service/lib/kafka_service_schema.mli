(** Schema registry HTTP client and Confluent wire-format codec backing
    [Kafka_service]. [Kafka_service] re-exports [Schema], [Confluent_wire],
    and [encode_wire] directly — see its [.mli] for the documented API.
    [decode_compatibility_response]/[decode_registration_response] are
    exposed only for direct unit testing of the registry response codec. *)

type compatibility_response = { is_compatible : bool }
type registration_response = { id : int }

val decode_compatibility_response : string -> (compatibility_response, string) result
val decode_registration_response : string -> (registration_response, string) result

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

val set_subject_compatibility
  :  _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> registry_url:string
  -> topic_name:string
  -> (unit, string) result

val register_schema
  :  _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> registry_url:string
  -> topic_name:string
  -> schema:string
  -> (int, string) result

module Confluent_wire : sig
  val encode : schema_id:int -> Yojson.Safe.t -> bytes
  val decode : bytes -> (int * string, string) result
end

val encode_wire : schema_id:int -> Yojson.Safe.t -> bytes

val decode_message
  :  'a Kafka_service_intf.topic
  -> Kafka.Consumer.message
  -> ('a * Obs_trace.t option, string * bytes option) result
(** Decode a raw consumed message: Confluent wire format, then [topic]'s own
    JSON decoder. On success also extracts the [traceparent] header (if
    present) into an [Obs_trace.t]. On failure, returns the raw undecoded
    bytes alongside the error so callers can route it to a decode-error
    handler without re-fetching the message. *)
