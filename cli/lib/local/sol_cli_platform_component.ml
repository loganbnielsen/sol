(* REFAC-102: every component's values live in one file, keyed
   <component>.{common,local,durable}. *)
let read_components path =
  if not (Sys.file_exists path)
  then (
    Printf.eprintf "error: %s is missing.\n" path;
    exit 1)
  else (
    try Yojson.Safe.from_file path with
    | Yojson.Json_error msg ->
      Printf.eprintf "error: %s is not valid JSON: %s\n" path msg;
      exit 1)
;;

(* A component with nothing to say for a layer (tempo's empty profiles, or a
   component the file does not name) contributes an empty object, not an error. *)
let layer components ~component ~name =
  match components with
  | `Assoc fields ->
    (match List.assoc_opt component fields with
     | Some (`Assoc layers) ->
       Option.value (List.assoc_opt name layers) ~default:(`Assoc [])
     | _ -> `Assoc [])
  | _ -> `Assoc []
;;

(* Deep merge: [override]'s object keys win over [base]'s on conflict, with
   nested objects merged recursively rather than replaced wholesale. Any
   other conflict (arrays, scalars, mismatched shapes) takes [override]
   outright -- matching Helm's own multi-values-file merge semantics, which
   this mirrors so a single JSON string can stand in for "common file then
   profile file" precedence. *)
let rec deep_merge (base : Yojson.Safe.t) (over : Yojson.Safe.t) : Yojson.Safe.t =
  match base, over with
  | `Assoc base_fields, `Assoc over_fields ->
    let merged =
      List.map
        (fun (k, v) ->
           match List.assoc_opt k over_fields with
           | Some v2 -> k, deep_merge v v2
           | None -> k, v)
        base_fields
    in
    let added =
      List.filter (fun (k, _) -> not (List.mem_assoc k base_fields)) over_fields
    in
    `Assoc (merged @ added)
  | _, over -> over
;;

let merged_values_yaml ~component ~profile =
  let components =
    read_components
      (Sol_cli_platform_assets.components_json
         (Sol_cli_platform_assets.resolve_or_exit ()))
  in
  let common = layer components ~component ~name:"common" in
  let profile_json = layer components ~component ~name:profile in
  Yojson.Safe.pretty_to_string (deep_merge common profile_json)
;;
