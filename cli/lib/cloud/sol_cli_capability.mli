type deescalation_principal =
  | Principal_confirmed of string
  | Principal_refused_by_cluster of string
  | Principal_probe_failed of string
  | Principal_unexpected of string

type deescalation_verdict =
  | Deescalated
  | Still_elevated of string list
  | Undetermined of string

type capability_answer =
  | Permitted
  | Denied
  | Indeterminate of string

type capability =
  { verb : string
  ; resource : string
  }

val capability_label : capability -> string
val answer_is_permitted : capability_answer -> bool

val capability_answer_of_can_i_output
  :  exit_code:int
  -> stdout:string
  -> stderr:string
  -> capability_answer

val indeterminate_reason : capability * capability_answer -> (string * string) option

val deescalation_verdict
  :  principal:deescalation_principal
  -> (capability * capability_answer) list
  -> deescalation_verdict

val successor_authority : (capability * capability_answer) list -> (unit, string) result

val deescalation_transition
  :  before:(capability * capability_answer) list
  -> after_principal:deescalation_principal
  -> after:(capability * capability_answer) list
  -> deescalation_verdict

val deescalation_verdict_to_string : deescalation_verdict -> string
