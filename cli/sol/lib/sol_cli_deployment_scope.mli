(** Deployment scope as a first-class, named value (FEAT-061, FEAT-064).

    Scope answers *what* a release contains; the destination (FEAT-059) answers
    *where* it goes. The two axes are separate, and neither should learn about
    the other. *)

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
    ["payments"], ["payments/charge_svc"] — always canonical. *)
val to_string : t -> string

(** What a user asked for, before discovery is consulted. *)
type request =
  | Whole_workspace
  | Whole_domain of string
  | Unit_named of string * string

(** [parse_request value] parses the optional user argument: absent or blank is
    the whole workspace, ["domain"] is a domain, ["domain/unit"] is one unit.
    Anything else — including a path with three or more segments — is an [Error]
    naming the accepted forms, because a request that cannot be understood must
    not fall back to selecting everything. *)
val parse_request : ?what:string -> string option -> (request, string) result

(** A unit as discovery reports it. *)
type named =
  { domain : string
  ; name : string
  ; kind : kind
  }

(** Whether the request matched anything. Neutral on purpose: whether zero
    matches is *meaningful* is the calling command's policy, not the selector's. *)
type selection =
  | Selected of named list
  | Empty

(** [resolve ~what request units] resolves against the units discovery found,
    failing closed with what exists when the request names something that does
    not. Matching normalises `-` to `_`, so `payments/charge-svc` resolves the
    same unit as `payments/charge_svc`; the resolved scope always carries
    discovery's canonical name rather than the spelling that was typed. *)
val resolve : ?what:string -> request -> named list -> (t * selection, string) result
