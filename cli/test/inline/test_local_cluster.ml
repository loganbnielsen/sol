let contains haystack needle =
  let n = String.length needle in
  let len = String.length haystack in
  let rec go i =
    i + n <= len && (String.equal (String.sub haystack i n) needle || go (i + 1))
  in
  n = 0 || go 0
;;

let with_path path f =
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Unix.putenv "PATH" path;
  Fun.protect ~finally:(fun () -> Unix.putenv "PATH" old_path) f
;;

let with_fake_k3d script f =
  let dir = Filename.temp_file "sol-local-cluster-k3d" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "k3d" in
  let oc = open_out bin in
  output_string oc script;
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    f
;;

let test_delete_failure_is_returned () =
  with_fake_k3d
    "#!/bin/sh\n\
     printf 'failed to delete cluster: sentinel deletion denied\\n' >&2\n\
     exit 23\n"
    (fun () ->
       match Sol_cli_local_cluster.delete () with
       | Error message ->
         Windtrap.is_true
           ~msg:("the original reason is preserved, got: " ^ message)
           (contains message "deletion denied")
       | Ok () -> Windtrap.fail "a failed deletion must not report success")
;;

let test_successful_deletion_and_absence () =
  with_fake_k3d
    "#!/bin/sh\ncase \"$*\" in\n  *'cluster get'*) exit 1 ;;\n  *) exit 0 ;;\nesac\n"
    (fun () ->
       (match Sol_cli_local_cluster.delete () with
        | Ok () -> ()
        | Error message -> Windtrap.failf "unexpected delete failure: %s" message);
       match Sol_cli_local_cluster.confirm_removed () with
       | Ok () -> ()
       | Error message ->
         Windtrap.failf "a confirmed-absent cluster must succeed: %s" message)
;;

let test_present_after_delete_is_not_removed () =
  with_fake_k3d "#!/bin/sh\nexit 0\n" (fun () ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"a cluster that is still present is not confirmed removed"
      false
      (Result.is_ok (Sol_cli_local_cluster.confirm_removed ())))
;;

let test_unobservable_is_not_confirmed_removed () =
  let dir = Filename.temp_file "sol-local-cluster-empty" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      try Unix.rmdir dir with
      | _ -> ())
    (fun () ->
       with_path dir (fun () ->
         match Sol_cli_local_cluster.observe () with
         | Sol_cli_local_cluster.Cluster_unobservable _ -> ()
         | Sol_cli_local_cluster.Cluster_present ->
           Windtrap.fail "a missing k3d cannot observe a present cluster"
         | Sol_cli_local_cluster.Cluster_absent ->
           Windtrap.fail "a missing k3d cannot confirm absence"))
;;

let%test "local cluster: a failed deletion is returned with its reason" =
  test_delete_failure_is_returned ()
;;

let%test "local cluster: a successful deletion with confirmed absence succeeds" =
  test_successful_deletion_and_absence ()
;;

let%test "local cluster: a cluster still present is not confirmed removed" =
  test_present_after_delete_is_not_removed ()
;;

let%test "local cluster: an unobservable k3d cannot confirm removal" =
  test_unobservable_is_not_confirmed_removed ()
;;
