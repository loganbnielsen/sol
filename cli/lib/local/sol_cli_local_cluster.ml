open Result.Syntax

let name = "sol-local"
let registry_port = 5000
let k3d_client_api_floor = "1.43"

let version_gt a b =
  let parts s = String.split_on_char '.' s |> List.filter_map int_of_string_opt in
  let rec cmp x y =
    match x, y with
    | [], [] -> 0
    | x :: xs, y :: ys -> if x <> y then compare x y else cmp xs ys
    | x :: _, [] -> compare x 0
    | [], y :: _ -> compare 0 y
  in
  cmp (parts a) (parts b) > 0
;;

let api_version_env ~daemon_min =
  let daemon_min = String.trim daemon_min in
  if daemon_min <> "" && version_gt daemon_min k3d_client_api_floor
  then [ "DOCKER_API_VERSION", daemon_min ]
  else []
;;

let k3d_env () =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd
         [ "docker"; "version"; "--format"; "{{.Server.MinAPIVersion}}" ])
  with
  | Ok r -> api_version_env ~daemon_min:r.stdout
  | Error _ -> []
;;

let k3d args = Sol_cli_process.cmd ~env:(k3d_env ()) ("k3d" :: args)
let exists () = Result.is_ok (Sol_cli_process.run (k3d [ "cluster"; "get"; name ]))

let refuse_pre_rename_cluster () =
  let pre_rename = "sun-local" in
  if Result.is_ok (Sol_cli_process.run (k3d [ "cluster"; "get"; pre_rename ]))
  then
    Error
      (Printf.sprintf
         "found a pre-rename '%s' k3d cluster.\n\
         \  Sol's local cluster is now named '%s', and its registry would try\n\
         \  to bind the same host port (%d) that '%s'/'sun-registry' would also use.\n\
         \  Remove the old cluster first:\n\
         \    k3d cluster delete %s\n\
         \  (rename or keep it yourself first if you still need it for something else)"
         pre_rename
         name
         registry_port
         pre_rename
         pre_rename)
  else Ok ()
;;

let provision () =
  if exists ()
  then (
    Sol_cli_report.app "  cluster %s already exists, skipping" name;
    Ok ())
  else
    let* () = refuse_pre_rename_cluster () in
    Sol_cli_process.run
      ~echo:true
      (k3d
         [ "cluster"
         ; "create"
         ; name
         ; "--registry-create"
         ; Printf.sprintf "sol-registry:%d" registry_port
         ])
    |> Result.map ignore
    |> Result.map_error (fun failure ->
      "cluster creation failed\n"
      ^
      match failure with
      | Sol_cli_process.Non_zero r -> Sol_cli_process.failure_message r
      | e -> Sol_cli_process.error_to_string e)
;;

let delete () = ignore (Sol_cli_process.run (k3d [ "cluster"; "delete"; name ]))
