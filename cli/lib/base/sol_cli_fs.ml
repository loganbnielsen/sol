open Result.Syntax

let unix_error path e = Error (Printf.sprintf "%s: %s" path (Unix.error_message e))

let remove_if_present path =
  match Unix.unlink path with
  | () -> Ok ()
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | exception Unix.Unix_error (e, _, _) -> unix_error path e
;;

let remove_reporting path =
  remove_if_present path
  |> Result.iter_error (Sol_cli_report.warn "warning: could not remove %s")
;;

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | exception Unix.Unix_error (e, _, _) -> unix_error path e
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    let* entries =
      match Sys.readdir path with
      | entries -> Ok (Array.to_list entries)
      | exception Sys_error message -> Error message
    in
    let* _ =
      entries
      |> Sol_cli_result.map_list (fun entry -> remove_tree (Filename.concat path entry))
    in
    (match Unix.rmdir path with
     | () -> Ok ()
     | exception Unix.Unix_error (e, _, _) -> unix_error path e)
  | _ -> remove_if_present path
;;

(* Unix.stat follows symlinks, so a symlink to a directory is usable; lstat tells
   "nothing here" apart from "a dirent stat cannot resolve" (a dangling link). *)
let usable_as_directory dir =
  match Unix.stat dir with
  | { Unix.st_kind = Unix.S_DIR; _ } -> true
  | _ | (exception Unix.Unix_error _) -> false
;;

let rec mkdir_p ?(perm = 0o755) dir =
  if dir = "" || dir = "." || dir = "/" || usable_as_directory dir
  then Ok ()
  else (
    match Unix.lstat dir with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      let* () = mkdir_p ~perm (Filename.dirname dir) in
      (match Unix.mkdir dir perm with
       | () -> Ok ()
       | exception Unix.Unix_error (Unix.EEXIST, _, _) when usable_as_directory dir ->
         (* Lost a race with a concurrent creator. *)
         Ok ()
       | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
         Error
           (Printf.sprintf
              "could not create directory %s: path exists but is not usable as a \
               directory (broken symlink?)"
              dir)
       | exception Unix.Unix_error (e, _, _) ->
         Error
           (Printf.sprintf "could not create directory %s: %s" dir (Unix.error_message e)))
    | exception Unix.Unix_error (e, _, _) ->
      Error
        (Printf.sprintf "could not create directory %s: %s" dir (Unix.error_message e))
    | _ ->
      Error
        (Printf.sprintf
           "could not create directory %s: a non-directory already exists at that path"
           dir))
;;

let write_file ?(perm = 0o644) path content =
  match
    Out_channel.with_open_gen
      [ Open_wronly; Open_creat; Open_trunc; Open_binary ]
      perm
      path
      (fun oc -> Out_channel.output_string oc content)
  with
  | () -> Ok ()
  | exception Sys_error message -> Error message
;;

let write_atomic ?perm path content =
  let tmp = path ^ ".tmp-" ^ string_of_int (Unix.getpid ()) in
  let* () = write_file ?perm tmp content in
  (* Creation goes through the umask; a caller that names a mode gets it. *)
  let* () =
    match perm with
    | None -> Ok ()
    | Some perm ->
      (match Unix.chmod tmp perm with
       | () -> Ok ()
       | exception Unix.Unix_error (e, _, _) -> unix_error tmp e)
  in
  match Unix.rename tmp path with
  | () -> Ok ()
  | exception Unix.Unix_error (e, _, _) ->
    ignore (remove_if_present tmp);
    unix_error path e
;;

let with_temp_file ~prefix ~suffix content f =
  let* path =
    match Filename.temp_file prefix suffix with
    | path -> Ok path
    | exception Sys_error message -> Error message
  in
  let cleanup () = remove_reporting path in
  match write_file ~perm:0o600 path content with
  | Error _ as e ->
    cleanup ();
    e
  | Ok () -> Ok (Fun.protect ~finally:cleanup (fun () -> f path))
;;

(* The permission bits exactly, as `rsync -a` keeps them: creation goes through
   the umask, so they are set again afterwards. *)
let copy_file ~src ~dst ~perm =
  match In_channel.with_open_bin src In_channel.input_all with
  | exception Sys_error message -> Error message
  | content ->
    let* () = write_file ~perm dst content in
    (match Unix.chmod dst perm with
     | () -> Ok ()
     | exception Unix.Unix_error (e, _, _) -> unix_error dst e)
;;

let rec copy_tree ~exclude ~src ~dst =
  match Unix.stat src with
  | exception Unix.Unix_error (e, _, _) -> unix_error src e
  | { Unix.st_kind = Unix.S_DIR; st_perm; _ } ->
    let* () =
      match Unix.mkdir dst st_perm with
      | () -> Ok ()
      | exception Unix.Unix_error (e, _, _) -> unix_error dst e
    in
    let* entries =
      match Sys.readdir src with
      | entries -> Ok (List.sort String.compare (Array.to_list entries))
      | exception Sys_error message -> Error message
    in
    entries
    |> List.filter (fun entry -> not (List.mem entry exclude))
    |> Sol_cli_result.map_list (fun entry ->
      copy_tree ~exclude ~src:(Filename.concat src entry) ~dst:(Filename.concat dst entry))
    |> Result.map ignore
  | { Unix.st_kind = Unix.S_REG; st_perm; _ } -> copy_file ~src ~dst ~perm:st_perm
  | _ ->
    (* Sockets, fifos and devices have no place in a build context. *)
    Ok ()
;;
