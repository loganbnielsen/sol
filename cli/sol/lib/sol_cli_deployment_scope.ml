(* FEAT-061: deployment scope as a first-class, *named* value.

   Scope answers WHAT a release contains. It deliberately says nothing about
   WHERE that release goes — that is the destination (FEAT-059) — and the two
   axes must not learn about each other. A resolver that knows which cluster it
   targets, or a kubectl helper that knows which service it deploys, has already
   conflated them.

   A scope is a name, not a path. Discovery still walks directories, and the
   positional path argument stays as an explicit escape hatch for "these
   directories", but the identity of a release is the unit it names. That is
   what DEC-018 needs: rolling back a service and rolling back a workspace are
   different operations with different blast radius, and a path prefix cannot
   tell them apart.

   The *kind* of a unit is not something the user states. Whether
   `payments/charge_svc` is a service, a worker or a function is a property of
   what discovery found, so a request carries a name and resolution supplies the
   kind — asking the user would be asking them to remember the filesystem. *)

type kind =
  | Service
  | Worker
  | Function
;;

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
;;

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
;;

(* Absent means the whole workspace, which is what it means today — in both
   `sol check` and `sol open` — so the vocabulary preserves it rather than
   inventing a new default. *)
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

(* A unit as discovery reports it: the shape resolution actually needs, kept
   separate from [service_spec] so the resolution logic can be tested without
   constructing a 24-field record. *)
type named =
  { domain : string
  ; name : string
  ; kind : kind
  }
;;

let named_of_spec (spec : Sol_cli_deployment_plan.service_spec) =
  { domain = spec.domain
  ; name = spec.source_name
  ; kind = kind_of_primitive spec.primitive
  }
;;

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

(* [select_named ~what request units] resolves a request against what discovery
   found, and fails closed naming the available units when it names something
   that does not exist. That failure mode is half the point of this module:
   today an unmatched filter selects nothing and the command proceeds to deploy
   nothing, quietly. *)
let select_named ?(what = "scope") request units =
  match request with
  | Whole_workspace -> Ok (Workspace, units)
  | Whole_domain domain ->
    let selected = List.filter (fun unit -> String.equal unit.domain domain) units in
    if selected = []
    then
      Error
        (Printf.sprintf
           "%s %S matches no units; domains with units: %s"
           what
           domain
           (or_none (domains_of units)))
    else Ok (Domain domain, selected)
  | Unit_named (domain, name) ->
    (match
       List.find_opt
         (fun unit -> String.equal unit.domain domain && String.equal unit.name name)
         units
     with
     | Some unit -> Ok (Unit { domain; name; kind = unit.kind }, [ unit ])
     | None ->
       let in_domain = List.filter (fun unit -> String.equal unit.domain domain) units in
       Error
         (Printf.sprintf
            "%s %S matches no unit; units under %S: %s; domains with units: %s"
            what
            (Printf.sprintf "%s/%s" domain name)
            domain
            (or_none (unit_names_of in_domain))
            (or_none (domains_of units))))
;;

let select ?what request specs =
  let units = List.map named_of_spec specs in
  match select_named ?what request units with
  | Error _ as error -> error
  | Ok (scope, selected) ->
    let matches unit (spec : Sol_cli_deployment_plan.service_spec) =
      String.equal unit.domain spec.domain && String.equal unit.name spec.source_name
    in
    Ok (scope, List.filter (fun spec -> List.exists (fun unit -> matches unit spec) selected) specs)
;;
