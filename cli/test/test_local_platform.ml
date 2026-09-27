(* REFAC-139, part B: what `sol local infra up` installs is a decision, and now
   a test can read it. *)

let assets =
  { Sol_cli_local_platform.component_values =
      List.map (fun c -> c, c ^ "-values") Sol_cli_local_platform.components
  ; alloy_values = "alloy-values"
  ; dashboards = "dashboards"
  }
;;

let req ?(kafka = false) ?(postgres = false) ?(observability = false) () =
  { Sol_cli_workspace.kafka
  ; postgres
  ; loki = observability
  ; prometheus = observability
  ; tempo = observability
  }
;;

let labels req =
  Sol_cli_local_platform.releases ~req ~assets
  |> List.map (fun (r : Sol_cli_local_platform.release) -> r.label)
;;

let test_everything () =
  Alcotest.(check (list string))
    "each component, in install order"
    [ "Redpanda"
    ; "PostgreSQL"
    ; "Loki"
    ; "Grafana"
    ; "Alloy"
    ; "Tempo"
    ; "Prometheus"
    ; "ingress-nginx"
    ]
    (labels (req ~kafka:true ~postgres:true ~observability:true ()))
;;

let test_ingress_always () =
  Alcotest.(check (list string)) "nothing declared" [ "ingress-nginx" ] (labels (req ()));
  Alcotest.(check bool)
    "no repositories needed"
    false
    (Sol_cli_local_platform.needs_any_chart (req ()))
;;

(* REFAC-107's case: a workspace that declares postgres gets it, whatever its
   language -- the decision reads the declaration, not build files. *)
let test_declared_postgres () =
  Alcotest.(check (list string))
    "postgres and the ingress"
    [ "PostgreSQL"; "ingress-nginx" ]
    (labels (req ~postgres:true ()))
;;

let test_values_come_from_the_assets () =
  let find label =
    Sol_cli_local_platform.releases
      ~req:(req ~kafka:true ~postgres:true ~observability:true ())
      ~assets
    |> List.find (fun (r : Sol_cli_local_platform.release) -> r.label = label)
  in
  Alcotest.(check (option string))
    "a component's merged values"
    (Some "redpanda-values")
    (find "Redpanda").values_yaml;
  Alcotest.(check (option string))
    "Alloy's rendered values"
    (Some "alloy-values")
    (find "Alloy").values_yaml;
  Alcotest.(check (option string))
    "pinned, matching the platform module"
    (Some "26.1.11")
    (find "Redpanda").version
;;

let () =
  Alcotest.run
    "local platform"
    [ ( "REFAC-139 part B"
      , [ Alcotest.test_case "everything" `Quick test_everything
        ; Alcotest.test_case "ingress always" `Quick test_ingress_always
        ; Alcotest.test_case "declared postgres" `Quick test_declared_postgres
        ; Alcotest.test_case
            "values from the assets"
            `Quick
            test_values_come_from_the_assets
        ] )
    ]
;;
