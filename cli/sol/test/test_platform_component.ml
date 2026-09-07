(* Tests for Sol_cli_platform_component (ADR 0001 / CODE_LAYER-005): reads
   platform/components/<name>/values-{common,<profile>}.json and deep-merges
   them, profile winning over common. Fully hermetic -- builds a throwaway
   "Sol home" directory with fake marker files rather than depending on this
   repo's own layout, since a dune test's cwd is a build sandbox. *)

let check_str = Alcotest.(check string)

(* Sol_cli_cmd_new.is_sol_home requires these two files to exist under a
   candidate SOL_HOME directory. *)
let sol_home_markers = [
  "framework/sol-svc/lib/dune";
  "integrations/kafka/kafka-eio-service/lib/dune";
]

let write_file path content =
  let dir = Filename.dirname path in
  let rec mkdir_p d =
    if d = "." || d = "/" || Sys.file_exists d then ()
    else (mkdir_p (Filename.dirname d); (try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()))
  in
  mkdir_p dir;
  let oc = open_out path in
  output_string oc content;
  close_out oc

(* Runs [f] with SOL_HOME pointed at a fresh throwaway directory containing
   the given [component]'s values files, restoring the previous SOL_HOME
   (or unsetting it) afterward regardless of outcome. *)
let with_fake_sol_home ~component ~files f =
  let root = Filename.temp_file "sol-home-test-" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  Fun.protect
    ~finally:(fun () ->
      let _ = Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)) in
      ())
    (fun () ->
      List.iter (fun marker -> write_file (Filename.concat root marker) "") sol_home_markers;
      List.iter (fun (name, content) ->
        write_file (Filename.concat root (Printf.sprintf "platform/components/%s/%s" component name)) content
      ) files;
      let prev = Sys.getenv_opt "SOL_HOME" in
      Unix.putenv "SOL_HOME" root;
      Fun.protect
        ~finally:(fun () ->
          match prev with
          | Some v -> Unix.putenv "SOL_HOME" v
          | None -> (try Unix.putenv "SOL_HOME" "" with _ -> ()))
        f)

let test_profile_overrides_common () =
  with_fake_sol_home ~component:"widget"
    ~files:[
      "values-common.json", {|{"a": 1, "nested": {"x": 1, "y": 2}}|};
      "values-local.json",  {|{"a": 2, "nested": {"y": 20, "z": 30}}|};
    ]
    (fun () ->
      let merged = Sol_cli_platform_component.merged_values_yaml
        ~component:"widget" ~profile:"local" in
      let json = Yojson.Safe.from_string merged in
      (* profile's scalar wins outright *)
      check_str "a" "2" (Yojson.Safe.to_string (Yojson.Safe.Util.member "a" json));
      (* nested object merges: base's untouched key survives, conflicting
         key takes profile's value, profile's new key is added *)
      let nested = Yojson.Safe.Util.member "nested" json in
      check_str "nested.x" "1" (Yojson.Safe.to_string (Yojson.Safe.Util.member "x" nested));
      check_str "nested.y" "20" (Yojson.Safe.to_string (Yojson.Safe.Util.member "y" nested));
      check_str "nested.z" "30" (Yojson.Safe.to_string (Yojson.Safe.Util.member "z" nested)))

let test_missing_profile_file_is_empty_object () =
  with_fake_sol_home ~component:"widget"
    ~files:["values-common.json", {|{"a": 1}|}]
    (fun () ->
      let merged = Sol_cli_platform_component.merged_values_yaml
        ~component:"widget" ~profile:"durable" in
      let json = Yojson.Safe.from_string merged in
      check_str "a" "1" (Yojson.Safe.to_string (Yojson.Safe.Util.member "a" json)))

let test_missing_common_file_is_empty_object () =
  with_fake_sol_home ~component:"widget"
    ~files:["values-local.json", {|{"a": 1}|}]
    (fun () ->
      let merged = Sol_cli_platform_component.merged_values_yaml
        ~component:"widget" ~profile:"local" in
      let json = Yojson.Safe.from_string merged in
      check_str "a" "1" (Yojson.Safe.to_string (Yojson.Safe.Util.member "a" json)))

let suite = [
  "platform_component", [
    Alcotest.test_case "profile overrides common, deep-merged" `Quick test_profile_overrides_common;
    Alcotest.test_case "missing profile file treated as empty" `Quick test_missing_profile_file_is_empty_object;
    Alcotest.test_case "missing common file treated as empty" `Quick test_missing_common_file_is_empty_object;
  ]
]

let () = Alcotest.run "platform_component" suite
