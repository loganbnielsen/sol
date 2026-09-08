let check_bool = Alcotest.(check bool)

let mkdir_p path =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote path)))

let with_tmpdir f =
  let tmpdir = Filename.temp_file "sol-workspace-root-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () -> f tmpdir)

let test_finds_root_from_root () =
  with_tmpdir (fun tmpdir ->
    mkdir_p (Filename.concat tmpdir "app");
    check_bool "root itself resolves" true
      (Sol_cli_workspace.find_root ~dir:tmpdir = Some tmpdir))

let test_finds_root_from_nested_service_dir () =
  with_tmpdir (fun tmpdir ->
    let nested = Filename.concat tmpdir "app/payments/charge_svc" in
    mkdir_p nested;
    check_bool "nested dir walks up to root" true
      (Sol_cli_workspace.find_root ~dir:nested = Some tmpdir))

let test_none_outside_any_workspace () =
  with_tmpdir (fun tmpdir ->
    (* no app/ anywhere under tmpdir *)
    check_bool "no app/ ancestor -> None" true
      (Sol_cli_workspace.find_root ~dir:tmpdir = None))

let test_app_must_be_a_directory () =
  with_tmpdir (fun tmpdir ->
    let oc = open_out (Filename.concat tmpdir "app") in
    close_out oc;
    check_bool "a plain file named app/ doesn't count" true
      (Sol_cli_workspace.find_root ~dir:tmpdir = None))

(* OBS-042: obs-tempo-eio in a dune file's libraries stanza should flip
   [tempo] the same way obs-loki-eio/obs-prometheus-eio already flip
   [loki]/[prometheus] -- this is what lets `sol dev up` install Tempo only
   for workspaces that actually wired a -svc up to it. *)
let test_scan_detects_tempo () =
  with_tmpdir (fun tmpdir ->
    let svc_dir = Filename.concat tmpdir "app/payments/charge_svc/bin" in
    mkdir_p svc_dir;
    let oc = open_out (Filename.concat svc_dir "dune") in
    output_string oc
      "(executable\n (name main)\n (libraries sol_svc obs-eio obs-loki-eio obs-prometheus-eio obs-tempo-eio))\n";
    close_out oc;
    let req = Sol_cli_workspace.scan ~dir:tmpdir in
    check_bool "tempo detected"      true  req.Sol_cli_workspace.tempo;
    check_bool "loki still detected" true  req.Sol_cli_workspace.loki;
    check_bool "kafka not falsely detected" false req.Sol_cli_workspace.kafka)

let test_scan_tempo_absent_by_default () =
  with_tmpdir (fun tmpdir ->
    let svc_dir = Filename.concat tmpdir "app/payments/charge_svc/bin" in
    mkdir_p svc_dir;
    let oc = open_out (Filename.concat svc_dir "dune") in
    output_string oc "(executable\n (name main)\n (libraries sol_svc))\n";
    close_out oc;
    let req = Sol_cli_workspace.scan ~dir:tmpdir in
    check_bool "no tempo dep -> not detected" false req.Sol_cli_workspace.tempo)

let () =
  Alcotest.run "workspace" [
    "find_root", [
      Alcotest.test_case "root itself"              `Quick test_finds_root_from_root;
      Alcotest.test_case "nested service dir"        `Quick test_finds_root_from_nested_service_dir;
      Alcotest.test_case "none outside a workspace"  `Quick test_none_outside_any_workspace;
      Alcotest.test_case "app must be a directory"   `Quick test_app_must_be_a_directory;
    ];
    "scan", [
      Alcotest.test_case "detects tempo dependency"      `Quick test_scan_detects_tempo;
      Alcotest.test_case "tempo absent by default"       `Quick test_scan_tempo_absent_by_default;
    ];
  ]
