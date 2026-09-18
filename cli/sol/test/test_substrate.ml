(* HARDEN-002 run 2, finding 8: the workspace execution substrate is a layer of its
   own, established before anything that needs it (the migration gate included)
   rather than by workload mutation.

   The user-facing acceptance test is the live sequence -- on a freshly
   provisioned target with no application namespace, `sol migrate apply` then
   `sol migrate status` then `sol deploy` succeed with no out-of-band kubectl --
   which needs a cluster and is run by HARDEN-002 itself. These tests pin the
   layer properties that made the defect possible in the first place. *)

module S = Sol_cli_substrate

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)

let contains ~needle s =
  let nlen = String.length needle
  and slen = String.length s in
  let rec loop i = i + nlen <= slen && (String.sub s i nlen = needle || loop (i + 1)) in
  nlen = 0 || loop 0
;;

let docs_or_fail ?secrets namespaces =
  match S.docs_for_namespaces ?secrets namespaces with
  | Ok docs -> docs
  | Error msg -> Alcotest.fail msg
;;

(* The substrate is a namespace, the deploy identity's RoleBinding in it
   (INFRA-025), and the workspace's runtime Secret. Nothing else: if a
   Deployment or Service ever appears here the layer has been misassigned
   again, which is exactly the bug this module exists to prevent. *)
let test_substrate_is_namespace_role_binding_and_runtime_secret_only () =
  (* Explicit keys, always present in the test environment: the default key set
     (POSTGRES_URL, SOL_API_KEY) is deliberately absent here, which is what the
     fail-closed test below relies on. *)
  let docs = docs_or_fail ~secrets:[ "HOME", "" ] [ "pluto-payments" ] in
  check_int "one namespace + one RoleBinding + one runtime Secret" 3 (List.length docs);
  check_bool
    "the namespace comes first"
    true
    (contains ~needle:"kind: Namespace" (List.nth docs 0)
     && contains ~needle:"pluto-payments" (List.nth docs 0));
  check_bool
    "then the deploy RoleBinding, scoped to this namespace"
    true
    (contains ~needle:"kind: RoleBinding" (List.nth docs 1)
     && contains ~needle:"namespace: pluto-payments" (List.nth docs 1)
     && contains ~needle:"name: sol-deploy" (List.nth docs 1)
     && contains ~needle:"name: sol:deployers" (List.nth docs 1));
  check_bool
    "then the runtime Secret"
    true
    (contains ~needle:"kind: Secret" (List.nth docs 2)
     && contains ~needle:"sol-secrets" (List.nth docs 2));
  List.iter
    (fun doc ->
       List.iter
         (fun kind ->
            check_bool
              (Printf.sprintf "substrate carries no %s" kind)
              false
              (contains ~needle:kind doc))
         [ "kind: Deployment"
         ; "kind: Service"
         ; "kind: PodDisruptionBudget"
         ; "kind: Ingress"
         ])
    docs
;;

(* Namespaces and RoleBindings all come before any Secret: a Secret in a
   namespace that does not exist yet is the failure mode that blocked a fresh
   target's first deploy, and the RoleBinding must exist before the deploy
   identity needs to patch the Secret into place. *)
let test_every_namespace_and_binding_precedes_every_secret () =
  let docs =
    docs_or_fail ~secrets:[ "HOME", "" ] [ "pluto-checkout"; "pluto-payments" ]
  in
  check_int "two namespaces + two RoleBindings + two runtime Secrets" 6 (List.length docs);
  let first_secret =
    let rec find i = function
      | [] -> Alcotest.fail "expected a Secret document"
      | doc :: rest ->
        if contains ~needle:"kind: Secret" doc then i else find (i + 1) rest
    in
    find 0 docs
  in
  check_bool
    "both namespaces and both RoleBindings are applied before the first Secret"
    true
    (first_secret = 4);
  List.iter
    (fun ns ->
       check_bool
         (Printf.sprintf "namespace %s is established" ns)
         true
         (List.exists (fun doc -> contains ~needle:ns doc) docs))
    [ "pluto-checkout"; "pluto-payments" ]
;;

(* A declared credential that is not in the environment must fail the substrate
   closed rather than establish an empty Secret: the migration gate could not
   verify anything through it, and an empty credential is worse than a refusal. *)
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
      (contains ~needle:"SOL_QUALIFICATION_ABSENT_KEY" msg);
    check_bool
      "says the substrate cannot be established"
      true
      (contains ~needle:"substrate" msg)
;;

(* INFRA-025: RBAC cannot itself stop the deploy identity's bootstrap grant
   from reaching a platform namespace (see the comment on
   [reserved_platform_namespaces]), so this client-side refusal is the
   software-side half of that mitigation. It must fire before any kubectl
   call -- this test passes [local_context] precisely to prove the check
   short-circuits without ever touching the destination. *)
let test_ensure_refuses_a_reserved_platform_namespace () =
  match
    S.ensure ~ctx:Sol_cli_kube_destination.local_context ~namespaces:[ "cert-manager" ]
  with
  | Ok () -> Alcotest.fail "expected ensure to refuse a reserved platform namespace"
  | Error msg ->
    check_bool "names the reserved namespace" true (contains ~needle:"cert-manager" msg);
    check_bool "says it is reserved" true (contains ~needle:"reserved" msg)
;;

let test_present_credential_is_accepted () =
  (* HOME is always set in the test environment. *)
  match S.docs_for_namespaces ~secrets:[ "HOME", "" ] [ "pluto-payments" ] with
  | Ok docs -> check_int "namespace + RoleBinding + Secret" 3 (List.length docs)
  | Error msg -> Alcotest.fail ("expected success, got: " ^ msg)
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
        ] )
    ]
;;
