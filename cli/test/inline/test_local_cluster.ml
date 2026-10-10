let contains haystack needle =
  let n = String.length needle in
  let len = String.length haystack in
  let rec go i =
    i + n <= len && (String.equal (String.sub haystack i n) needle || go (i + 1))
  in
  n = 0 || go 0
;;

let read_lines path =
  match In_channel.with_open_text path In_channel.input_all with
  | text ->
    String.split_on_char '\n' text
    |> List.map String.trim
    |> List.filter (fun line -> line <> "")
  | exception Sys_error _ -> []
;;

let fake_k3d_body =
  "printf '%s\\n' \"$*\" >> \"$FAKE_K3D_LOG\"\n\
   case \"$*\" in\n\
  \  *'cluster get'*) exit \"${FAKE_K3D_GET_EXIT:-1}\" ;;\n\
  \  *'cluster create'*)\n\
  \    printf 'failed to create cluster: sentinel creation denied\\n' >&2\n\
  \    exit \"${FAKE_K3D_CREATE_EXIT:-0}\"\n\
  \    ;;\n\
   esac\n\
   exit 0\n"
;;

let restore name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""
;;

let with_fake_k3d ?(get_exit = 1) ?(create_exit = 0) f =
  let dir = Filename.temp_file "sol-local-cluster-k3d" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "k3d" in
  let oc = open_out bin in
  output_string oc ("#!/bin/sh\n" ^ fake_k3d_body);
  close_out oc;
  Unix.chmod bin 0o755;
  let log = Filename.concat dir "invocations.log" in
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  let old_log = Sys.getenv_opt "FAKE_K3D_LOG" in
  let old_get = Sys.getenv_opt "FAKE_K3D_GET_EXIT" in
  let old_create = Sys.getenv_opt "FAKE_K3D_CREATE_EXIT" in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Unix.putenv "FAKE_K3D_LOG" log;
  Unix.putenv "FAKE_K3D_GET_EXIT" (string_of_int get_exit);
  Unix.putenv "FAKE_K3D_CREATE_EXIT" (string_of_int create_exit);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      restore "FAKE_K3D_LOG" old_log;
      restore "FAKE_K3D_GET_EXIT" old_get;
      restore "FAKE_K3D_CREATE_EXIT" old_create;
      (try Sys.remove bin with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () -> f log)
;;

let log_has lines needle = List.exists (fun line -> contains line needle) lines

let test_absent_cluster_is_created () =
  with_fake_k3d ~get_exit:1 ~create_exit:0 (fun log ->
    (match Sol_cli_local_cluster.provision () with
     | Ok () -> ()
     | Error message -> Windtrap.failf "an absent cluster must be created: %s" message);
    let lines = read_lines log in
    Windtrap.equal
      Windtrap.bool
      ~msg:"the cluster's presence is observed before creating it"
      true
      (log_has lines "cluster get sol-local");
    Windtrap.equal
      Windtrap.bool
      ~msg:"an absent cluster is created with its registry"
      true
      (log_has lines "cluster create sol-local --registry-create sol-registry:5000"))
;;

let test_existing_cluster_is_reused () =
  with_fake_k3d ~get_exit:0 (fun log ->
    (match Sol_cli_local_cluster.provision () with
     | Ok () -> ()
     | Error message ->
       Windtrap.failf "an existing cluster must be reused, not recreated: %s" message);
    let lines = read_lines log in
    Windtrap.equal
      Windtrap.bool
      ~msg:"the existing cluster is observed"
      true
      (log_has lines "cluster get sol-local");
    Windtrap.equal
      Windtrap.bool
      ~msg:"an existing cluster is never recreated, so its data survives"
      false
      (log_has lines "cluster create"))
;;

let test_creation_failure_is_returned () =
  with_fake_k3d ~get_exit:1 ~create_exit:23 (fun _ ->
    match Sol_cli_local_cluster.provision () with
    | Ok () -> Windtrap.fail "a failed cluster creation must not report success"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:("the original reason is preserved, got: " ^ message)
        true
        (contains message "creation denied"))
;;

let%test "local cluster: an absent cluster is created" = test_absent_cluster_is_created ()

let%test "local cluster: an existing cluster is reused, never recreated" =
  test_existing_cluster_is_reused ()
;;

let%test "local cluster: a failed creation is returned with its reason" =
  test_creation_failure_is_returned ()
;;
