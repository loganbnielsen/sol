let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let ok_or_fail = function
  | Ok value -> value
  | Error message -> Windtrap.fail ("unexpected error: " ^ message)
;;

let test_empty_context_fails_closed () =
  match Sol_cli_kube_destination.of_context "" with
  | Ok _ -> Windtrap.fail "an empty context must not produce a destination"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the error explains the refusal rather than just failing"
      true
      (String.length message > 40)
;;

let test_whitespace_context_fails_closed () =
  match Sol_cli_kube_destination.of_context "   " with
  | Ok _ -> Windtrap.fail "a whitespace-only context must not produce a destination"
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
  Windtrap.equal
    Windtrap.bool
    ~msg:"a blank kubeconfig is not a kubeconfig"
    true
    (destination.kubeconfig = None)
;;

let test_arguments_scope_the_operation () =
  let destination = ok_or_fail (Sol_cli_kube_destination.of_context "prod-ctx") in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"kubectl is told which context"
    [ "--context"; "prod-ctx" ]
    (Sol_cli_kube_destination.kubectl_args destination);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"helm is told which context"
    [ "--kube-context"; "prod-ctx" ]
    (Sol_cli_kube_destination.helm_args destination);
  Windtrap.equal
    Windtrap.int
    ~msg:"nothing extra in the environment without a kubeconfig"
    0
    (List.length (Sol_cli_kube_destination.environment destination))
;;

let test_scoped_kubeconfig_is_exported () =
  let destination =
    ok_or_fail
      (Sol_cli_kube_destination.of_context ~kubeconfig:"/tmp/prod.kubeconfig" "ctx")
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:
      "the kubeconfig is scoped to the process, which also keeps other environments' \
       credentials out of it"
    (Some "/tmp/prod.kubeconfig")
    (List.assoc_opt "KUBECONFIG" (Sol_cli_kube_destination.environment destination))
;;

let test_local_is_named_literally () =
  check_string "local cluster" "k3d-sol-local" Sol_cli_kube_destination.local.context;
  Windtrap.equal
    Windtrap.bool
    ~msg:"the local destination needs no kubeconfig"
    true
    (Sol_cli_kube_destination.local.kubeconfig = None)
;;

let test_to_string_mentions_the_kubeconfig () =
  let destination =
    ok_or_fail (Sol_cli_kube_destination.of_context ~kubeconfig:"/tmp/c" "ctx")
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the kubeconfig appears when one is scoped"
    true
    (String.length (Sol_cli_kube_destination.to_string destination) > 3)
;;

let test_ambient_context_cannot_leak () =
  let ambient = Filename.temp_file "sol-ambient-" ".kubeconfig" in
  let oc = open_out ambient in
  output_string
    oc
    "apiVersion: v1\n\
     kind: Config\n\
     current-context: definitely-wrong-cluster\n\
     clusters: []\n\
     contexts: []\n\
     users: []\n";
  close_out oc;
  let scoped = Filename.temp_file "sol-scoped-" ".kubeconfig" in
  let saved = Sys.getenv_opt "KUBECONFIG" in
  Unix.putenv "KUBECONFIG" ambient;
  Fun.protect
    ~finally:(fun () ->
      saved |> Option.iter (fun v -> Unix.putenv "KUBECONFIG" v);
      (try Sys.remove ambient with
       | _ -> ());
      try Sys.remove scoped with
      | _ -> ())
    (fun () ->
       let destination =
         ok_or_fail (Sol_cli_kube_destination.of_context ~kubeconfig:scoped "sol-staging")
       in
       let ctx = Sol_cli_kube_destination.context_of_destination destination in
       Windtrap.equal
         (Windtrap.list Windtrap.string)
         ~msg:"argv names the target's context, not the ambient one"
         [ "--context"; "sol-staging" ]
         (Sol_cli_kube_destination.kubectl_context_args ctx);
       let env = Array.to_list (Sol_cli_kube_destination.child_environment ctx) in
       let kubeconfig_in_env =
         List.filter_map
           (fun entry ->
              match String.index_opt entry '=' with
              | None -> None
              | Some i ->
                Some
                  ( String.sub entry 0 i
                  , String.sub entry (i + 1) (String.length entry - i - 1) ))
           env
         |> List.assoc_opt "KUBECONFIG"
       in
       Windtrap.equal
         (Windtrap.option Windtrap.string)
         ~msg:"the child env pins the target's kubeconfig, not the ambient one"
         (Some scoped)
         kubeconfig_in_env;
       Windtrap.equal
         Windtrap.bool
         ~msg:"the ambient context name appears nowhere in the invocation"
         false
         (List.mem
            "definitely-wrong-cluster"
            (Sol_cli_kube_destination.kubectl_context_args ctx)))
;;

let%test "destination: empty context fails closed" = test_empty_context_fails_closed ()

let%test "destination: whitespace context fails closed" =
  test_whitespace_context_fails_closed ()
;;

let%test "destination: context is trimmed" = test_context_is_trimmed ()
let%test "destination: blank kubeconfig is dropped" = test_blank_kubeconfig_is_dropped ()

let%test "destination: arguments scope the operation" =
  test_arguments_scope_the_operation ()
;;

let%test "destination: scoped kubeconfig is exported" =
  test_scoped_kubeconfig_is_exported ()
;;

let%test "destination: local is named literally" = test_local_is_named_literally ()

let%test "destination: to_string mentions the kubeconfig" =
  test_to_string_mentions_the_kubeconfig ()
;;

let%test "destination: ambient context cannot leak" = test_ambient_context_cannot_leak ()
