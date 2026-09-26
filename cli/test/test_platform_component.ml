(* Tests for Sol_cli_platform_component (ADR 0001 / CODE_LAYER-005, REFAC-102):
   reads <name>.common and <name>.<profile> from platform/shared/components.json
   and deep-merges them, profile winning over common. Fully hermetic -- builds a throwaway
   "Sol home" directory with fake marker files rather than depending on this
   repo's own layout, since a dune test's cwd is a build sandbox. *)

let check_str = Alcotest.(check string)

(* Sol_cli_platform_assets.is_checkout requires these two files to exist under a
   candidate SOL_HOME directory. *)
let sol_home_markers =
  [ "framework/ocaml/sol-svc/lib/dune"; "framework/ocaml/kafka-eio-service/lib/dune" ]
;;

(* REFAC-115: the readers return results; a test fails with the reason. *)
let ok = function
  | Ok x -> x
  | Error e -> Alcotest.fail e
;;

let assets () =
  match Sol_cli_platform_assets.resolve () with
  | Ok a -> a
  | Error e -> Alcotest.fail (Sol_cli_platform_assets.error_to_string e)
;;

let write_file path content =
  let dir = Filename.dirname path in
  let rec mkdir_p d =
    if d = "." || d = "/" || Sys.file_exists d
    then ()
    else (
      mkdir_p (Filename.dirname d);
      try Unix.mkdir d 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  mkdir_p dir;
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

(* Runs [f] with SOL_HOME pointed at a fresh throwaway directory whose
   components.json gives [component] the listed layers ("common", "local", ...),
   restoring the previous SOL_HOME (or unsetting it) afterward regardless of
   outcome. *)
let with_fake_sol_home ~component ~files f =
  let root = Filename.temp_file "sol-home-test-" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  Fun.protect
    ~finally:(fun () ->
      let _ = Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)) in
      ())
    (fun () ->
       List.iter
         (fun marker -> write_file (Filename.concat root marker) "")
         sol_home_markers;
       let layers =
         List.map (fun (layer, content) -> layer, Yojson.Safe.from_string content) files
       in
       write_file
         (Filename.concat root "platform/shared/components.json")
         (Yojson.Safe.to_string (`Assoc [ component, `Assoc layers ]));
       let prev = Sys.getenv_opt "SOL_HOME" in
       Unix.putenv "SOL_HOME" root;
       Fun.protect
         ~finally:(fun () ->
           match prev with
           | Some v -> Unix.putenv "SOL_HOME" v
           | None ->
             (try Unix.putenv "SOL_HOME" "" with
              | _ -> ()))
         f)
;;

let test_profile_overrides_common () =
  with_fake_sol_home
    ~component:"widget"
    ~files:
      [ "common", {|{"a": 1, "nested": {"x": 1, "y": 2}}|}
      ; "local", {|{"a": 2, "nested": {"y": 20, "z": 30}}|}
      ]
    (fun () ->
       let merged =
         ok
         @@ Sol_cli_platform_component.merged_values_yaml
              ~assets:(assets ())
              ~component:"widget"
              ~profile:"local"
       in
       let json = Yojson.Safe.from_string merged in
       (* profile's scalar wins outright *)
       check_str "a" "2" (Yojson.Safe.to_string (Yojson.Safe.Util.member "a" json));
       (* nested object merges: base's untouched key survives, conflicting
         key takes profile's value, profile's new key is added *)
       let nested = Yojson.Safe.Util.member "nested" json in
       check_str
         "nested.x"
         "1"
         (Yojson.Safe.to_string (Yojson.Safe.Util.member "x" nested));
       check_str
         "nested.y"
         "20"
         (Yojson.Safe.to_string (Yojson.Safe.Util.member "y" nested));
       check_str
         "nested.z"
         "30"
         (Yojson.Safe.to_string (Yojson.Safe.Util.member "z" nested)))
;;

let test_missing_profile_layer_is_empty_object () =
  with_fake_sol_home
    ~component:"widget"
    ~files:[ "common", {|{"a": 1}|} ]
    (fun () ->
       let merged =
         ok
         @@ Sol_cli_platform_component.merged_values_yaml
              ~assets:(assets ())
              ~component:"widget"
              ~profile:"durable"
       in
       let json = Yojson.Safe.from_string merged in
       check_str "a" "1" (Yojson.Safe.to_string (Yojson.Safe.Util.member "a" json)))
;;

let test_missing_common_layer_is_empty_object () =
  with_fake_sol_home
    ~component:"widget"
    ~files:[ "local", {|{"a": 1}|} ]
    (fun () ->
       let merged =
         ok
         @@ Sol_cli_platform_component.merged_values_yaml
              ~assets:(assets ())
              ~component:"widget"
              ~profile:"local"
       in
       let json = Yojson.Safe.from_string merged in
       check_str "a" "1" (Yojson.Safe.to_string (Yojson.Safe.Util.member "a" json)))
;;

let test_unnamed_component_is_empty_object () =
  with_fake_sol_home
    ~component:"widget"
    ~files:[ "common", {|{"a": 1}|} ]
    (fun () ->
       check_str
         "empty"
         "{}"
         (Yojson.Safe.to_string
            (Yojson.Safe.from_string
               (ok
                @@ Sol_cli_platform_component.merged_values_yaml
                     ~assets:(assets ())
                     ~component:"gadget"
                     ~profile:"local"))))
;;

let suite =
  [ ( "platform_component"
    , [ Alcotest.test_case
          "profile overrides common, deep-merged"
          `Quick
          test_profile_overrides_common
      ; Alcotest.test_case
          "missing profile layer treated as empty"
          `Quick
          test_missing_profile_layer_is_empty_object
      ; Alcotest.test_case
          "missing common layer treated as empty"
          `Quick
          test_missing_common_layer_is_empty_object
      ; Alcotest.test_case
          "a component the file does not name is empty"
          `Quick
          test_unnamed_component_is_empty_object
      ] )
  ]
;;

let () = Alcotest.run "platform_component" suite
