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

(* ── INFRA-048 / FND-0011: the namespace is created, never applied ───────────

   The live defect: the apply path ran `kubectl apply` over the Namespace
   document, which requires `patch`, which the deploy identity's bootstrap grant
   deliberately withholds. Sol_cli_substrate.ensure always creates the namespace
   first, so that apply could only ever be refused -- on the first deploy and on
   the migration-gate recovery path the deploy itself prints.

   The fake kubectl below reproduces the live role exactly: it refuses `apply` on
   a Namespace (as the API server did) and answers `create` on an existing
   Namespace with AlreadyExists (as it does once the substrate has run). The test
   therefore drives the real condition -- an existing namespace with no
   last-applied annotation -- rather than a sanitised one, and fails with the
   live failure if the apply path ever returns to `kubectl apply` for it. *)

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
    let ns_yaml = Sol_cli_manifest.namespace_doc ~ns:"pluto-checkout" in
    let workload_yaml =
      "---\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: checkout-svc\n"
    in
    (* Before the fix this raises Deploy_failed carrying the live Forbidden
       error: the namespace is applied rather than created. *)
    (try
       Sol_cli_manifest.apply
         ~ctx:Sol_cli_kube_destination.local_context
         (ns_yaml, workload_yaml)
         ~dry_run:false
     with
     | Sol_cli_manifest.Deploy_failed msg ->
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
    ]
;;
