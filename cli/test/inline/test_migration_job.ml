let with_fake_kubectl script f =
  let dir = Filename.temp_dir "sol-fake-kubectl-" "" in
  let bin = Filename.concat dir "kubectl" in
  Out_channel.with_open_text bin (fun oc -> output_string oc script);
  Unix.chmod bin 0o755;
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      ignore (Sol_cli_fs.remove_tree dir))
    f
;;

let fake ~succeeded ~waiting =
  Printf.sprintf
    {|#!/bin/sh
case "$*" in
  *"get job"*"status.succeeded"*) printf '%s' ;;
  *"get job"*"status.failed"*) printf '' ;;
  *"get pods"*) printf '%%s' '%s' ;;
  *) exit 1 ;;
esac
|}
    succeeded
    waiting
;;

let job =
  { Sol_cli_migration_job.namespace = "pluto-payments"
  ; job_name = "sol-migrate-1"
  ; configmap_name = Some "sol-migrate-files-1"
  }
;;

let wait () =
  Sol_cli_migration_job.wait
    ~ctx:Sol_cli_kube_destination.local_context
    ~interval_s:0.01
    ~attempts:5
    job
;;

let test_unstartable_fails_fast () =
  with_fake_kubectl
    (fake
       ~succeeded:""
       ~waiting:{|CreateContainerConfigError|secret "sol-secrets" not found|})
    (fun () ->
       match wait () with
       | Unstartable { reason; detail } ->
         Windtrap.equal
           Windtrap.string
           ~msg:"the reason"
           "CreateContainerConfigError"
           reason;
         Windtrap.equal
           (Windtrap.option Windtrap.string)
           ~msg:"the message naming the thing"
           (Some {|secret "sol-secrets" not found|})
           detail
       | _ -> Windtrap.fail "a container that cannot start was waited on")
;;

let test_succeeded () =
  with_fake_kubectl (fake ~succeeded:"1" ~waiting:"") (fun () ->
    match wait () with
    | Succeeded -> ()
    | _ -> Windtrap.fail "a succeeded Job was not read as succeeded")
;;

let test_times_out_on_a_transient_wait () =
  with_fake_kubectl (fake ~succeeded:"" ~waiting:"ContainerCreating|") (fun () ->
    match wait () with
    | Timed_out _ -> ()
    | _ -> Windtrap.fail "a transient waiting reason ended the wait")
;;

let service domain name : Sol_cli_manifest.service =
  { domain; name; primitive = Sol_cli_manifest.Svc; dir = "app/" ^ domain ^ "/" ^ name }
;;

let test_job_namespace () =
  Windtrap.equal
    (Windtrap.result Windtrap.string Windtrap.string)
    ~msg:"the first service by domain, then name"
    (Ok "pluto-checkout")
    (Sol_cli_migration_job.job_namespace
       ~workspace:"pluto"
       ~services:[ service "payments" "charge_svc"; service "checkout" "checkout_svc" ]);
  Windtrap.equal
    Windtrap.bool
    ~msg:"no services is an error"
    true
    (Result.is_error
       (Sol_cli_migration_job.job_namespace ~workspace:"pluto" ~services:[]))
;;

let%test "REFAC-139 part A: unstartable fails fast" = test_unstartable_fails_fast ()
let%test "REFAC-139 part A: succeeded" = test_succeeded ()

let%test "REFAC-139 part A: a transient wait runs to its bound" =
  test_times_out_on_a_transient_wait ()
;;

let%test "REFAC-139 part A: job namespace" = test_job_namespace ()
