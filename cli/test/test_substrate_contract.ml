open Sol_cli_substrate_contract

let observed_cluster =
  { cluster = `Reachable; registry = None; postgres_url = None; base_domain = None }
;;

let verdict_of input observations =
  match List.assoc_opt input (evaluate observations) with
  | Some verdict -> verdict
  | None -> Alcotest.failf "the contract has no verdict for %s" (name input)
;;

let check_verdict label expected actual =
  Alcotest.(check string) label expected (Sol_cli_installation.verdict_label actual)
;;

let test_every_input_is_answered_once () =
  let verdicts = evaluate observed_cluster in
  List.iter
    (fun input ->
       Alcotest.(check int)
         (Printf.sprintf "one verdict for %s" (name input))
         1
         (List.length (List.filter (fun (i, _) -> i = input) verdicts));
       Alcotest.(check bool)
         (Printf.sprintf "%s has a statement" (name input))
         true
         (String.trim (statement input) <> ""))
    all;
  Alcotest.(check int)
    "a verdict for every input"
    (List.length all)
    (List.length verdicts)
;;

let test_a_cluster_that_cannot_be_looked_at_is_unknown () =
  check_verdict "reachable" "Established" (verdict_of Cluster observed_cluster);
  check_verdict
    "unreachable names the reason"
    "Unmet: no such host"
    (verdict_of Cluster { observed_cluster with cluster = `Unmet "no such host" });
  check_verdict
    "unobservable is UNKNOWN, never satisfied"
    "UNKNOWN: kubectl is not installed"
    (verdict_of
       Cluster
       { observed_cluster with cluster = `Unknown "kubectl is not installed" })
;;

let test_a_missing_connection_is_a_named_unmet () =
  check_verdict
    "without POSTGRES_URL"
    "Unmet: the deploy identity's environment has no POSTGRES_URL, so the workspace's \
     runtime Secret cannot carry the key"
    (verdict_of Postgres observed_cluster);
  check_verdict
    "with POSTGRES_URL"
    "Established"
    (verdict_of Postgres { observed_cluster with postgres_url = Some "postgres://db" })
;;

let test_unobservable_inputs_are_never_satisfied () =
  List.iter
    (fun input ->
       match verdict_of input observed_cluster with
       | Established ->
         Alcotest.failf
           "%s is reported satisfied from the target surface, which cannot observe it"
           (name input)
       | Unmet _ | Unknown _ -> ())
    [ Registry; Kafka; Observability; Domain ]
;;

let test_an_unresolved_input_is_named () =
  let unresolved = unmet_or_unknown (evaluate observed_cluster) in
  Alcotest.(check (list string))
    "only the cluster is established here"
    [ "container registry"
    ; "kafka and schema registry"
    ; "postgres connection"
    ; "observability endpoints"
    ; "base domain and tls"
    ]
    (List.map (fun (input, _) -> name input) unresolved);
  Alcotest.(check int) "and the unresolved count matches" 5 (List.length unresolved)
;;

let test_a_registry_prefix_is_named_in_its_verdict () =
  match verdict_of Registry { observed_cluster with registry = Some "ghcr.io/acme" } with
  | Unknown reason ->
    Alcotest.(check bool)
      "names the prefix"
      true
      (Sol_cli_string.contains ~needle:"ghcr.io/acme" reason)
  | Established -> Alcotest.fail "a prefix Sol cannot verify is not Established"
  | Unmet reason -> Alcotest.failf "a configured prefix is not Unmet: %s" reason
;;

let () =
  Alcotest.run
    "substrate contract"
    [ ( "the contract (DEC-052)"
      , [ Alcotest.test_case
            "every input is answered once"
            `Quick
            test_every_input_is_answered_once
        ; Alcotest.test_case
            "a cluster that cannot be looked at is UNKNOWN"
            `Quick
            test_a_cluster_that_cannot_be_looked_at_is_unknown
        ; Alcotest.test_case
            "a missing connection is a named Unmet"
            `Quick
            test_a_missing_connection_is_a_named_unmet
        ; Alcotest.test_case
            "unobservable inputs are never satisfied"
            `Quick
            test_unobservable_inputs_are_never_satisfied
        ; Alcotest.test_case
            "an unresolved input is named"
            `Quick
            test_an_unresolved_input_is_named
        ; Alcotest.test_case
            "a registry prefix is named in its verdict"
            `Quick
            test_a_registry_prefix_is_named_in_its_verdict
        ] )
    ]
;;
