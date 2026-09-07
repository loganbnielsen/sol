(* Fold over entries in [dir], silently returning [init] if the dir is absent. *)
let fold_dir dir ~init ~f =
  if not (Sys.file_exists dir && Sys.is_directory dir) then init
  else begin
    let acc = ref init in
    (try Array.iter (fun entry ->
       let path = Filename.concat dir entry in
       acc := f !acc entry path
     ) (Sys.readdir dir)
    with _ -> ());
    !acc
  end

(** Convert a string through a newtype constructor, printing a warning and
    returning [None] when validation fails. *)
let filter_validated ~kind of_string strings =
  List.filter_map (fun s ->
    match of_string s with
    | Ok v    -> Some v
    | Error e ->
      Printf.eprintf "sol: warning: skipping invalid %s %S: %s\n%!" kind s e;
      None
  ) strings

(** Scan [events/<domain>/] subdirectories for [*.ml] files and derive schema
    subject names as ["<domain>.<EventName>"].  Also handles top-level
    [events/<event>.ml] files (no domain prefix).  Returns a sorted,
    deduplicated list. *)
let discover_schema_subjects () =
  let subjects = fold_dir "events" ~init:[] ~f:(fun acc entry path ->
    if entry.[0] = '.' then acc
    else if Sys.is_directory path then
      fold_dir path ~init:acc ~f:(fun acc2 fname _p ->
        if Filename.check_suffix fname ".ml" then
          (entry ^ "." ^ String.capitalize_ascii (Filename.chop_suffix fname ".ml")) :: acc2
        else acc2)
    else if Filename.check_suffix entry ".ml" then
      Filename.chop_suffix entry ".ml" :: acc
    else acc
  ) in
  let sorted = List.sort_uniq String.compare subjects in
  filter_validated ~kind:"schema subject"
    Sol_cli_plan_ids.Schema_subject.of_string sorted

(** Derive consumer group identifiers for worker identities.
    Convention: ["<workspace>.<domain>.<worker_name>"]. *)
let derive_consumer_groups workspace workers =
  let strings =
    List.map (fun (domain, source_name) ->
      Printf.sprintf "%s.%s.%s" workspace domain source_name
    ) workers
    |> List.sort_uniq String.compare
  in
  filter_validated ~kind:"consumer group"
    Sol_cli_plan_ids.Consumer_group.of_string strings

(** Load topics from a [sol.toml] file at [path], returning [] if absent or
    unparseable.  Silently ignores errors so a missing/malformed sol.toml in an
    event directory does not abort workspace scanning. *)
let topics_of_toml path =
  match Sol_cli_toml.load_result path with
  | Ok t -> t.Sol_cli_toml.topics
  | Error _ -> []

(** Discover topics from [sol.toml]'s [[service] topics = [...]] array in
    [events/] subdirectories and [events/sol.toml]; sorted, deduplicated.
    Never scans [*.ml] source, to avoid false positives from string literals. *)
let discover_topics () =
  let top_level = topics_of_toml "events/sol.toml" in
  let sub_topics = fold_dir "events" ~init:[] ~f:(fun acc entry path ->
    if entry.[0] = '.' then acc
    else if Sys.is_directory path then
      let toml_path = Filename.concat path "sol.toml" in
      topics_of_toml toml_path @ acc
    else acc
  ) in
  let sorted = List.sort_uniq String.compare (top_level @ sub_topics) in
  filter_validated ~kind:"topic name"
    Sol_cli_plan_ids.Topic_name.of_string sorted

(** Scan [db/migrations/] for SQL files, sorted by filename. *)
let discover_migrations () =
  let files = fold_dir "db/migrations" ~init:[] ~f:(fun acc f _path ->
    if Filename.check_suffix f ".sql" then f :: acc else acc
  ) in
  let sorted = List.sort String.compare files in
  filter_validated ~kind:"migration file"
    Sol_cli_plan_ids.Migration_file.of_string sorted
