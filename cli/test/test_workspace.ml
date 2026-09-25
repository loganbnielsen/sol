let check_bool = Alcotest.(check bool)
let check_string = Alcotest.(check string)

let mkdir_p path =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote path)))
;;

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let with_tmpdir f =
  let tmpdir = Filename.temp_file "sol-workspace-root-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () -> f tmpdir)
;;

let contains ~needle s =
  let n = String.length needle
  and l = String.length s in
  let rec loop i = i + n <= l && (String.sub s i n = needle || loop (i + 1)) in
  n = 0 || loop 0
;;

(* ── DEC-024 regression suite — pin the abstraction, not BUG-034 ───────────── *)

(* Row 1: a workspace with no dune marker at all. This is the layout that made
   BUG-034 fail: `find_root` must resolve it from its own sol.yml, never from an
   enclosing ecosystem marker. *)
let test_workspace_without_dune_marker () =
  with_tmpdir (fun tmpdir ->
    write_file (Filename.concat tmpdir "sol.yml") "";
    mkdir_p (Filename.concat tmpdir "app/payments/charge_svc");
    check_bool
      "sol.yml alone resolves the root"
      true
      (Sol_cli_workspace.find_root ~dir:tmpdir = Some tmpdir))
;;

(* Row 2: a Sol workspace nested inside a larger OCaml repo. The enclosing
   dune-project must not win. *)
let test_nested_in_ocaml_repo () =
  with_tmpdir (fun tmpdir ->
    let child = Filename.concat tmpdir "child" in
    mkdir_p child;
    write_file (Filename.concat tmpdir "dune-project") "(lang dune 3.0)\n";
    write_file (Filename.concat child "sol.yml") "";
    check_bool
      "the nearer sol.yml wins over the enclosing dune-project"
      true
      (Sol_cli_workspace.find_root ~dir:child = Some child))
;;

(* Row 3: same, but the enclosing repo is a Node project. This stops a future
   "also detect package.json roots" fix from creeping back in. *)
let test_nested_in_node_repo () =
  with_tmpdir (fun tmpdir ->
    let child = Filename.concat tmpdir "child" in
    mkdir_p child;
    write_file (Filename.concat tmpdir "package.json") "{\"name\":\"parent\"}\n";
    write_file (Filename.concat child "sol.yml") "";
    check_bool
      "the nearer sol.yml wins over the enclosing package.json"
      true
      (Sol_cli_workspace.find_root ~dir:child = Some child))
;;

(* Row 4: mixed-language workspace — OCaml and TS units underneath one Sol
   root. Language is a unit property (DEC-022 clause 7); it does not split the
   workspace boundary. *)
let test_mixed_ocaml_and_typescript_workspace () =
  with_tmpdir (fun tmpdir ->
    write_file (Filename.concat tmpdir "sol.yml") "";
    let ocaml_unit = Filename.concat tmpdir "app/payments/charge_svc" in
    let ts_unit = Filename.concat tmpdir "app/comms/notify_ts" in
    mkdir_p ocaml_unit;
    mkdir_p ts_unit;
    write_file (Filename.concat tmpdir "dune-project") "(lang dune 3.0)\n";
    write_file (Filename.concat ocaml_unit "dune") "(executable (name main))\n";
    write_file (Filename.concat ts_unit "package.json") "{\"name\":\"notify\"}\n";
    check_bool
      "OCaml unit resolves to the common Sol root"
      true
      (Sol_cli_workspace.find_root ~dir:ocaml_unit = Some tmpdir);
    check_bool
      "TS unit resolves to the same common Sol root"
      true
      (Sol_cli_workspace.find_root ~dir:ts_unit = Some tmpdir))
;;

(* Row 5: a descendant cwd resolves the workspace root, per DEC-024 clause 4
   (`cd app/payments/charge_svc && sol check` acts on the workspace). *)
let test_descendant_cwd_resolves_root () =
  with_tmpdir (fun tmpdir ->
    write_file (Filename.concat tmpdir "sol.yml") "";
    let nested = Filename.concat tmpdir "app/payments/charge_svc/lib" in
    mkdir_p nested;
    check_bool
      "a deep descendant walks up to the workspace root"
      true
      (Sol_cli_workspace.find_root ~dir:nested = Some tmpdir))
;;

(* Row 6: sibling workspaces resolve independently — one is not shadowed by the
   other, and neither consults the directory that contains them both. *)
let test_sibling_workspaces_resolve_independently () =
  with_tmpdir (fun tmpdir ->
    let a = Filename.concat tmpdir "product-a"
    and b = Filename.concat tmpdir "product-b" in
    mkdir_p a;
    mkdir_p b;
    write_file (Filename.concat a "sol.yml") "";
    write_file (Filename.concat b "sol.yml") "";
    check_bool
      "sibling a resolves to itself"
      true
      (Sol_cli_workspace.find_root ~dir:a = Some a);
    check_bool
      "sibling b resolves to itself"
      true
      (Sol_cli_workspace.find_root ~dir:b = Some b))
;;

(* Row 7: a nested boundary is a hard error that names both boundaries, not
   silent shadowing. Resolution stays cheap; the invariant is enforced by
   validation/discovery. *)
let test_nested_workspace_is_rejected () =
  with_tmpdir (fun tmpdir ->
    let outer = Filename.concat tmpdir "product"
    and inner = Filename.concat tmpdir "product/foo" in
    mkdir_p inner;
    write_file (Filename.concat outer "sol.yml") "";
    write_file (Filename.concat inner "sol.yml") "";
    (match Sol_cli_workspace.validate ~root:outer with
     | Ok () -> Alcotest.fail "expected the nested boundary to be rejected"
     | Error (Sol_cli_workspace.Nested_workspace { outer = o; inner = i }) ->
       check_string "outer boundary" outer o;
       check_string "inner boundary" inner i
     | Error Sol_cli_workspace.Not_in_workspace ->
       Alcotest.fail "expected Nested_workspace, got Not_in_workspace");
    match Sol_cli_workspace.resolve_validated ~dir:outer with
    | Ok _ -> Alcotest.fail "expected resolve_validated to reject nesting"
    | Error (Sol_cli_workspace.Nested_workspace _) -> ()
    | Error Sol_cli_workspace.Not_in_workspace ->
      Alcotest.fail "expected Nested_workspace, got Not_in_workspace")
;;

(* Fail-closed: no sol.yml anywhere means no workspace, and the message names
   the fix rather than inferring intent from an enclosing repo marker. *)
let test_absence_fails_closed_with_guidance () =
  with_tmpdir (fun tmpdir ->
    mkdir_p (Filename.concat tmpdir "app/payments/charge_svc");
    write_file (Filename.concat tmpdir "dune-project") "(lang dune 3.0)\n";
    check_bool
      "no sol.yml -> find_root returns None"
      true
      (Sol_cli_workspace.find_root ~dir:tmpdir = None);
    match Sol_cli_workspace.resolve ~dir:tmpdir with
    | Ok _ -> Alcotest.fail "expected absence to fail closed"
    | Error Sol_cli_workspace.Not_in_workspace ->
      let message =
        Sol_cli_workspace.workspace_error_to_string Sol_cli_workspace.Not_in_workspace
      in
      check_bool
        "the error names `sol new workspace`"
        true
        (contains ~needle:"sol new workspace" message)
    | Error (Sol_cli_workspace.Nested_workspace _) ->
      Alcotest.fail "expected Not_in_workspace")
;;

(* A directory merely named sol.yml is not a manifest. *)
let test_sol_yml_must_be_a_file () =
  with_tmpdir (fun tmpdir ->
    Unix.mkdir (Filename.concat tmpdir "sol.yml") 0o755;
    check_bool
      "a directory named sol.yml does not count"
      true
      (Sol_cli_workspace.find_root ~dir:tmpdir = None))
;;

(* ── infra scan (unchanged responsibility) ────────────────────────────────── *)

(* OBS-042: obs-tempo-eio in a dune file's libraries stanza should flip
   [tempo] the same way obs-loki-eio/obs-prometheus-eio already flip
   [loki]/[prometheus] -- this is what lets `sol local infra up` install Tempo only
   for workspaces that actually wired a -svc up to it. *)
let test_scan_detects_tempo () =
  with_tmpdir (fun tmpdir ->
    let svc_dir = Filename.concat tmpdir "app/payments/charge_svc/bin" in
    mkdir_p svc_dir;
    write_file
      (Filename.concat svc_dir "dune")
      "(executable\n\
      \ (name main)\n\
      \ (libraries sol_svc obs-eio obs-loki-eio obs-prometheus-eio obs-tempo-eio))\n";
    let req = Sol_cli_workspace.scan ~dir:tmpdir in
    check_bool "tempo detected" true req.Sol_cli_workspace.tempo;
    check_bool "loki still detected" true req.Sol_cli_workspace.loki;
    check_bool "kafka not falsely detected" false req.Sol_cli_workspace.kafka)
;;

let test_scan_tempo_absent_by_default () =
  with_tmpdir (fun tmpdir ->
    let svc_dir = Filename.concat tmpdir "app/payments/charge_svc/bin" in
    mkdir_p svc_dir;
    write_file
      (Filename.concat svc_dir "dune")
      "(executable\n (name main)\n (libraries sol_svc))\n";
    let req = Sol_cli_workspace.scan ~dir:tmpdir in
    check_bool "no tempo dep -> not detected" false req.Sol_cli_workspace.tempo)
;;

let () =
  Alcotest.run
    "workspace"
    [ ( "find_root (DEC-024)"
      , [ Alcotest.test_case
            "workspace with no dune marker"
            `Quick
            test_workspace_without_dune_marker
        ; Alcotest.test_case "nested in an OCaml repo" `Quick test_nested_in_ocaml_repo
        ; Alcotest.test_case "nested in a Node repo" `Quick test_nested_in_node_repo
        ; Alcotest.test_case
            "mixed OCaml + TS workspace"
            `Quick
            test_mixed_ocaml_and_typescript_workspace
        ; Alcotest.test_case "descendant cwd" `Quick test_descendant_cwd_resolves_root
        ; Alcotest.test_case
            "sibling workspaces"
            `Quick
            test_sibling_workspaces_resolve_independently
        ; Alcotest.test_case "sol.yml must be a file" `Quick test_sol_yml_must_be_a_file
        ] )
    ; ( "validation"
      , [ Alcotest.test_case
            "nested workspace is rejected"
            `Quick
            test_nested_workspace_is_rejected
        ; Alcotest.test_case
            "absence fails closed with guidance"
            `Quick
            test_absence_fails_closed_with_guidance
        ] )
    ; ( "scan"
      , [ Alcotest.test_case "detects tempo dependency" `Quick test_scan_detects_tempo
        ; Alcotest.test_case
            "tempo absent by default"
            `Quick
            test_scan_tempo_absent_by_default
        ] )
    ]
;;
