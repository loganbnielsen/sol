type ticket_state =
  | Backlog
  | Ready_for_engineering
  | Done

val state_to_dir : ticket_state -> string
val state_of_dir : string -> ticket_state option
val all_states : ticket_state list
val frontmatter : string -> ((string * string) list, string) result
val fields : string -> (string * string) list
val unreadable : path:string -> string -> string option
val fm_get : (string * string) list -> string -> string option
val parse_depends : string -> string list
val has_human_decision_gate : string -> bool
val human_decision_details : string -> string
val ticket_title : string -> string
val find_ticket : string -> (ticket_state * string) option
val dependency_status : string -> [ `Done | `Unknown | `Blocked of ticket_state ]
val dependency_summary : string list -> string

type premise_verdict =
  | Premise_holds
  | Premise_stale
  | Premise_unverified of string

val premise_of : string -> string option
val premise_verdict : exit_code:int -> premise_verdict

val find_dependency_cycle_from
  :  deps_of:(string -> string list)
  -> string
  -> string list option

val find_dependency_cycle : string -> string list option
val cycle_blocks : string list -> bool
val readiness_label : ticket_id:string -> ticket_state -> string -> string
