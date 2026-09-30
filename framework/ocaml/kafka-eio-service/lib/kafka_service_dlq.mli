type relay =
  { source : Kafka.Consumer.message
  ; headers : (string * string option) list
  }

val decode_failure_message
  :  raw_msg:Kafka.Consumer.message
  -> decode_error:string
  -> group_id:string
  -> relay

val route_decode_error
  :  dlq_topic:string
  -> raw_msg:Kafka.Consumer.message
  -> decode_error:string
  -> group_id:string
  -> publish:(target_topic:string -> relay -> (unit, Kafka.Error.t) result)
  -> ack:(unit -> (unit, Kafka.Error.t) result)
  -> (unit, Kafka.Error.t) result

val sanitize_group_id : string -> string
val canonical_group_segment : string -> string
val dlq_topic_name : source:string -> group_id:string -> string
