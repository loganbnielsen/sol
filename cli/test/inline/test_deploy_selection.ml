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
       | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
       | Ok config -> f config)
;;

let omit_charge = Some "services:\n  charge_svc:\n    omit: true\n"

let select ?(image_refs = []) scope =
  match Sol_cli_deploy_selection.select ~scope ~image_refs inventory with
  | Ok selection -> selection
  | Error msg -> Windtrap.fail ("unexpected selection error: " ^ msg)
;;

let apply ~config selection =
  Sol_cli_deploy_selection.apply_target ~target:"dev/aws/us-east-1" ~config selection
;;

let names (deployed : Sol_cli_deploy_selection.deployed) =
  List.map (fun (s : Sol_cli_manifest.service) -> s.name) deployed.services
;;

let expect_refusal ~containing = function
  | Ok _ -> Windtrap.fail "expected a refusal"
  | Error msg ->
    if not (Sol_cli_string.contains ~needle:containing msg)
    then Windtrap.failf "refusal %S does not mention %S" msg containing
;;

let test_undeclared_target_is_refused () =
  with_workspace ~target_body:None (fun config ->
    apply ~config (select None) |> expect_refusal ~containing:"is not declared")
;;

let test_domain_scope_excludes_omitted_unit () =
  with_workspace ~target_body:omit_charge (fun config ->
    match apply ~config (select (Some "payments")) with
    | Error msg -> Windtrap.fail msg
    | Ok deployed ->
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"kept"
        [ "invoice_svc" ]
        (names deployed);
      Windtrap.equal Windtrap.int ~msg:"one note" 1 (List.length deployed.notes);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the note says excluded"
        true
        (Sol_cli_string.contains ~needle:"excluded" (List.hd deployed.notes)))
;;

let test_unit_scope_names_omitted_unit_back_in () =
  with_workspace ~target_body:omit_charge (fun config ->
    match apply ~config (select (Some "payments/charge_svc")) with
    | Error msg -> Windtrap.fail msg
    | Ok deployed ->
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"included"
        [ "charge_svc" ]
        (names deployed);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the note says included"
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
  | Ok _ -> Windtrap.fail "expected --image-ref outside the scope to be refused"
  | Error _ -> ()
;;

let test_target_plan_requires_independent_image_refs () =
  match
    Sol_cli_image_ref.resolve_complete
      ~service_names:[ "charge_svc"; "invoice_svc" ]
      [ Some "charge_svc", digest ]
  with
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the missing image is named"
      true
      (Sol_cli_string.contains ~needle:"missing: invoice_svc" message)
  | Ok _ -> Windtrap.fail "target plan accepted incomplete per-workload image identities"
;;

let test_target_images_inherit_and_override_release_images () =
  let old_charge = "registry.example/charge@sha256:" ^ String.make 64 'b' in
  let new_charge = "registry.example/charge@sha256:" ^ String.make 64 'c' in
  let old_invoice = "registry.example/invoice@sha256:" ^ String.make 64 'd' in
  match
    Sol_cli_image_ref.resolve_with_previous
      ~service_names:[ "charge_svc"; "invoice_svc" ]
      [ Some "charge_svc", new_charge ]
      [ "charge_svc", old_charge; "invoice_svc", old_invoice ]
  with
  | Error message -> Windtrap.fail message
  | Ok images ->
    Windtrap.equal
      (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
      ~msg:"explicit changed image overrides; omitted image inherits"
      [ "charge_svc", new_charge; "invoice_svc", old_invoice ]
      images
;;

let test_target_images_require_missing_or_mutable_release_images () =
  let old_charge = "registry.example/charge@sha256:" ^ String.make 64 'b' in
  let check_missing message =
    Windtrap.equal
      Windtrap.bool
      ~msg:"the workload without an immutable prior image is named"
      true
      (Sol_cli_string.contains ~needle:"invoice_svc" message)
  in
  (match
     Sol_cli_image_ref.resolve_with_previous
       ~service_names:[ "charge_svc"; "invoice_svc" ]
       []
       [ "charge_svc", old_charge ]
   with
   | Ok _ -> Windtrap.fail "target plan accepted a partial release record"
   | Error message -> check_missing message);
  match
    Sol_cli_image_ref.resolve_with_previous
      ~service_names:[ "charge_svc"; "invoice_svc" ]
      []
      [ "charge_svc", old_charge; "invoice_svc", "registry.example/invoice:latest" ]
  with
  | Ok _ -> Windtrap.fail "target plan inherited a missing or mutable image identity"
  | Error message -> check_missing message
;;

let%test "target: undeclared target" = test_undeclared_target_is_refused ()

let%test "target: domain scope excludes omitted" =
  test_domain_scope_excludes_omitted_unit ()
;;

let%test "target: unit scope includes omitted" =
  test_unit_scope_names_omitted_unit_back_in ()
;;

let%test "target: image-ref for omitted unit" =
  test_image_ref_for_omitted_unit_is_refused ()
;;

let%test "target: emptied by omission" = test_selection_emptied_by_omission_is_refused ()

let%test "select: image-ref outside scope" =
  test_image_ref_outside_scope_fails_before_target ()
;;

let%test "plan: all workloads need independent image refs" =
  test_target_plan_requires_independent_image_refs ()
;;

let%test "plan: inherit and override image refs" =
  test_target_images_inherit_and_override_release_images ()
;;

let%test "plan: missing or mutable inherited image" =
  test_target_images_require_missing_or_mutable_release_images ()
;;
