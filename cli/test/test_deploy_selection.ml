let svc domain name =
  { Sol_cli_manifest.domain; name; primitive = Sol_cli_manifest.Svc; dir = "" }
;;

let inventory = [ svc "payments" "charge_svc"; svc "payments" "invoice_svc" ]
let digest = "registry.example/charge@sha256:" ^ String.make 64 'a'

let with_workspace ~target_body f =
  let dir = Filename.temp_file "sol-deploy-selection-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir dir;
       Out_channel.with_open_text "sol.yml" (fun oc ->
         output_string
           oc
           {|
project: pluto

services:
  charge_svc:
    type: http
    path: app/payments/charge_svc
  invoice_svc:
    type: http
    path: app/payments/invoice_svc
|});
       Option.iter (Targets_fixture.write ~target:"dev/aws/us-east-1") target_body;
       match Sol_cli_config.load_for_target ~target:"dev/aws/us-east-1" with
       | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
       | Ok config -> f config)
;;

let omit_charge = Some "services:\n  charge_svc:\n    omit: true\n"

let select ?(image_refs = []) scope =
  match Sol_cli_deploy_selection.select ~scope ~image_refs inventory with
  | Ok selection -> selection
  | Error msg -> Alcotest.fail ("unexpected selection error: " ^ msg)
;;

let apply ~config selection =
  Sol_cli_deploy_selection.apply_target ~target:"dev/aws/us-east-1" ~config selection
;;

let names (deployed : Sol_cli_deploy_selection.deployed) =
  List.map (fun (s : Sol_cli_manifest.service) -> s.name) deployed.services
;;

let expect_refusal ~containing = function
  | Ok _ -> Alcotest.fail "expected a refusal"
  | Error msg ->
    if not (Sol_cli_string.contains ~needle:containing msg)
    then Alcotest.failf "refusal %S does not mention %S" msg containing
;;

let test_undeclared_target_is_refused () =
  with_workspace ~target_body:None (fun config ->
    apply ~config (select None) |> expect_refusal ~containing:"is not declared")
;;

let test_domain_scope_excludes_omitted_unit () =
  with_workspace ~target_body:omit_charge (fun config ->
    match apply ~config (select (Some "payments")) with
    | Error msg -> Alcotest.fail msg
    | Ok deployed ->
      Alcotest.(check (list string)) "kept" [ "invoice_svc" ] (names deployed);
      Alcotest.(check int) "one note" 1 (List.length deployed.notes);
      Alcotest.(check bool)
        "the note says excluded"
        true
        (Sol_cli_string.contains ~needle:"excluded" (List.hd deployed.notes)))
;;

let test_unit_scope_names_omitted_unit_back_in () =
  with_workspace ~target_body:omit_charge (fun config ->
    match apply ~config (select (Some "payments/charge_svc")) with
    | Error msg -> Alcotest.fail msg
    | Ok deployed ->
      Alcotest.(check (list string)) "included" [ "charge_svc" ] (names deployed);
      Alcotest.(check bool)
        "the note says included"
        true
        (Sol_cli_string.contains ~needle:"included" (List.hd deployed.notes)))
;;

let test_image_ref_for_omitted_unit_is_refused () =
  with_workspace ~target_body:omit_charge (fun config ->
    select ~image_refs:[ Some "charge_svc", digest ] (Some "payments")
    |> apply ~config
    |> expect_refusal ~containing:"charge_svc")
;;

let test_selection_emptied_by_omission_is_refused () =
  with_workspace
    ~target_body:
      (Some "services:\n  charge_svc:\n    omit: true\n  invoice_svc:\n    omit: true\n")
    (fun config ->
       apply ~config (select (Some "payments")) |> expect_refusal ~containing:"omit")
;;

let test_image_ref_outside_scope_fails_before_target () =
  match
    Sol_cli_deploy_selection.select
      ~scope:(Some "payments/invoice_svc")
      ~image_refs:[ Some "charge_svc", digest ]
      inventory
  with
  | Ok _ -> Alcotest.fail "expected --image-ref outside the scope to be refused"
  | Error _ -> ()
;;

let () =
  Alcotest.run
    "deploy selection"
    [ ( "target"
      , [ Alcotest.test_case "undeclared target" `Quick test_undeclared_target_is_refused
        ; Alcotest.test_case
            "domain scope excludes omitted"
            `Quick
            test_domain_scope_excludes_omitted_unit
        ; Alcotest.test_case
            "unit scope includes omitted"
            `Quick
            test_unit_scope_names_omitted_unit_back_in
        ; Alcotest.test_case
            "image-ref for omitted unit"
            `Quick
            test_image_ref_for_omitted_unit_is_refused
        ; Alcotest.test_case
            "emptied by omission"
            `Quick
            test_selection_emptied_by_omission_is_refused
        ] )
    ; ( "select"
      , [ Alcotest.test_case
            "image-ref outside scope"
            `Quick
            test_image_ref_outside_scope_fails_before_target
        ] )
    ]
;;
