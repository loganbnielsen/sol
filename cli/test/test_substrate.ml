module S = Sol_cli_substrate

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)

let docs_or_fail ?secrets namespaces =
  match S.docs_for_namespaces ?secrets namespaces with
  | Ok docs -> List.map (fun doc -> Sol_cli_yaml.render [ doc ]) docs
  | Error msg -> Alcotest.fail msg
;;

let test_substrate_is_namespace_role_binding_and_runtime_secret_only () =
  let docs = docs_or_fail ~secrets:[ "HOME", "" ] [ "pluto-payments" ] in
  check_int
    "namespace + deploy RoleBinding + operator RoleBinding + runtime Secret"
    4
    (List.length docs);
  check_bool
    "the namespace comes first"
    true
    (Sol_cli_string.contains ~needle:"kind: Namespace" (List.nth docs 0)
     && Sol_cli_string.contains ~needle:"pluto-payments" (List.nth docs 0));
  check_bool
    "then the deploy RoleBinding, scoped to this namespace"
    true
    (Sol_cli_string.contains ~needle:"kind: RoleBinding" (List.nth docs 1)
     && Sol_cli_string.contains ~needle:"namespace: pluto-payments" (List.nth docs 1)
     && Sol_cli_string.contains ~needle:"name: sol-deploy" (List.nth docs 1)
     && Sol_cli_string.contains ~needle:"name: sol:deployers" (List.nth docs 1));
  check_bool
    "then the operator's read-only RoleBinding (DEC-038)"
    true
    (Sol_cli_string.contains ~needle:"kind: RoleBinding" (List.nth docs 2)
     && Sol_cli_string.contains ~needle:"namespace: pluto-payments" (List.nth docs 2)
     && Sol_cli_string.contains ~needle:"name: sol-operator-diagnostics" (List.nth docs 2)
     && Sol_cli_string.contains ~needle:"name: sol:operators" (List.nth docs 2));
  check_bool
    "then the runtime Secret"
    true
    (Sol_cli_string.contains ~needle:"kind: Secret" (List.nth docs 3)
     && Sol_cli_string.contains ~needle:"sol-secrets" (List.nth docs 3));
  docs
  |> List.iter (fun doc ->
    List.iter
      (fun kind ->
         check_bool
           (Printf.sprintf "substrate carries no %s" kind)
           false
           (Sol_cli_string.contains ~needle:kind doc))
      [ "kind: Deployment"
      ; "kind: Service"
      ; "kind: PodDisruptionBudget"
      ; "kind: Ingress"
      ])
;;

let test_every_namespace_and_binding_precedes_every_secret () =
  let docs =
    docs_or_fail ~secrets:[ "HOME", "" ] [ "pluto-checkout"; "pluto-payments" ]
  in
  check_int
    "two namespaces + four RoleBindings (deploy and operator, per namespace) + two \
     runtime Secrets"
    8
    (List.length docs);
  let first_secret =
    let rec find i = function
      | [] -> Alcotest.fail "expected a Secret document"
      | doc :: rest ->
        if Sol_cli_string.contains ~needle:"kind: Secret" doc
        then i
        else find (i + 1) rest
    in
    find 0 docs
  in
  check_bool
    "both namespaces and all four RoleBindings are applied before the first Secret"
    true
    (first_secret = 6);
  List.iter
    (fun ns ->
       check_bool
         (Printf.sprintf "namespace %s is established" ns)
         true
         (List.exists (fun doc -> Sol_cli_string.contains ~needle:ns doc) docs))
    [ "pluto-checkout"; "pluto-payments" ]
;;

let test_missing_credential_fails_closed_before_applying_anything () =
  match
    S.docs_for_namespaces
      ~secrets:[ "SOL_QUALIFICATION_ABSENT_KEY", "" ]
      [ "pluto-payments" ]
  with
  | Ok _ -> Alcotest.fail "expected the substrate to refuse without its credential"
  | Error msg ->
    check_bool
      "names the missing key"
      true
      (Sol_cli_string.contains ~needle:"SOL_QUALIFICATION_ABSENT_KEY" msg);
    check_bool
      "says the substrate cannot be established"
      true
      (Sol_cli_string.contains ~needle:"substrate" msg)
;;

let test_ensure_refuses_a_reserved_platform_namespace () =
  match
    S.ensure ~ctx:Sol_cli_kube_destination.local_context ~namespaces:[ "cert-manager" ]
  with
  | Ok () -> Alcotest.fail "expected ensure to refuse a reserved platform namespace"
  | Error msg ->
    check_bool
      "names the reserved namespace"
      true
      (Sol_cli_string.contains ~needle:"cert-manager" msg);
    check_bool "says it is reserved" true (Sol_cli_string.contains ~needle:"reserved" msg)
;;

let test_present_credential_is_accepted () =
  match S.docs_for_namespaces ~secrets:[ "HOME", "" ] [ "pluto-payments" ] with
  | Ok docs ->
    check_int
      "namespace + deploy RoleBinding + operator RoleBinding + Secret"
      4
      (List.length docs)
  | Error msg -> Alcotest.fail ("expected success, got: " ^ msg)
;;

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s
;;

let fake_kubectl ~log =
  Printf.sprintf
    {|#!/bin/sh
# Classify by the document's kind, record the verdict, then behave like the
# cluster the deploy identity actually talks to.
#
# Sol invokes kubectl as `kubectl --context <destination> <verb> ...`, so the
# destination's flags precede the verb -- find the verb by name, not position.
verb=""
for a in "$@"; do
  case "$a" in
    apply|create|delete|get|patch|replace|rollout|logs) verb="$a"; break ;;
  esac
done
file=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-f" ]; then file="$a"; fi
  prev="$a"
done
kind=other
if [ -n "$file" ] && grep -q 'kind: Namespace' "$file" 2>/dev/null; then
  kind=Namespace
fi
printf '%%s %%s\n' "$verb" "$kind" >> %s
if [ "$kind" = "Namespace" ]; then
  if [ "$verb" = "apply" ]; then
    echo 'Error from server (Forbidden): namespaces "pluto-checkout" is forbidden:' \
         'cannot patch resource "namespaces"' >&2
    exit 1
  fi
  if [ "$verb" = "create" ]; then
    echo 'Error from server (AlreadyExists): namespaces "pluto-checkout" already exists' >&2
    exit 1
  fi
fi
exit 0
|}
    log
;;

let with_fake_kubectl f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let bin = Filename.concat dir "kubectl" in
  let oc = open_out bin in
  output_string oc (fake_kubectl ~log);
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      (try Sys.remove log with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () -> f log)
;;

let test_namespace_is_created_not_applied () =
  with_fake_kubectl (fun log ->
    let ns_yaml =
      Sol_cli_yaml.render [ Sol_cli_manifest.namespace_doc ~ns:"pluto-checkout" ]
    in
    let workload_yaml =
      "---\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: checkout-svc\n"
    in
    Sol_cli_manifest.apply
      ~ctx:Sol_cli_kube_destination.local_context
      (ns_yaml, workload_yaml)
      ~dry_run:false
    |> Result.iter_error (fun msg ->
      Alcotest.failf
        "the namespace was applied instead of created; live error was: %s"
        msg);
    let calls = String.split_on_char '\n' (read_file log) in
    let call verb kind =
      List.exists (fun line -> String.equal (String.trim line) (verb ^ " " ^ kind)) calls
    in
    check_bool "the namespace is created" true (call "create" "Namespace");
    check_bool
      "the namespace is never applied (apply would need patch, which deploy lacks)"
      false
      (call "apply" "Namespace");
    check_bool
      "an AlreadyExists create on an existing namespace is tolerated, not fatal"
      true
      (call "create" "Namespace");
    check_bool "the workload is still applied" true (call "apply" "other"))
;;

let test_operator_bindings_cover_every_workload_namespace () =
  let svc domain name =
    { Sol_cli_manifest.domain; name; primitive = Sol_cli_manifest.Svc; dir = "/tmp" }
  in
  let docs =
    Sol_cli_substrate.operator_binding_docs
      ~workspace:"pluto"
      [ svc "checkout" "checkout_svc"
      ; svc "comms" "notify_worker"
      ; svc "checkout" "refunds"
      ]
    |> List.map (fun doc -> Sol_cli_yaml.render [ doc ])
  in
  check_int
    "one binding per distinct namespace, whoever the caller is"
    2
    (List.length docs);
  let has needle = List.exists (fun doc -> Sol_cli_string.contains ~needle doc) docs in
  check_bool
    "the namespace the caller was not operating on is covered"
    true
    (has "namespace: pluto-comms");
  check_bool "so is the caller's own" true (has "namespace: pluto-checkout");
  docs
  |> List.iter (fun doc ->
    check_bool
      "every document is a RoleBinding"
      true
      (Sol_cli_string.contains ~needle:"kind: RoleBinding" doc);
    check_bool
      "bound to the operator group"
      true
      (Sol_cli_string.contains ~needle:"name: sol:operators" doc);
    check_bool
      "referencing the read-only role"
      true
      (Sol_cli_string.contains ~needle:"name: sol-operator-diagnostics" doc);
    check_bool
      "no Secret is written"
      false
      (Sol_cli_string.contains ~needle:"kind: Secret" doc);
    check_bool
      "no workload document is written"
      false
      (Sol_cli_string.contains ~needle:"kind: Deployment" doc))
;;

let () =
  Alcotest.run
    "substrate"
    [ ( "workspace substrate"
      , [ Alcotest.test_case
            "namespace, RoleBinding and runtime Secret only"
            `Quick
            test_substrate_is_namespace_role_binding_and_runtime_secret_only
        ; Alcotest.test_case
            "every namespace and binding precedes every Secret"
            `Quick
            test_every_namespace_and_binding_precedes_every_secret
        ; Alcotest.test_case
            "missing credential fails closed"
            `Quick
            test_missing_credential_fails_closed_before_applying_anything
        ; Alcotest.test_case
            "present credential is accepted"
            `Quick
            test_present_credential_is_accepted
        ; Alcotest.test_case
            "ensure refuses a reserved platform namespace"
            `Quick
            test_ensure_refuses_a_reserved_platform_namespace
        ; Alcotest.test_case
            "an existing namespace is created, never applied (INFRA-048)"
            `Quick
            test_namespace_is_created_not_applied
        ] )
    ; ( "operator diagnostic bindings (INFRA-058)"
      , [ Alcotest.test_case
            "every workload namespace is covered, RBAC only"
            `Quick
            test_operator_bindings_cover_every_workload_namespace
        ] )
    ]
;;
