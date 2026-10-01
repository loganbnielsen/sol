let delete_payloads output =
  let open Sol_cli_json in
  let open Result.Syntax in
  let* json = decode ~what:"the state bucket's object versions" output in
  let objects name =
    match field [ name ] json |> list with
    | None -> []
    | Some entries ->
      List.filter_map
        (fun entry ->
           match
             field [ "Key" ] entry |> string, field [ "VersionId" ] entry |> string
           with
           | Some key, Some version_id ->
             Some (`Assoc [ "Key", `String key; "VersionId", `String version_id ])
           | _ -> None)
        entries
  in
  let chunk all =
    let rec go acc current = function
      | [] -> List.rev (if current = [] then acc else List.rev current :: acc)
      | entry :: rest when List.length current = 1000 ->
        go (List.rev current :: acc) [ entry ] rest
      | entry :: rest -> go acc (entry :: current) rest
    in
    go [] [] all
  in
  let payloads =
    objects "Versions" @ objects "DeleteMarkers"
    |> chunk
    |> List.map (fun entries ->
      Yojson.Safe.to_string (`Assoc [ "Objects", `List entries; "Quiet", `Bool true ]))
  in
  Ok payloads
;;

let observe_to_result = function
  | Sol_cli_installation.Observed _ -> Ok ()
  | Sol_cli_installation.Absent reason -> Error reason
  | Sol_cli_installation.Unobservable reason -> Error reason
;;

let retire ~run (configuration : Sol_cli_installation.installation_config) =
  let open Result.Syntax in
  let bucket = configuration.state_bucket in
  match
    run [ "aws"; "s3api"; "list-object-versions"; "--bucket"; bucket; "--output"; "json" ]
  with
  | Sol_cli_installation.Unobservable reason -> Error reason
  | Sol_cli_installation.Absent _ -> Ok ()
  | Sol_cli_installation.Observed output ->
    let* payloads = delete_payloads output in
    let* () =
      List.fold_left
        (fun accumulated payload ->
           let* () = accumulated in
           observe_to_result
             (run
                [ "aws"
                ; "s3api"
                ; "delete-objects"
                ; "--bucket"
                ; bucket
                ; "--delete"
                ; payload
                ]))
        (Ok ())
        payloads
    in
    observe_to_result (run [ "aws"; "s3api"; "delete-bucket"; "--bucket"; bucket ])
;;
