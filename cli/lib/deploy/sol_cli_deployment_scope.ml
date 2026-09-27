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

type request =
  | Whole_workspace
  | Whole_domain of string
  | Unit_named of string * string

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

let request_to_string = function
  | Whole_workspace -> "workspace"
  | Whole_domain domain -> domain
  | Unit_named (domain, name) -> Printf.sprintf "%s/%s" domain name
;;

type named =
  { domain : string
  ; name : string
  ; kind : kind
  }

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

let normalize_name =
  String.map (function
    | '-' -> '_'
    | c -> c)
;;

let equal_name a b = String.equal (normalize_name a) (normalize_name b)

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
       units
       |> List.find_opt (fun unit ->
         equal_name unit.domain domain && equal_name unit.name name)
     with
     | Some unit ->
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
