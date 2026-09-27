(* REFAC-139, part A: the migration Job runner both `sol migrate apply` and the
   deploy's prerequisite check use. The wait is exercised against a fake kubectl
   on PATH, so the INFRA-040 fail-fast -- which only the check used to have -- is
   held for the one runner both paths now share. *)

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

(* Answers the three reads the wait makes: the Job's succeeded and failed counts,
   and its pods' waiting state. *)
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
  ; configmap_name = "sol-migrate-files-1"
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
         Alcotest.(check string) "the reason" "CreateContainerConfigError" reason;
         Alcotest.(check (option string))
           "the message naming the thing"
           (Some {|secret "sol-secrets" not found|})
           detail
       | _ -> Alcotest.fail "a container that cannot start was waited on")
;;

let test_succeeded () =
  with_fake_kubectl (fake ~succeeded:"1" ~waiting:"") (fun () ->
    match wait () with
    | Succeeded -> ()
    | _ -> Alcotest.fail "a succeeded Job was not read as succeeded")
;;

let test_times_out_on_a_transient_wait () =
  (* ContainerCreating is not terminal: the wait continues to its bound. *)
  with_fake_kubectl (fake ~succeeded:"" ~waiting:"ContainerCreating|") (fun () ->
    match wait () with
    | Timed_out _ -> ()
    | _ -> Alcotest.fail "a transient waiting reason ended the wait")
;;

let service domain name : Sol_cli_manifest.service =
  { domain; name; primitive = Sol_cli_manifest.Svc; dir = "app/" ^ domain ^ "/" ^ name }
;;

let test_namespace_and_repository () =
  Alcotest.(check (result (pair string string) string))
    "the first service by domain, then name"
    (Ok ("pluto-checkout", "checkout-svc"))
    (Sol_cli_migration_job.namespace_and_repository
       ~workspace:"pluto"
       ~services:[ service "payments" "charge_svc"; service "checkout" "checkout_svc" ]
     |> Result.map (fun (ns, name) -> ns, Sol_cli_kubernetes_name.k8s_name_to_string name)
    );
  Alcotest.(check bool)
    "no services is an error"
    true
    (Result.is_error
       (Sol_cli_migration_job.namespace_and_repository ~workspace:"pluto" ~services:[]))
;;

let () =
  Alcotest.run
    "migration job"
    [ ( "REFAC-139 part A"
      , [ Alcotest.test_case "unstartable fails fast" `Quick test_unstartable_fails_fast
        ; Alcotest.test_case "succeeded" `Quick test_succeeded
        ; Alcotest.test_case
            "a transient wait runs to its bound"
            `Quick
            test_times_out_on_a_transient_wait
        ; Alcotest.test_case
            "namespace and repository"
            `Quick
            test_namespace_and_repository
        ] )
    ]
;;
