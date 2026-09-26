(* REFAC-114 / DEC-049: Sol_cli_platform_assets resolves Sol's asset root, in the
   order SOL_HOME > (installed bundle, FEAT-101) > source-checkout discovery. *)

module A = Sol_cli_platform_assets

let contains ~sub s =
  let n = String.length sub in
  let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
  go 0
;;

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
          (contains ~sub:"export SOL_HOME" msg)
      | Error A.Not_found -> Alcotest.fail "reported Not_found for an explicit SOL_HOME"))
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
      | A.Build_from_source { context } ->
        Alcotest.(check string) "a checkout builds its runner from itself" dir context))
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
    ]
;;
