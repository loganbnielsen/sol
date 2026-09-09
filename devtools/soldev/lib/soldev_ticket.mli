(* Only three persisted states remain (see REFAC-077): [Backlog] is a
   pre-work human-judgment gate, [Ready_for_engineering] covers everything
   from "not started" through "PR open, in review" (GitHub's own open-PR/
   review/CI state IS that information — no local directory duplicates it),
   and [Done] is committed on the ticket's own PR branch as part of the
   worker's implementation commit, so it rides into `main` inside the same
   squashed merge commit as the code. There is no persisted "in review" or
   "ready to merge" directory, and no "blocked by performance" directory: a
   post-merge revert undoes the code and the ticket's DONE move atomically,
   since they were always the same commit — it lands back in
   [Ready_for_engineering] for free. *)
type ticket_state = Backlog | Ready_for_engineering | Done

val state_to_dir : ticket_state -> string
val state_of_dir : string -> ticket_state option
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
