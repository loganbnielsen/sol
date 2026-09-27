type kind =
  | Service
  | Worker
  | Function

val kind_to_string : kind -> string
val kind_of_primitive : Sol_cli_deployment_plan.primitive -> kind

type t =
  | Workspace
  | Domain of string
  | Unit of
      { domain : string
      ; name : string
      ; kind : kind
      }

val to_string : t -> string

type request =
  | Whole_workspace
  | Whole_domain of string
  | Unit_named of string * string

val parse_request : ?what:string -> string option -> (request, string) result
val request_to_string : request -> string
val equal_name : string -> string -> bool

type named =
  { domain : string
  ; name : string
  ; kind : kind
  }

type selection =
  | Selected of named list
  | Empty

val resolve : ?what:string -> request -> named list -> (t * selection, string) result
