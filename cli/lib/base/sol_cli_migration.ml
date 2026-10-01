type prerequisite =
  { version : int
  ; name : string
  }

let default_dir = "db/migrations"

let table_name ~workspace =
  let buf = Buffer.create (String.length workspace) in
  workspace
  |> String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
    then Buffer.add_char buf c
    else if c >= 'A' && c <= 'Z'
    then Buffer.add_char buf (Char.lowercase_ascii c)
    else Buffer.add_char buf '_');
  Printf.sprintf "sol_%s_schema_migrations" (Buffer.contents buf)
;;

let parse_version = Migration.parse_filename

type directory_contents =
  | Absent
  | Entries of string list
  | Uninspectable of string

let inspect_directory dir =
  match Unix.stat dir with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Absent
  | exception Unix.Unix_error (error, _, _) ->
    Uninspectable (Printf.sprintf "cannot inspect %s: %s" dir (Unix.error_message error))
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    (match Sys.readdir dir with
     | entries -> Entries (Array.to_list entries)
     | exception Sys_error message ->
       Uninspectable (Printf.sprintf "cannot read %s: %s" dir message))
  | _ -> Uninspectable (Printf.sprintf "%s exists but is not a directory" dir)
;;

let required ~dir =
  match inspect_directory dir with
  | Absent ->
    Error
      (Printf.sprintf
         "cannot read migrations dir: %s: %s"
         dir
         (Unix.error_message Unix.ENOENT))
  | Uninspectable message -> Error message
  | Entries _ ->
    Eio_main.run (fun env ->
      Migration.migrations ~fs:env#fs ~dir
      |> Result.map_error Pg_error.to_string
      |> Result.map (List.map (fun (version, name, _) -> { version; name })))
;;

let required_if_present ~dir =
  match inspect_directory dir with
  | Absent -> Ok []
  | Uninspectable _ | Entries _ -> required ~dir
;;

let to_string (p : prerequisite) = Printf.sprintf "%03d_%s" p.version p.name

let parse_status_json text =
  let open Result.Syntax in
  let what = "migration status" in
  let applied_version item =
    let* applied = Sol_cli_json.require ~what [ "applied" ] Sol_cli_json.bool item in
    if applied
    then
      Sol_cli_json.require ~what [ "version" ] Sol_cli_json.int item
      |> Result.map Option.some
    else Ok None
  in
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error msg -> Error (Printf.sprintf "invalid JSON: %s" msg)
  | json ->
    (match Sol_cli_json.field [ "migrations" ] json with
     | `List items ->
       Sol_cli_result.map_list applied_version items
       |> Result.map (List.filter_map Fun.id)
     | _ -> Error "missing \"migrations\" array")
;;

let unsatisfied ~required ~applied =
  List.filter (fun p -> not (List.mem p.version applied)) required
;;

let status_json ~table rows =
  `Assoc
    [ "table", `String table
    ; ( "migrations"
      , `List
          (rows
           |> List.map (fun (version, name, applied_at) ->
             `Assoc
               [ "version", `Int version
               ; "name", `String name
               ; "applied", `Bool (Option.is_some applied_at)
               ; ( "applied_at"
                 , match applied_at with
                   | Some s -> `String s
                   | None -> `Null )
               ])) )
    ]
  |> Yojson.Safe.to_string
;;

let evidence_report ~waiting ~logs =
  let waiting_line (reason, detail) =
    Printf.sprintf
      "container waiting: %s%s"
      reason
      (Option.fold detail ~none:"" ~some:(fun d -> " -- " ^ d))
  in
  match Option.map waiting_line waiting, Option.map (fun l -> "job logs:\n" ^ l) logs with
  | None, None -> None
  | waiting, logs ->
    Some (String.concat "\n\n" (Option.to_list waiting @ Option.to_list logs))
;;
