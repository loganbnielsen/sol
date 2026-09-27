val synthetic_alert : owner:string -> runbook_url:string -> now:float -> Yojson.Safe.t
val endpoint : string -> string

type outcome =
  | Accepted
  | Rejected of
      { exit_code : int
      ; stderr : string
      }
  | Unreachable of string

val send : url:string -> body:string -> outcome
