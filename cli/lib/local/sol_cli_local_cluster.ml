(* REFAC-139, part F: Sol's local k3d cluster, moved out of `cmd_local.ml`. *)

open Result.Syntax

let name = "sol-local"
let registry_port = 5000

(* FRIC-017: k3d v5.6.0's embedded Docker client pins API 1.43, but Docker
   Engine 29 removed every API below 1.44, so any k3d invocation fails with
   "client version 1.43 is too old" on a current host. Ask the daemon for the
   oldest API it still accepts and hand that to k3d via DOCKER_API_VERSION --
   but never below k3d's own 1.43 floor, so older daemons keep working too. *)
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

(* ponytail: FRIC-008, one-time Sun->Sol migration check -- delete this once
   nobody plausibly still has a 'sun-local' cluster around. A pre-rename
   'sun-local' cluster's inline registry binds the same host port this cluster's
   registry needs, causing a silent k3d port-bind conflict with no indication of
   the real cause. Blocks unconditionally on 'sun-local' existing at all (not just
   on a verified port-5000 conflict) -- deliberately simple for a shim meant to be
   deleted. *)
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
    (* FRIC-006: k3d's own output is the actual diagnosis (e.g. "port is already
       allocated") -- surface it instead of leaving the user to re-run k3d by hand
       to find out why. *)
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
