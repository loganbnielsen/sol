let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let mkdir_p path =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote path)))
;;

let with_tmp f =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      ("sol-check-" ^ string_of_int (Random.bits ()))
  in
  mkdir_p root;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root))))
    (fun () ->
       let cwd = Sys.getcwd () in
       Fun.protect
         ~finally:(fun () -> Sys.chdir cwd)
         (fun () ->
            Sys.chdir root;
            f root))
;;

let has_msg needle findings =
  List.exists
    (fun (f : Sol_cli_check.finding) ->
       String.contains f.message needle.[0]
       &&
       try
         ignore (Str.search_forward (Str.regexp_string needle) f.message 0);
         true
       with
       | Not_found -> false)
    findings
;;

let test_missing_app_result () =
  with_tmp (fun _ ->
    match Sol_cli_manifest.discover_services_result () with
    | Error Sol_cli_manifest.Missing_app_dir -> ()
    | Ok _ -> Alcotest.fail "expected missing app error")
;;

let test_discover_valid_service () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    match Sol_cli_manifest.discover_services_result () with
    | Error e -> Alcotest.fail (Sol_cli_manifest.discover_error_to_string e)
    | Ok [ svc ] ->
      Alcotest.(check string) "domain" "payments" svc.domain;
      Alcotest.(check string) "name" "charge_svc" svc.name
    | Ok _ -> Alcotest.fail "expected one service")
;;

let test_typed_scan_reports_missing_dockerfile_and_unexpected_dirs () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    mkdir_p "app/payments/helpers";
    match Sol_cli_manifest.scan_workspace () with
    | Error e -> Alcotest.fail (Sol_cli_manifest.discover_error_to_string e)
    | Ok scan ->
      Alcotest.(check int) "workload count" 1 (List.length scan.workloads);
      let _, has_dockerfile = List.hd scan.workloads in
      Alcotest.(check bool) "has dockerfile false" false has_dockerfile;
      Alcotest.(check int) "unexpected count" 1 (List.length scan.unexpected);
      let _, unexpected_name, _ = List.hd scan.unexpected in
      Alcotest.(check string) "unexpected name" "helpers" unexpected_name)
;;

(* Framework-backed services do not need /healthz or /metrics in their own
   source; the shared pre-deploy phase is static and must not require those
   strings. Runtime probing is CODE_LAYER-022. *)
let test_check_valid_service () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/charge_svc/sol.toml" "[infra.env]\nsecrets = [\"DATABASE_URL\"]\n";
    let findings = Sol_cli_check.run () in
    Alcotest.(check bool) "no errors" false (Sol_cli_check.has_errors findings))
;;

let test_check_bad_secret_key () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/charge_svc/sol.toml" "[infra.env]\nsecrets = [\"bad-key\"]\n";
    let findings = Sol_cli_check.run () in
    Alcotest.(check bool) "has errors" true (Sol_cli_check.has_errors findings);
    Alcotest.(check bool)
      "mentions invalid secret"
      true
      (has_msg "invalid secret key" findings))
;;

let test_check_missing_dockerfile () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    let findings = Sol_cli_check.run () in
    Alcotest.(check bool) "has errors" true (Sol_cli_check.has_errors findings);
    Alcotest.(check bool)
      "mentions Dockerfile"
      true
      (has_msg "Dockerfile is missing" findings))
;;

(* FEAT-065: a command that resolved a scope checks exactly that set, so a bad
   workload outside the selection cannot fail a scoped run. *)
let test_run_services_scopes_the_check () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/charge_svc/sol.toml" "[infra.env]\nsecrets = [\"DATABASE_URL\"]\n";
    mkdir_p "app/comms/notify_worker";
    write "app/comms/notify_worker/Dockerfile" "FROM scratch\n";
    write "app/comms/notify_worker/sol.toml" "[infra.env]\nsecrets = [\"bad-key\"]\n";
    let services = Sol_cli_manifest.discover_services () in
    let charge =
      List.filter (fun (s : Sol_cli_manifest.service) -> s.name = "charge_svc") services
    in
    let findings = Sol_cli_check.run_services charge in
    Alcotest.(check bool)
      "only the selected workload is checked"
      false
      (Sol_cli_check.has_errors findings))
;;

let () =
  Alcotest.run
    "sol_cli_check"
    [ ( "discover"
      , [ Alcotest.test_case "missing app returns error" `Quick test_missing_app_result
        ; Alcotest.test_case "valid service" `Quick test_discover_valid_service
        ; Alcotest.test_case
            "typed scan facts"
            `Quick
            test_typed_scan_reports_missing_dockerfile_and_unexpected_dirs
        ] )
    ; ( "check"
      , [ Alcotest.test_case "valid service" `Quick test_check_valid_service
        ; Alcotest.test_case "bad secret key" `Quick test_check_bad_secret_key
        ; Alcotest.test_case "missing Dockerfile" `Quick test_check_missing_dockerfile
        ; Alcotest.test_case
            "run_services checks only the selected set"
            `Quick
            test_run_services_scopes_the_check
        ] )
    ]
;;
