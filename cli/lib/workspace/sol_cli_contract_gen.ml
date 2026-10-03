let generated_module ~dir = String.capitalize_ascii (Filename.basename dir) ^ "_contract"

let generated_path ~dir =
  Filename.concat dir (String.uncapitalize_ascii (generated_module ~dir) ^ ".ml")
;;

let render_event (event : Sol_cli_toml.event_decl) =
  let key_field =
    match event.key_field with
    | None -> "None"
    | Some field -> Printf.sprintf "Some %S" field
  in
  Printf.sprintf
    "module %s = struct\n\
    \  let topic_name = Kafka_service.topic_name_exn %S\n\
    \  let schema = %S\n\
    \  let partitions = %d\n\
    \  let key_field = %s\n\
     end\n"
    event.name
    event.topic
    event.schema
    event.partitions
    key_field
;;

let render events =
  let body = String.concat "\n" (List.map render_event events) in
  Printf.sprintf "[@@@ocamlformat \"disable\"]\n\n%s" body
;;

let group_events events =
  let dirs = List.sort_uniq String.compare (List.map fst events) in
  List.map
    (fun dir ->
       ( dir
       , List.filter_map
           (fun (event_dir, event) ->
              if String.equal event_dir dir then Some event else None)
           events ))
    dirs
;;

let plan ~root =
  match Sol_cli_workspace_scan.discover_events ~root () with
  | Error error -> Error (Sol_cli_toml.parse_error_to_string error)
  | Ok events ->
    Ok
      (List.map
         (fun (dir, events) -> dir, generated_path ~dir, render events)
         (group_events events))
;;

let generate ~root ~check =
  match plan ~root with
  | Error error -> Error error
  | Ok files ->
    if check
    then (
      let problems =
        List.filter_map
          (fun (_, path, content) ->
             let full = Filename.concat root path in
             match Sol_cli_fs.read_file_opt full with
             | Some existing when String.equal existing content -> None
             | Some _ ->
               Some (Printf.sprintf "%s is stale; run `sol contract generate`" path)
             | None ->
               Some (Printf.sprintf "%s is missing; run `sol contract generate`" path))
          files
      in
      if problems = [] then Ok [] else Error (String.concat "\n" problems))
    else
      List.fold_left
        (fun acc (_, path, content) ->
           Result.bind acc (fun written ->
             let full = Filename.concat root path in
             Result.bind
               (Sol_cli_fs.mkdir_p (Filename.dirname full))
               (fun () ->
                  Result.bind (Sol_cli_fs.write_atomic full content) (fun () ->
                    Ok (path :: written)))))
        (Ok [])
        files
      |> Result.map List.rev
;;
