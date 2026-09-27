(* REFAC-102: every component's values live in one file, keyed
   <component>.{common,local,durable}. *)
let read_components path =
  if not (Sys.file_exists path)
  then Error (Printf.sprintf "%s is missing" path)
  else (
    match Yojson.Safe.from_file path with
    | json -> Ok json
    | exception Yojson.Json_error msg ->
      Error (Printf.sprintf "%s is not valid JSON: %s" path msg))
;;

(* A component with nothing to say for a layer (tempo's empty profiles, or a
   component the file does not name) contributes an empty object, not an error.
   REFAC-132: something that is there but is not an object is an error -- a
   malformed components.json must not install every component with no values. *)
let layer ~path components ~component ~name =
  let what = Printf.sprintf "%s: %s.%s" path component name in
  match components with
  | `Assoc fields ->
    (match List.assoc_opt component fields with
     | None -> Ok (`Assoc [])
     | Some (`Assoc layers) ->
       (match List.assoc_opt name layers with
        | None -> Ok (`Assoc [])
        | Some (`Assoc _ as values) -> Ok values
        | Some _ -> Error (what ^ " is not an object"))
     | Some _ -> Error (Printf.sprintf "%s: %s is not an object" path component))
  | _ -> Error (path ^ " is not a JSON object")
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
      base_fields
      |> List.map (fun (k, v) ->
        match List.assoc_opt k over_fields with
        | Some v2 -> k, deep_merge v v2
        | None -> k, v)
    in
    let added =
      List.filter (fun (k, _) -> not (List.mem_assoc k base_fields)) over_fields
    in
    `Assoc (merged @ added)
  | _, over -> over
;;

let merged_values_yaml ~assets ~component ~profile =
  let open Result.Syntax in
  let path = Sol_cli_platform_assets.components_json assets in
  let* components = read_components path in
  let* common = layer ~path components ~component ~name:"common" in
  let* profile_json = layer ~path components ~component ~name:profile in
  Ok (Yojson.Safe.pretty_to_string (deep_merge common profile_json))
;;
