let component_dir sol_home component =
  Filename.concat sol_home (Filename.concat "cli/platform/components" component)
;;

let read_json path =
  if not (Sys.file_exists path)
  then `Assoc []
  else (
    try Yojson.Safe.from_file path with
    | Yojson.Json_error msg ->
      Printf.eprintf "error: %s is not valid JSON: %s\n" path msg;
      exit 1)
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
  let sol_home =
    match Sol_cli_cmd_new.infer_sol_home () with
    | Some dir -> dir
    | None ->
      Printf.eprintf
        "error: cannot locate the Sol monorepo root to read cli/platform/components/%s.\n"
        component;
      Printf.eprintf "  Set SOL_HOME to your Sol checkout and re-run:\n";
      Printf.eprintf "    export SOL_HOME=/path/to/sol\n";
      exit 1
  in
  let dir = component_dir sol_home component in
  let common = read_json (Filename.concat dir "values-common.json") in
  let profile_json =
    read_json (Filename.concat dir (Printf.sprintf "values-%s.json" profile))
  in
  Yojson.Safe.pretty_to_string (deep_merge common profile_json)
;;
