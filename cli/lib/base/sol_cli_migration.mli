type prerequisite =
  { version : int
  ; name : string
  }

val default_dir : string
val postgres_identifier_max_bytes : int
val table_name : workspace:string -> string
val table_length_error : table:string -> string option
val parse_version : string -> (int * string) option
val required : dir:string -> (prerequisite list, string) result
val required_if_present : dir:string -> (prerequisite list, string) result
val parse_status_json : string -> (int list, string) result
val unsatisfied : required:prerequisite list -> applied:int list -> prerequisite list
val to_string : prerequisite -> string
val status_json : table:string -> (int * string * string option) list -> string

val evidence_report
  :  waiting:(string * string option) option
  -> logs:string option
  -> string option
