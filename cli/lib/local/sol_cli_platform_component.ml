let read_components path =
  if not (Sys.file_exists path)
  then Error (Printf.sprintf "%s is missing" path)
  else (
    match Yojson.Safe.from_file path with
    | json -> Ok json
    | exception Yojson.Json_error msg ->
      Error (Printf.sprintf "%s is not valid JSON: %s" path msg))
;;

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

(* The single declared source of the platform charts' versions, read by both the
   local platform and the production Terraform module. *)
let versions ~assets =
  let open Result.Syntax in
  let path = Sol_cli_platform_assets.components_json assets in
  let* components = read_components path in
  match components with
  | `Assoc fields ->
    (match List.assoc_opt "versions" fields with
     | Some (`Assoc entries) ->
       let* pairs =
         List.fold_left
           (fun acc (name, value) ->
              let* acc = acc in
              match value with
              | `String version -> Ok ((name, version) :: acc)
              | _ -> Error (Printf.sprintf "%s: versions.%s is not a string" path name))
           (Ok [])
           entries
       in
       Ok (List.rev pairs)
     | Some _ -> Error (path ^ ": versions is not an object")
     | None -> Error (path ^ ": versions is missing"))
  | _ -> Error (path ^ " is not a JSON object")
;;
