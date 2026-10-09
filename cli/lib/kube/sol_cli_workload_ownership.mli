type identity =
  { resource : string
  ; namespace : string
  ; name : string
  }

type evidence = string option

type live =
  | Live_absent
  | Live_present of string
  | Live_unobservable of string

val identity_equal : identity -> identity -> bool
val recorded_uid : Sol_cli_release_id.owned_object list -> identity -> evidence
val owns : recorded:evidence -> live_uid:string -> bool

type declared =
  | Create
  | Owned_unchanged
  | Live_not_owned
  | Recorded_gone
  | Declared_unobservable of string

val classify_declared : recorded:evidence -> live -> declared

type surplus =
  | Surplus_removable
  | Surplus_retained

val classify_surplus : recorded:evidence -> live_uid:string -> surplus
val observe : ctx:Sol_cli_kube_destination.context -> identity -> live
