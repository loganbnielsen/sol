type grant =
  { unit : string
  ; capability : string
  ; resource : string
  }

val compare_grant : grant -> grant -> int
val normalize : grant list -> grant list
val grant_to_string : grant -> string

type deployed_state =
  | Deployed of grant list
  | Unobservable of string

type plan =
  { keep : grant list
  ; additions : grant list
  ; removals : grant list
  ; held : grant list
  ; held_reason : string
  ; notes : string list
  }

val compute : desired:grant list -> current:grant list -> deployed:deployed_state -> plan
val render : plan -> string list
