type compatibility_response = { is_compatible : bool }
type registration_response = { id : int }

val decode_compatibility_response : string -> (compatibility_response, string) result
val decode_registration_response : string -> (registration_response, string) result
val subject_name : string -> string
val is_subject_not_found : string -> bool

type compatibility =
  | Compatible
  | Incompatible
  | No_schema_registered

val check_compatibility
  :  ?ca_file:string
  -> _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> registry_url:string
  -> topic_name:string
  -> schema:string
  -> (compatibility, string) result

val set_subject_compatibility
  :  ?ca_file:string
  -> _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> registry_url:string
  -> topic_name:string
  -> (unit, string) result

val register_schema
  :  ?ca_file:string
  -> _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> registry_url:string
  -> topic_name:string
  -> schema:string
  -> (int, string) result

val lookup_schema
  :  ?ca_file:string
  -> _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> registry_url:string
  -> topic_name:string
  -> schema:string
  -> (int, string) result

module Wire : sig
  val encode : schema_id:int -> Yojson.Safe.t -> bytes
  val decode : bytes -> (int * string, string) result
end
