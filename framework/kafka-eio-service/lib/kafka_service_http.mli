(** Minimal HTTP client for the Redpanda admin API and schema registry — a
    single request per call (10s timeout, connection closed after), not a
    pooled client. Internal helper for [Kafka_service_intf] and
    [Kafka_service_schema]; not part of the package's public API. *)

val http_get
  :  _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> base_url:string
  -> path:string
  -> (int * string, string) result

val http_post
  :  _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> base_url:string
  -> path:string
  -> content_type:string
  -> body:string
  -> (int * string, string) result

val http_put
  :  _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> base_url:string
  -> path:string
  -> content_type:string
  -> body:string
  -> (int * string, string) result
