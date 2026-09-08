type ticket_state =
  | Backlog
  | Ready_for_engineering
  | In_progress
  | Review
  | Ready_to_merge
  | Blocked_by_performance
  | Done

type review_status = Pass | Fail

val state_to_dir : ticket_state -> string
val state_of_dir : string -> ticket_state option
val review_status_to_string : review_status -> string
val review_status_of_string : string -> review_status option

val all_states : ticket_state list

val parse_frontmatter : string -> (string * string) list
val fm_get : (string * string) list -> string -> string option
val set_frontmatter_field : string -> string -> string -> string

val parse_depends : string -> string list
val has_human_decision_gate : string -> bool
val human_decision_details : string -> string
val ticket_title : string -> string

val find_ticket : string -> (ticket_state * string) option
val dependency_status : string -> [ `Done | `Unknown | `Blocked of ticket_state ]
val dependency_summary : string list -> string
val readiness_label : ticket_state -> string -> string
