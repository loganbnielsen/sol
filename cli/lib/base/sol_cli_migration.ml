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

let parse_version fname =
  let base = Filename.remove_extension fname in
  match String.index_opt base '_' with
  | None -> None
  | Some i ->
    let num = String.sub base 0 i in
    (match int_of_string_opt num with
     | Some version when version >= 0 ->
       Some (version, String.sub base (i + 1) (String.length base - i - 1))
     | _ -> None)
;;

let duplicate_versions named =
  let rec scan acc = function
    | (fa, a) :: ((fb, b) :: _ as rest) when a.version = b.version ->
      scan ((fa, fb, a.version) :: acc) rest
    | _ :: rest -> scan acc rest
    | [] -> List.rev acc
  in
  scan [] (List.stable_sort (fun (_, a) (_, b) -> compare a.version b.version) named)
;;

let shared_version_error ~dir (a, b, version) =
  let message =
    String.concat
      " "
      [ Printf.sprintf "migrations %s and %s in %s share version %d;" a b dir version
      ; "each migration needs its own version, or the runner applies one and silently"
      ; "skips the other -- renumber one of them"
      ]
  in
  Error message
;;

let required ~dir =
  match Sys.readdir dir with
  | exception Sys_error _ -> Ok []
  | arr ->
    let sql =
      Array.to_list arr
      |> List.filter (fun f ->
        Filename.check_suffix f ".sql" && not (Filename.check_suffix f ".down.sql"))
      |> List.sort String.compare
    in
    let rec parse acc = function
      | [] -> Ok (List.rev acc)
      | fname :: rest ->
        (match parse_version fname with
         | Some (version, name) -> parse ((fname, { version; name }) :: acc) rest
         | None ->
           Error
             (Printf.sprintf
                "migration file %S does not start with a numeric version separated by \
                 `_` (expected e.g. `001_create_orders.sql`)"
                (Filename.concat dir fname)))
    in
    (match parse [] sql with
     | Error _ as e -> e
     | Ok named ->
       (match duplicate_versions named with
        | [] -> Ok (List.map snd named)
        | shared :: _ -> shared_version_error ~dir shared))
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
