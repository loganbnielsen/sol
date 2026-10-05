let in_root root path = if root = "" then path else Filename.concat root path

let entries_or_empty dir =
  match Sol_cli_fs_walk.entries dir with
  | Ok names -> Ok names
  | Error (Sol_cli_fs_walk.Absent _) -> Ok []
  | Error error -> Error error
;;

let fs_error_to_parse_error = function
  | Sol_cli_fs_walk.Absent path ->
    Sol_cli_toml.Validation { path; message = "no such directory" }
  | Sol_cli_fs_walk.Unreadable (path, message) ->
    Sol_cli_toml.Validation { path; message }
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
  let events = in_root root "events" in
  let open Result.Syntax in
  let* names = entries_or_empty events |> Result.map_error Sol_cli_fs_walk.to_string in
  let* subjects =
    List.fold_left
      (fun acc entry ->
         let* acc = acc in
         let path = Filename.concat events entry in
         if entry.[0] = '.'
         then Ok acc
         else if Sys.is_directory path
         then (
           let generated = generated_binding_name ~entry in
           let* files =
             entries_or_empty path |> Result.map_error Sol_cli_fs_walk.to_string
           in
           Ok
             (List.fold_left
                (fun acc2 fname ->
                   if
                     Filename.check_suffix fname ".ml"
                     && not (String.equal fname generated)
                   then
                     (entry
                      ^ "."
                      ^ String.capitalize_ascii (Filename.chop_suffix fname ".ml"))
                     :: acc2
                   else acc2)
                acc
                files))
         else if Filename.check_suffix entry ".ml"
         then Ok (Filename.chop_suffix entry ".ml" :: acc)
         else Ok acc)
      (Ok [])
      names
  in
  let sorted = List.sort_uniq String.compare subjects in
  Ok
    (filter_validated
       ~kind:"schema subject"
       Sol_cli_plan_ids.Schema_subject.of_string
       sorted)
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
  let events = in_root root "events" in
  let open Result.Syntax in
  let* top_level = Sol_cli_toml.load_result (in_root root "events/sol.toml") in
  let* names = entries_or_empty events |> Result.map_error fs_error_to_parse_error in
  let* sub_contracts =
    List.fold_left
      (fun acc entry ->
         let* acc = acc in
         let path = Filename.concat events entry in
         if entry.[0] = '.'
         then Ok acc
         else if Sys.is_directory path
         then
           let* manifest = Sol_cli_toml.load_result (Filename.concat path "sol.toml") in
           Ok (acc @ contracts_of_manifest ~dir:(Filename.concat "events" entry) manifest)
         else Ok acc)
      (Ok [])
      names
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
  let events = in_root root "events" in
  let open Result.Syntax in
  let* top_level = topics_of_toml (in_root root "events/sol.toml") in
  let* names = entries_or_empty events |> Result.map_error fs_error_to_parse_error in
  let* sub_topics =
    List.fold_left
      (fun acc entry ->
         let* acc = acc in
         let path = Filename.concat events entry in
         if entry.[0] = '.'
         then Ok acc
         else if Sys.is_directory path
         then
           let* topics = topics_of_toml (Filename.concat path "sol.toml") in
           Ok (topics @ acc)
         else Ok acc)
      (Ok [])
      names
  in
  let sorted = List.sort_uniq String.compare (top_level @ sub_topics) in
  Ok (filter_validated ~kind:"topic name" Sol_cli_plan_ids.Topic_name.of_string sorted)
;;

let discover_migrations ?root () =
  let open Result.Syntax in
  let root = Option.value root ~default:"" in
  let* names =
    entries_or_empty (in_root root "db/migrations")
    |> Result.map_error Sol_cli_fs_walk.to_string
  in
  let files =
    List.filter
      (fun f ->
         Filename.check_suffix f ".sql" && not (Filename.check_suffix f ".down.sql"))
      names
  in
  let sorted = List.sort String.compare files in
  Ok
    (filter_validated
       ~kind:"migration file"
       Sol_cli_plan_ids.Migration_file.of_string
       sorted)
;;
