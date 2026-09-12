(** Deployment scope as a first-class, named value (FEAT-061).

    Scope answers *what* a release contains; the destination (FEAT-059) answers
    *where* it goes. The two axes are separate, and neither should learn about
    the other.

    A scope is a name rather than a path: discovery still walks directories and
    the existing path argument remains as an escape hatch, but the identity of a
    release is the unit it names. See the implementation for why DEC-018 needs
    that distinction. *)

(** The kind of unit a scope names. Resolution supplies it from discovery, so a
    request never carries one. *)
type kind =
  | Service
  | Worker
  | Function

val kind_to_string : kind -> string
val kind_of_primitive : Sol_cli_deployment_plan.primitive -> kind

(** A resolved scope. *)
type t =
  | Workspace
  | Domain of string
  | Unit of
      { domain : string
      ; name : string
      ; kind : kind
      }

(** [to_string scope] is the spelling a user types back: ["workspace"],
    ["payments"], ["payments/charge_svc"]. *)
val to_string : t -> string

(** What a user asked for, before discovery is consulted. *)
type request =
  | Whole_workspace
  | Whole_domain of string
  | Unit_named of string * string

(** [parse_request value] parses the optional user argument: absent or blank is
    the whole workspace, ["domain"] is a domain, ["domain/unit"] is one unit.
    Anything else — including a path with three or more segments — is an
    [Error] naming the accepted forms, because a request that cannot be
    understood must not fall back to deploying everything. *)
val parse_request : ?what:string -> string option -> (request, string) result

(** A unit as discovery reports it. Kept separate from
    [Sol_cli_deployment_plan.service_spec] so resolution can be tested without
    constructing a 24-field record. *)
type named =
  { domain : string
  ; name : string
  ; kind : kind
  }

val named_of_spec : Sol_cli_deployment_plan.service_spec -> named

(** [select_named ~what request units] resolves a request against the units
    discovery found. It fails closed when the request names something that does
    not exist, listing what does — the failure mode this exists to remove is an
    unmatched selection quietly deploying nothing. *)
val select_named
  :  ?what:string
  -> request
  -> named list
  -> (t * named list, string) result

(** The same, over discovered services. *)
val select
  :  ?what:string
  -> request
  -> Sol_cli_deployment_plan.service_spec list
  -> (t * Sol_cli_deployment_plan.service_spec list, string) result
