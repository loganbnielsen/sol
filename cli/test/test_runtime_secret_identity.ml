(* INFRA-040: the substrate's Secret and the migration Job's reference are two
   renderings of one identity, and in Attempt 6 they disagreed.

   The substrate created `sol-secrets-secrets` -- because [secret_doc]'s template
   appended `-secrets` to the name it was handed, and the substrate handed it the
   already-final [runtime_secret_name] -- while every consumer asked for
   `sol-secrets`:

     Pod sol-migrate-...: CreateContainerConfigError
       waiting message: secret "sol-secrets" not found
       container envFrom: secretRef{name: sol-secrets}

   Every migration Job's container therefore failed to start, the migration gate
   could never pass, and no workload could be deployed to a cloud target at all.

   This renders the producer and asserts the consumer's source, deliberately rather
   than only asserting that [secret_doc] renders its argument: the helper's own
   behaviour was never in doubt, and a test of it alone would have passed while the
   deployment path created a Secret nobody referenced. The consumer arm is pinned
   structurally by internal/ci/check_runtime_secret_identity.sh, because the
   migration Job's renderer lives in the CLI binary rather than the library. *)

let contains haystack needle = Sol_cli_string.contains ~needle haystack

let assert_contains label haystack needle =
  if not (contains haystack needle)
  then Alcotest.failf "%s: expected to find %S in:\n%s" label needle haystack
;;

let assert_absent label haystack needle =
  if contains haystack needle
  then Alcotest.failf "%s: did not expect to find %S in:\n%s" label needle haystack
;;

let namespace = "pluto-checkout"

let test_substrate_secret_carries_the_runtime_identity () =
  let substrate =
    Sol_cli_manifest.secret_doc
      ~ns:namespace
      ~name:Sol_cli_manifest.runtime_secret_name
      ()
    |> fun doc -> Sol_cli_yaml.render [ doc ]
  in
  Alcotest.(check string)
    "one runtime identity, defined once"
    "sol-secrets"
    Sol_cli_manifest.runtime_secret_name;
  assert_contains
    "the substrate Secret carries that identity"
    substrate
    "  name: sol-secrets\n";
  assert_contains
    "the substrate Secret lands in the workload's namespace"
    substrate
    ("  namespace: " ^ namespace ^ "\n");
  (* The defect, stated as a property: the shared runtime Secret is not
     workload-suffixed, and nothing may render it as though it were. *)
  assert_absent
    "the shared runtime Secret is not suffixed a second time"
    substrate
    "sol-secrets-secrets"
;;

let test_workload_secrets_keep_their_own_convention () =
  Alcotest.(check string)
    "a workload's Secret is its name plus the suffix"
    "charge-svc-secrets"
    (Sol_cli_manifest.workload_secret_name "charge-svc");
  assert_contains
    "and rendering it produces exactly that name"
    (Sol_cli_yaml.render
       [ Sol_cli_manifest.secret_doc
           ~ns:namespace
           ~name:(Sol_cli_manifest.workload_secret_name "charge-svc")
           ()
       ])
    "  name: charge-svc-secrets\n";
  assert_absent
    "a workload Secret is not suffixed twice either"
    (Sol_cli_yaml.render
       [ Sol_cli_manifest.secret_doc
           ~ns:namespace
           ~name:(Sol_cli_manifest.workload_secret_name "charge-svc")
           ()
       ])
    "charge-svc-secrets-secrets"
;;

(* The consumer half, rendered: the migration Job reads the Secret by the same
   identity the substrate creates (REFAC-131 moved its builder into the library,
   so this is now a rendered assertion rather than a source grep). *)
let test_migration_job_reads_the_runtime_identity () =
  let job =
    Sol_cli_yaml.render
      [ Sol_cli_manifest.migration_job_doc
          ~name:"sol-migrate-x"
          ~namespace
          ~image:"runner:1"
          ~args:[ "migrate"; "up" ]
          ~configmap_name:"sol-migrate-files-x"
      ]
  in
  let secret_ref =
    match Yaml.of_string (String.sub job 4 (String.length job - 4)) with
    | Ok (`O fields) ->
      (match List.assoc_opt "spec" fields with
       | Some (`O spec) ->
         (match List.assoc_opt "template" spec with
          | Some (`O template) ->
            (match List.assoc_opt "spec" template with
             | Some (`O pod) ->
               (match List.assoc_opt "containers" pod with
                | Some (`A [ `O container ]) ->
                  (match List.assoc_opt "envFrom" container with
                   | Some (`A [ `O [ ("secretRef", `O [ ("name", `String name) ]) ] ]) ->
                     Some name
                   | _ -> None)
                | _ -> None)
             | _ -> None)
          | _ -> None)
       | _ -> None)
    | _ -> None
  in
  Alcotest.(check (option string))
    "the Job's secretRef is the runtime Secret"
    (Some Sol_cli_manifest.runtime_secret_name)
    secret_ref
;;

let () =
  Alcotest.run
    "runtime secret identity"
    [ ( "infra-040"
      , [ Alcotest.test_case
            "the substrate Secret carries the runtime identity"
            `Quick
            test_substrate_secret_carries_the_runtime_identity
        ; Alcotest.test_case
            "workload Secrets keep their own convention"
            `Quick
            test_workload_secrets_keep_their_own_convention
        ; Alcotest.test_case
            "the migration Job reads the runtime identity"
            `Quick
            test_migration_job_reads_the_runtime_identity
        ] )
    ]
;;
