(* REFAC-114 / DEC-049: Sol_cli_platform_assets resolves Sol's asset root, in the
   order SOL_HOME > (installed bundle, FEAT-101) > source-checkout discovery. *)

module A = Sol_cli_platform_assets

let mkdir_p path =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote path)))
;;

let touch path =
  mkdir_p (Filename.dirname path);
  close_out (open_out path)
;;

let with_tmpdir f =
  let dir = Filename.temp_file "sol-assets-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f (Unix.realpath dir))
;;

(* Unix.putenv cannot unset; the resolver treats "" as unset. *)
let with_sol_home value f =
  let saved = Sys.getenv_opt "SOL_HOME" in
  Unix.putenv "SOL_HOME" value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv "SOL_HOME" (Option.value saved ~default:""))
    f
;;

let fake_checkout dir =
  touch (Filename.concat dir "framework/ocaml/sol-svc/lib/dune");
  touch (Filename.concat dir "framework/ocaml/kafka-eio-service/lib/dune")
;;

let resolved_dir () = Result.map A.dir (A.resolve ())

(* The test binary runs from inside this checkout, so discovery alone would find
   it. A valid SOL_HOME elsewhere must win over that. *)
let test_sol_home_wins_over_discovery () =
  with_tmpdir (fun dir ->
    fake_checkout dir;
    with_sol_home dir (fun () ->
      match resolved_dir () with
      | Ok got -> Alcotest.(check string) "SOL_HOME is the root" dir got
      | Error e -> Alcotest.fail (A.error_to_string e)))
;;

(* An explicit root that is wrong is an error. It must not fall through to the
   checkout discovery would find. *)
let test_invalid_sol_home_is_an_error () =
  with_tmpdir (fun dir ->
    with_sol_home dir (fun () ->
      match A.resolve () with
      | Ok t -> Alcotest.fail ("fell through to " ^ A.dir t)
      | Error (A.Invalid_sol_home got) ->
        Alcotest.(check string) "names the bad value" dir got;
        let msg = A.error_to_string (A.Invalid_sol_home got) in
        Alcotest.(check bool)
          ("says how to fix it: " ^ msg)
          true
          (Sol_cli_string.contains ~needle:"export SOL_HOME" msg)
      | Error e -> Alcotest.fail ("expected Invalid_sol_home: " ^ A.error_to_string e)))
;;

(* Unset: discovery walks up from the running binary to this checkout. *)
let test_unset_discovers_the_checkout () =
  with_sol_home "" (fun () ->
    match A.resolve () with
    | Error e -> Alcotest.fail (A.error_to_string e)
    | Ok t ->
      Alcotest.(check bool) "a checkout" true (A.is_checkout (A.dir t));
      Alcotest.(check bool)
        "its components.json exists"
        true
        (Sys.file_exists (A.components_json t)))
;;

(* A build tree mirrors the sentinels but is never a root. *)
let test_build_tree_is_not_a_checkout () =
  with_tmpdir (fun dir ->
    let mirrored = Filename.concat dir "_build/default" in
    fake_checkout mirrored;
    Alcotest.(check bool) "rejected" false (A.is_checkout mirrored))
;;

let test_asset_paths () =
  with_tmpdir (fun dir ->
    fake_checkout dir;
    with_sol_home dir (fun () ->
      let t = A.resolve_or_exit () in
      Alcotest.(check string)
        "cluster root"
        (dir ^ "/platform/cloud/gcp/cluster")
        (A.cloud_root t Sol_cli_provider.Gcp A.Cluster);
      Alcotest.(check string)
        "components"
        (dir ^ "/platform/shared/components.json")
        (A.components_json t);
      Alcotest.(check string)
        "dashboard"
        (dir ^ "/platform/shared/observability/dashboards/x.json")
        (A.dashboard t "x.json");
      match A.migration_runner t with
      | Ok (A.Build_from_source { context }) ->
        Alcotest.(check string) "a checkout builds its runner from itself" dir context
      | Ok (A.Published r) -> Alcotest.fail ("a checkout used a published runner " ^ r)
      | Error msg -> Alcotest.fail msg))
;;

(* ── FEAT-101: the installed form and DEC-049's full order ─────────────────── *)

let write path text =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  output_string oc text;
  close_out oc
;;

(* <prefix>/bin and <prefix>/share/sol/<version>/ as a release archive lays them out. *)
let fake_install prefix ~version =
  mkdir_p (Filename.concat prefix "bin");
  let bundle = Filename.concat prefix ("share/sol/" ^ version) in
  write (Filename.concat bundle "VERSION") (version ^ "\n");
  write (Filename.concat bundle "platform/shared/components.json") "{}\n";
  bundle
;;

let digest = "ghcr.io/o/sol-migration-runner@sha256:" ^ String.make 64 'a'

let form_name = function
  | Ok t ->
    (match A.form t with
     | A.Checkout -> "checkout:" ^ A.dir t
     | A.Installed { version } -> "installed:" ^ version ^ ":" ^ A.dir t)
  | Error (A.Invalid_sol_home _) -> "invalid-sol-home"
  | Error (A.Bundle_version_mismatch _) -> "bundle-version-mismatch"
  | Error (A.Missing_bundle _) -> "missing-bundle"
  | Error A.Not_found -> "not-found"
;;

let check_form name want got = Alcotest.(check string) name want (form_name got)

(* The install sits inside a checkout, so every lower rung is also available and
   each case shows which one wins. *)
let with_layout f =
  with_tmpdir (fun root ->
    fake_checkout root;
    let prefix = Filename.concat root "prefix" in
    let bundle = fake_install prefix ~version:"v1.2.3" in
    f ~root ~bin:(Filename.concat prefix "bin") ~bundle)
;;

let test_sol_home_beats_installed () =
  with_layout (fun ~root ~bin ~bundle:_ ->
    with_tmpdir (fun other ->
      fake_checkout other;
      check_form
        "SOL_HOME checkout over the installed bundle"
        ("checkout:" ^ other)
        (A.resolve_from
           ~sol_home:(Some other)
           ~exe_dir:bin
           ~release_version:(Some "v1.2.3")));
    ignore root)
;;

let test_installed_beats_discovery () =
  with_layout (fun ~root:_ ~bin ~bundle ->
    check_form
      "a release binary uses its bundle, not the checkout around it"
      ("installed:v1.2.3:" ^ bundle)
      (A.resolve_from ~sol_home:None ~exe_dir:bin ~release_version:(Some "v1.2.3")))
;;

let test_release_never_discovers_a_checkout () =
  with_layout (fun ~root:_ ~bin ~bundle:_ ->
    check_form
      "a release whose bundle is absent refuses; it does not reach back"
      "missing-bundle"
      (A.resolve_from ~sol_home:None ~exe_dir:bin ~release_version:(Some "v9.9.9")))
;;

let test_development_build_discovers () =
  with_layout (fun ~root ~bin ~bundle:_ ->
    check_form
      "a development build uses the checkout, never a bundle"
      ("checkout:" ^ root)
      (A.resolve_from ~sol_home:None ~exe_dir:bin ~release_version:None))
;;

let test_sol_home_bundle_must_match () =
  with_layout (fun ~root:_ ~bin ~bundle ->
    check_form
      "SOL_HOME naming this release's bundle"
      ("installed:v1.2.3:" ^ bundle)
      (A.resolve_from
         ~sol_home:(Some bundle)
         ~exe_dir:bin
         ~release_version:(Some "v1.2.3"));
    check_form
      "SOL_HOME naming another release's bundle"
      "bundle-version-mismatch"
      (A.resolve_from
         ~sol_home:(Some bundle)
         ~exe_dir:bin
         ~release_version:(Some "v2.0.0"));
    check_form
      "a development build pointed at a bundle"
      "bundle-version-mismatch"
      (A.resolve_from ~sol_home:(Some bundle) ~exe_dir:bin ~release_version:None))
;;

let test_invalid_sol_home_never_falls_through () =
  with_layout (fun ~root:_ ~bin ~bundle:_ ->
    with_tmpdir (fun empty ->
      check_form
        "invalid SOL_HOME with a valid bundle and checkout both available"
        "invalid-sol-home"
        (A.resolve_from
           ~sol_home:(Some empty)
           ~exe_dir:bin
           ~release_version:(Some "v1.2.3"))))
;;

let test_empty_sol_home_is_unset () =
  with_layout (fun ~root:_ ~bin ~bundle ->
    check_form
      "SOL_HOME=\"\" is unset"
      ("installed:v1.2.3:" ^ bundle)
      (A.resolve_from ~sol_home:(Some "") ~exe_dir:bin ~release_version:(Some "v1.2.3")))
;;

let installed_runner ~file =
  with_layout (fun ~root:_ ~bin ~bundle ->
    Option.iter (write (Filename.concat bundle "migration-runner-image")) file;
    match A.resolve_from ~sol_home:None ~exe_dir:bin ~release_version:(Some "v1.2.3") with
    | Error e -> Error (A.error_to_string e)
    | Ok t -> A.migration_runner t)
;;

let test_installed_runner_is_published_by_digest () =
  (match installed_runner ~file:(Some (digest ^ "\n")) with
   | Ok (A.Published r) -> Alcotest.(check string) "the bundle's digest" digest r
   | Ok (A.Build_from_source _) -> Alcotest.fail "an installed release built its runner"
   | Error msg -> Alcotest.fail msg);
  (match installed_runner ~file:(Some "ghcr.io/o/sol-migration-runner:latest\n") with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "a floating tag was accepted as the runner");
  (match installed_runner ~file:None with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "a bundle without a runner reference was accepted");
  match installed_runner ~file:(Some "") with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "an empty runner reference was accepted"
;;

(* An empty VERSION is not a bundle: an error, not an exception. *)
let test_empty_version_is_not_a_bundle () =
  with_layout (fun ~root:_ ~bin ~bundle ->
    write (Filename.concat bundle "VERSION") "";
    check_form
      "empty VERSION"
      "missing-bundle"
      (A.resolve_from ~sol_home:None ~exe_dir:bin ~release_version:(Some "v1.2.3"));
    check_form
      "empty VERSION via SOL_HOME"
      "invalid-sol-home"
      (A.resolve_from
         ~sol_home:(Some bundle)
         ~exe_dir:bin
         ~release_version:(Some "v1.2.3")))
;;

let () =
  Alcotest.run
    "platform_assets"
    [ ( "resolution"
      , [ Alcotest.test_case
            "SOL_HOME wins over discovery"
            `Quick
            test_sol_home_wins_over_discovery
        ; Alcotest.test_case
            "invalid SOL_HOME is an error"
            `Quick
            test_invalid_sol_home_is_an_error
        ; Alcotest.test_case
            "unset discovers the checkout"
            `Quick
            test_unset_discovers_the_checkout
        ; Alcotest.test_case
            "a build tree is not a checkout"
            `Quick
            test_build_tree_is_not_a_checkout
        ; Alcotest.test_case "asset paths" `Quick test_asset_paths
        ] )
    ; ( "precedence"
      , [ Alcotest.test_case
            "SOL_HOME beats installed"
            `Quick
            test_sol_home_beats_installed
        ; Alcotest.test_case
            "installed beats discovery"
            `Quick
            test_installed_beats_discovery
        ; Alcotest.test_case
            "a release never discovers a checkout"
            `Quick
            test_release_never_discovers_a_checkout
        ; Alcotest.test_case
            "a development build discovers"
            `Quick
            test_development_build_discovers
        ; Alcotest.test_case
            "a SOL_HOME bundle must match"
            `Quick
            test_sol_home_bundle_must_match
        ; Alcotest.test_case
            "invalid SOL_HOME never falls through"
            `Quick
            test_invalid_sol_home_never_falls_through
        ; Alcotest.test_case "empty SOL_HOME is unset" `Quick test_empty_sol_home_is_unset
        ; Alcotest.test_case
            "installed runner is published by digest"
            `Quick
            test_installed_runner_is_published_by_digest
        ; Alcotest.test_case
            "empty VERSION is not a bundle"
            `Quick
            test_empty_version_is_not_a_bundle
        ] )
    ]
;;
