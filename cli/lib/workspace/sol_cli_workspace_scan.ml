let in_root root path = if root = "" then path else Filename.concat root path

let fold_dir dir ~init ~f =
  match Sol_cli_fs_walk.entries dir with
  | Ok names ->
    List.fold_left (fun acc entry -> f acc entry (Filename.concat dir entry)) init names
  | Error (Sol_cli_fs_walk.Absent _) -> init
  | Error error ->
    Sol_cli_report.warn "sol: warning: %s" (Sol_cli_fs_walk.to_string error);
    init
;;

let fold_dir_result dir ~init ~f =
  match Sol_cli_fs_walk.entries dir with
  | Ok names ->
    Ok
      (List.fold_left
         (fun acc entry -> f acc entry (Filename.concat dir entry))
         init
         names)
  | Error (Sol_cli_fs_walk.Absent _) -> Ok init
  | Error error -> Error (Sol_cli_fs_walk.to_string error)
;;

let filter_validated ~kind of_string strings =
  strings
  |> List.filter_map (fun s ->
    match of_string s with
    | Ok v -> Some v
    | Error e ->
      Sol_cli_report.warn "sol: warning: skipping invalid %s %S: %s" kind s e;
      None)
;;

let generated_binding_name ~entry = entry ^ "_contract.ml"

let discover_schema_subjects ?root () =
  let root = Option.value root ~default:"" in
  let subjects =
    fold_dir (in_root root "events") ~init:[] ~f:(fun acc entry path ->
      if entry.[0] = '.'
      then acc
      else if Sys.is_directory path
      then (
        let generated = generated_binding_name ~entry in
        fold_dir path ~init:acc ~f:(fun acc2 fname _p ->
          if Filename.check_suffix fname ".ml" && not (String.equal fname generated)
          then
            (entry ^ "." ^ String.capitalize_ascii (Filename.chop_suffix fname ".ml"))
            :: acc2
          else acc2))
      else if Filename.check_suffix entry ".ml"
      then Filename.chop_suffix entry ".ml" :: acc
      else acc)
  in
  let sorted = List.sort_uniq String.compare subjects in
  filter_validated ~kind:"schema subject" Sol_cli_plan_ids.Schema_subject.of_string sorted
;;

let derive_consumer_groups workspace workers =
  let strings =
    List.map
      (fun (domain, source_name) ->
         Printf.sprintf "%s.%s.%s" workspace domain source_name)
      workers
    |> List.sort_uniq String.compare
  in
  filter_validated
    ~kind:"consumer group"
    Sol_cli_plan_ids.Consumer_group.of_string
    strings
;;

let topics_of_toml path =
  Sol_cli_toml.load_result path
  |> Result.map (fun t ->
    t.Sol_cli_toml.topics
    @ List.map
        (fun (event : Sol_cli_toml.event_decl) -> event.topic)
        t.Sol_cli_toml.events)
;;

type contract =
  { dir : string
  ; language : Sol_cli_toml.binding_language
  ; events : Sol_cli_toml.event_decl list
  }

let contracts_of_manifest ~dir (manifest : Sol_cli_toml.t) =
  match manifest.Sol_cli_toml.contract_language, manifest.Sol_cli_toml.events with
  | Some language, _ :: _ -> [ { dir; language; events = manifest.Sol_cli_toml.events } ]
  | _ -> []
;;

let discover_contracts ?root () =
  let root = Option.value root ~default:"" in
  let open Result.Syntax in
  let* top_level = Sol_cli_toml.load_result (in_root root "events/sol.toml") in
  let* sub_contracts =
    fold_dir (in_root root "events") ~init:(Ok []) ~f:(fun acc entry path ->
      let* acc = acc in
      if entry.[0] = '.'
      then Ok acc
      else if Sys.is_directory path
      then
        let* manifest = Sol_cli_toml.load_result (Filename.concat path "sol.toml") in
        Ok (acc @ contracts_of_manifest ~dir:(Filename.concat "events" entry) manifest)
      else Ok acc)
  in
  Ok (contracts_of_manifest ~dir:"events" top_level @ sub_contracts)
;;

let discover_events ?root () =
  match discover_contracts ?root () with
  | Error error -> Error error
  | Ok contracts ->
    Ok
      (List.concat_map
         (fun (contract : contract) ->
            List.map (fun decl -> contract.dir, decl) contract.events)
         contracts)
;;

let discover_topics ?root () =
  let root = Option.value root ~default:"" in
  let open Result.Syntax in
  let* top_level = topics_of_toml (in_root root "events/sol.toml") in
  let* sub_topics =
    fold_dir (in_root root "events") ~init:(Ok []) ~f:(fun acc entry path ->
      let* acc = acc in
      if entry.[0] = '.'
      then Ok acc
      else if Sys.is_directory path
      then
        let* topics = topics_of_toml (Filename.concat path "sol.toml") in
        Ok (topics @ acc)
      else Ok acc)
  in
  let sorted = List.sort_uniq String.compare (top_level @ sub_topics) in
  Ok (filter_validated ~kind:"topic name" Sol_cli_plan_ids.Topic_name.of_string sorted)
;;

let discover_migrations ?root () =
  let open Result.Syntax in
  let root = Option.value root ~default:"" in
  let* files =
    fold_dir_result (in_root root "db/migrations") ~init:[] ~f:(fun acc f _path ->
      if Filename.check_suffix f ".sql" && not (Filename.check_suffix f ".down.sql")
      then f :: acc
      else acc)
  in
  let sorted = List.sort String.compare files in
  Ok
    (filter_validated
       ~kind:"migration file"
       Sol_cli_plan_ids.Migration_file.of_string
       sorted)
;;
