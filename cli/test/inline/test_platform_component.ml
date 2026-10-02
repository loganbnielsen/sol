let check_str msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let sol_home_markers =
  [ "framework/ocaml/sol-svc/lib/dune"; "framework/ocaml/kafka-eio-service/lib/dune" ]
;;

let ok = function
  | Ok x -> x
  | Error e -> Windtrap.fail e
;;

let assets () =
  match Sol_cli_platform_assets.resolve () with
  | Ok a -> a
  | Error e -> Windtrap.fail (Sol_cli_platform_assets.error_to_string e)
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

let with_fake_sol_home ~component ~files f =
  let root = Filename.temp_file "sol-home-test-" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  Fun.protect
    ~finally:(fun () ->
      let _ = Sol_cli_fs.remove_tree root in
      ())
    (fun () ->
       sol_home_markers
       |> List.iter (fun marker -> write_file (Filename.concat root marker) "");
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
       check_str "a" "2" (Yojson.Safe.to_string (Yojson.Safe.Util.member "a" json));
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

let%test "platform_component: profile overrides common, deep-merged" =
  test_profile_overrides_common ()
;;

let%test "platform_component: missing profile layer treated as empty" =
  test_missing_profile_layer_is_empty_object ()
;;

let%test "platform_component: missing common layer treated as empty" =
  test_missing_common_layer_is_empty_object ()
;;

let%test "platform_component: a component the file does not name is empty" =
  test_unnamed_component_is_empty_object ()
;;
