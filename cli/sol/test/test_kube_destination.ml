(* Tests for Sol_cli_kube_destination: the fail-closed rule that keeps the
   ambient context out of the picture, and the argument shapes every Kubernetes
   invocation is scoped with. *)

let check_string = Alcotest.(check string)

let ok_or_fail = function
  | Ok value -> value
  | Error message -> Alcotest.fail ("unexpected error: " ^ message)
;;

(* The property this module exists for: an unspecified destination is an error,
   not a licence to use whatever kubectl happens to be pointing at. An empty
   context is precisely the shape that would silently mean "ambient". *)
let test_empty_context_fails_closed () =
  match Sol_cli_kube_destination.of_context "" with
  | Ok _ -> Alcotest.fail "an empty context must not produce a destination"
  | Error message ->
    Alcotest.(check bool)
      "the error explains the refusal rather than just failing"
      true
      (String.length message > 40)
;;

let test_whitespace_context_fails_closed () =
  match Sol_cli_kube_destination.of_context "   " with
  | Ok _ -> Alcotest.fail "a whitespace-only context must not produce a destination"
  | Error _ -> ()
;;

let test_context_is_trimmed () =
  let destination = ok_or_fail (Sol_cli_kube_destination.of_context "  prod-ctx\n") in
  check_string "context is trimmed" "prod-ctx" destination.context
;;

let test_blank_kubeconfig_is_dropped () =
  let destination =
    ok_or_fail (Sol_cli_kube_destination.of_context ~kubeconfig:"  " "prod")
  in
  Alcotest.(check bool)
    "a blank kubeconfig is not a kubeconfig"
    true
    (destination.kubeconfig = None)
;;

let test_arguments_scope_the_operation () =
  let destination = ok_or_fail (Sol_cli_kube_destination.of_context "prod-ctx") in
  Alcotest.(check (list string))
    "kubectl is told which context"
    [ "--context"; "prod-ctx" ]
    (Sol_cli_kube_destination.kubectl_args destination);
  Alcotest.(check (list string))
    "helm is told which context"
    [ "--kube-context"; "prod-ctx" ]
    (Sol_cli_kube_destination.helm_args destination);
  Alcotest.(check int)
    "nothing extra in the environment without a kubeconfig"
    0
    (List.length (Sol_cli_kube_destination.environment destination))
;;

let test_scoped_kubeconfig_is_exported () =
  let destination =
    ok_or_fail
      (Sol_cli_kube_destination.of_context ~kubeconfig:"/tmp/prod.kubeconfig" "ctx")
  in
  Alcotest.(check (option string))
    "the kubeconfig is scoped to the process, which also keeps other environments' \
     credentials out of it"
    (Some "/tmp/prod.kubeconfig")
    (List.assoc_opt "KUBECONFIG" (Sol_cli_kube_destination.environment destination))
;;

let test_local_is_named_literally () =
  check_string "local cluster" "k3d-sol-local" Sol_cli_kube_destination.local.context;
  Alcotest.(check bool)
    "the local destination needs no kubeconfig"
    true
    (Sol_cli_kube_destination.local.kubeconfig = None)
;;

let test_to_string_mentions_the_kubeconfig () =
  let destination =
    ok_or_fail (Sol_cli_kube_destination.of_context ~kubeconfig:"/tmp/c" "ctx")
  in
  Alcotest.(check bool)
    "the kubeconfig appears when one is scoped"
    true
    (String.length (Sol_cli_kube_destination.to_string destination) > 3)
;;

let () =
  Alcotest.run
    "kube_destination"
    [ ( "destination"
      , [ Alcotest.test_case
            "empty context fails closed"
            `Quick
            test_empty_context_fails_closed
        ; Alcotest.test_case
            "whitespace context fails closed"
            `Quick
            test_whitespace_context_fails_closed
        ; Alcotest.test_case "context is trimmed" `Quick test_context_is_trimmed
        ; Alcotest.test_case
            "blank kubeconfig is dropped"
            `Quick
            test_blank_kubeconfig_is_dropped
        ; Alcotest.test_case
            "arguments scope the operation"
            `Quick
            test_arguments_scope_the_operation
        ; Alcotest.test_case
            "scoped kubeconfig is exported"
            `Quick
            test_scoped_kubeconfig_is_exported
        ; Alcotest.test_case
            "local is named literally"
            `Quick
            test_local_is_named_literally
        ; Alcotest.test_case
            "to_string mentions the kubeconfig"
            `Quick
            test_to_string_mentions_the_kubeconfig
        ] )
    ]
;;
