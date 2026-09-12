(* FEAT-061 / FEAT-064: deployment scope as a first-class, *named* value.

   Scope answers WHAT a release contains. It deliberately says nothing about
   WHERE that release goes — that is the destination (FEAT-059) — and the two
   axes must not learn about each other. A resolver that knows which cluster it
   targets, or a kubectl helper that knows which service it deploys, has already
   conflated them.

   A scope is a name, not a path: the identity of a release is the unit it names,
   which is what DEC-018 needs to restore one. The *kind* of a unit is not
   something the user states — whether `payments/charge_svc` is a service, a
   worker or a function is a property of what discovery found, so a request
   carries a name and resolution supplies the kind. *)

type kind =
  | Service
  | Worker
  | Function

let kind_to_string = function
  | Service -> "service"
  | Worker -> "worker"
  | Function -> "function"
;;

let kind_of_primitive : Sol_cli_deployment_plan.primitive -> kind = function
  | Svc -> Service
  | Worker -> Worker
  | Fn -> Function
;;

type t =
  | Workspace
  | Domain of string
  | Unit of
      { domain : string
      ; name : string
      ; kind : kind
      }

let to_string = function
  | Workspace -> "workspace"
  | Domain domain -> domain
  | Unit { domain; name; _ } -> Printf.sprintf "%s/%s" domain name
;;

(* What the user asked for, before discovery is consulted. *)
type request =
  | Whole_workspace
  | Whole_domain of string
  | Unit_named of string * string

(* Absent means the whole workspace, which is what it means today — in both
   `sol check` and `sol open` — so the vocabulary preserves it rather than
   inventing a new default. A three-segment value is rejected: it is a *path*,
   and a path is not a name. *)
let parse_request ?(what = "scope") value =
  let trimmed = String.trim (Option.value value ~default:"") in
  if trimmed = ""
  then Ok Whole_workspace
  else (
    match String.split_on_char '/' trimmed with
    | [ domain ] when domain <> "" -> Ok (Whole_domain domain)
    | [ domain; name ] when domain <> "" && name <> "" -> Ok (Unit_named (domain, name))
    | _ ->
      Error
        (Printf.sprintf
           "%s must be a domain (`payments`), a unit (`payments/charge_svc`), or absent \
            for the whole workspace — got %S"
           what
           trimmed))
;;

(* [request_to_string] is the spelling a command records as *requested* scope
   (DEC-018/FEAT-065): intent, before discovery narrowed it. It deliberately
   does not normalise `-` to `_` — what the user asked for is what the requested
   scope says; the resolved set carries discovery's canonical names. *)
let request_to_string = function
  | Whole_workspace -> "workspace"
  | Whole_domain domain -> domain
  | Unit_named (domain, name) -> Printf.sprintf "%s/%s" domain name
;;

(* A unit as discovery reports it. Kept separate from [service_spec] and from
   [Sol_cli_manifest.service] so resolution is testable without constructing
   either record, and so neither record becomes the centre of the design. *)
type named =
  { domain : string
  ; name : string
  ; kind : kind
  }

(* Whether the request matched anything. Deliberately neutral: the resolver
   answers "what matched", and whether zero matches is *meaningful* is the calling
   command's policy — `check` and `status` accept an empty workspace, while `up`,
   `deploy` and `rollback` must not (FEAT-064). Encoding that policy here would
   make the selector know what its caller intends to do with the answer. *)
type selection =
  | Selected of named list
  | Empty

let domains_of units =
  units |> List.map (fun unit -> unit.domain) |> List.sort_uniq String.compare
;;

let unit_names_of units =
  units
  |> List.map (fun unit -> Printf.sprintf "%s/%s" unit.domain unit.name)
  |> List.sort_uniq String.compare
;;

let or_none = function
  | [] -> "(none)"
  | values -> String.concat ", " values
;;

(* The repository name is canonical: discovery derives it from the directory, and
   `charge-svc` is merely what a user sees in the cluster. Normalising on the way
   in lets the hyphenated spelling resolve to the same unit without either
   spelling becoming a second identity — the resolved scope always carries the
   discovered name. *)
let normalize_name =
  String.map (function
    | '-' -> '_'
    | c -> c)
;;

let equal_name a b = String.equal (normalize_name a) (normalize_name b)

(* [resolve ~what request units] resolves a request against what discovery found,
   and fails closed naming what exists when it names something that does not.
   That failure mode is half the point of this module: an unmatched selection must
   not be able to proceed as though it had matched nothing on purpose. *)
let resolve ?(what = "scope") request units =
  match request with
  | Whole_workspace -> Ok (Workspace, if units = [] then Empty else Selected units)
  | Whole_domain domain ->
    let selected = List.filter (fun unit -> equal_name unit.domain domain) units in
    if selected = []
    then
      Error
        (Printf.sprintf
           "%s %S matches no workload; domains with units: %s"
           what
           domain
           (or_none (domains_of units)))
    else Ok (Domain domain, Selected selected)
  | Unit_named (domain, name) ->
    (match
       List.find_opt
         (fun unit -> equal_name unit.domain domain && equal_name unit.name name)
         units
     with
     | Some unit ->
       (* Canonical, from discovery — not the spelling that was typed. *)
       Ok
         ( Unit { domain = unit.domain; name = unit.name; kind = unit.kind }
         , Selected [ unit ] )
     | None ->
       let in_domain = List.filter (fun unit -> equal_name unit.domain domain) units in
       Error
         (Printf.sprintf
            "%s %S matches no unit; units under %S: %s; domains with units: %s"
            what
            (Printf.sprintf "%s/%s" domain name)
            domain
            (or_none (unit_names_of in_domain))
            (or_none (domains_of units))))
;;
