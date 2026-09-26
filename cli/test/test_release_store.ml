(* INFRA-055 / DEC-037: the release record must be written with the verbs the
   deploy identity actually holds.

   [kubectl apply] degrades to a *patch* when the object exists, and the
   boundary-lease grant withholds `patch` on ConfigMaps in `default` -- so the
   release pointer silently stayed on an older release. The writer must therefore
   use only `create` (absent), `replace` (present, different) or nothing at all
   (present, identical), and must never treat a *permission* failure as absence.

   The fake kubectl behaves like the restricted cluster: it answers `get` from a
   state file, and records every verb it was asked for, so the assertions are
   about what Sol actually invoked rather than about what the code appears to
   say. *)

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

let read_file path =
  try
    let ic = open_in path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    s
  with
  | _ -> ""
;;

let fake_kubectl ~log ~mode_file ~json_file =
  Printf.sprintf
    {|#!/bin/sh
verb=""
for a in "$@"; do
  case "$a" in
    apply|create|delete|get|patch|replace) verb="$a"; break ;;
  esac
done
file=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-f" ]; then file="$a"; fi
  prev="$a"
done
rv=no
if [ -n "$file" ] && grep -q '"resourceVersion"' "$file" 2>/dev/null; then rv=yes; fi
printf '%%s rv=%%s\n' "$verb" "$rv" >> %s
mode=$(cat %s 2>/dev/null)
if [ "$verb" = "get" ]; then
  if [ "$mode" = "missing" ]; then
    echo 'Error from server (NotFound): configmaps "sol-release-current-pluto" not found' >&2
    exit 1
  fi
  if [ "$mode" = "forbidden" ]; then
    echo 'Error from server (Forbidden): configmaps "sol-release-current-pluto" is forbidden:' \
         'cannot get resource "configmaps" in API group "" in the namespace "default"' >&2
    exit 1
  fi
  cat %s
fi
exit 0
|}
    log
    mode_file
    json_file
;;

let with_fake_kubectl ~mode ~live_json f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let mode_file = Filename.concat dir "mode" in
  let json_file = Filename.concat dir "live.json" in
  write_file mode_file mode;
  write_file json_file live_json;
  let bin = Filename.concat dir "kubectl" in
  write_file bin (fake_kubectl ~log ~mode_file ~json_file);
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      (try Sys.remove mode_file with
       | _ -> ());
      (try Sys.remove json_file with
       | _ -> ());
      (try Sys.remove log with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () -> f log)
;;

let release ~release_id =
  { Sol_cli_release.release_id
  ; workspace = "pluto"
  ; environment = None
  ; workloads = []
  ; migrations = []
  ; apply_mode = Sol_cli_release.Direct
  }
;;

let ctx = Sol_cli_kube_destination.local_context

let verbs log =
  let lines = String.split_on_char '\n' (read_file log) in
  List.filter (fun l -> not (String.equal (String.trim l) "")) lines
;;

let contains_needle ~needle haystack =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with
  | Not_found -> false
;;

(* Absent object -> create, with no resourceVersion, and never apply/patch. *)
let test_absent_object_is_created () =
  with_fake_kubectl ~mode:"missing" ~live_json:"" (fun log ->
    (match
       Sol_cli_release_store.move_pointer ~ctx (release ~release_id:"r-aaaabbbbccccdddd")
     with
     | Ok () -> ()
     | Error e -> Alcotest.fail ("expected success, got: " ^ e));
    let calls = verbs log in
    Alcotest.(check (list string))
      "one get, then one create, both without a resourceVersion"
      [ "get rv=no"; "create rv=no" ]
      calls;
    let all = String.concat "\n" calls in
    Alcotest.(check bool) "never applied" false (contains_needle ~needle:"apply" all);
    Alcotest.(check bool) "never patched" false (contains_needle ~needle:"patch" all))
;;

(* Identical content -> no write at all. This is the common case for the
   content-addressed record, and it is why a repeated deploy succeeds without
   needing any write verb. *)
let test_identical_object_is_left_alone () =
  let live_json =
    {|{"kind":"ConfigMap","metadata":{"name":"sol-release-current-pluto","resourceVersion":"42"},"data":{"release_id":"r-aaaabbbbccccdddd"}}|}
  in
  with_fake_kubectl ~mode:"present" ~live_json (fun log ->
    (match
       Sol_cli_release_store.move_pointer ~ctx (release ~release_id:"r-aaaabbbbccccdddd")
     with
     | Ok () -> ()
     | Error e -> Alcotest.fail ("expected success, got: " ^ e));
    Alcotest.(check (list string)) "only a get" [ "get rv=no" ] (verbs log))
;;

(* Different content -> replace, carrying the live resourceVersion so a
   concurrent writer conflicts rather than being silently overwritten. *)
let test_changed_object_is_replaced_with_a_precondition () =
  let live_json =
    {|{"kind":"ConfigMap","metadata":{"name":"sol-release-current-pluto","resourceVersion":"42"},"data":{"release_id":"r-1111222233334444"}}|}
  in
  with_fake_kubectl ~mode:"present" ~live_json (fun log ->
    (match
       Sol_cli_release_store.move_pointer ~ctx (release ~release_id:"r-aaaabbbbccccdddd")
     with
     | Ok () -> ()
     | Error e -> Alcotest.fail ("expected success, got: " ^ e));
    let calls = verbs log in
    Alcotest.(check (list string))
      "one get, then a replace carrying the live resourceVersion"
      [ "get rv=no"; "replace rv=yes" ]
      calls;
    let all = String.concat "\n" calls in
    Alcotest.(check bool) "never applied" false (contains_needle ~needle:"apply" all);
    Alcotest.(check bool) "never patched" false (contains_needle ~needle:"patch" all))
;;

(* A permission failure is not absence: it must fail, and must not be answered
   with a create that would then fail differently. *)
let test_permission_failure_is_not_absence () =
  with_fake_kubectl ~mode:"forbidden" ~live_json:"" (fun log ->
    (match
       Sol_cli_release_store.move_pointer ~ctx (release ~release_id:"r-aaaabbbbccccdddd")
     with
     | Ok () -> Alcotest.fail "a forbidden read must not be reported as success"
     | Error msg ->
       Alcotest.(check bool)
         "the error names the read"
         true
         (contains_needle ~needle:"kubectl get configmap" msg));
    let calls = verbs log in
    Alcotest.(check (list string)) "a get and nothing else" [ "get rv=no" ] calls;
    Alcotest.(check bool)
      "no create was attempted"
      false
      (contains_needle ~needle:"create" (String.concat "\n" calls)))
;;

(* REFAC-116: [Sol_cli_kubectl.get] reports a failed kubectl as [Error Non_zero],
   so the NotFound branch has to match there. It used to match
   [Ok r when exit_code <> 0], which that function never returns, so a missing
   release read as a generic kubectl failure. *)
let test_missing_release_is_not_found () =
  with_fake_kubectl ~mode:"missing" ~live_json:"" (fun _log ->
    match
      Sol_cli_release_store.get ~ctx ~workspace:"pluto" ~release_id:"r-aaaabbbbccccdddd"
    with
    | Ok _ -> Alcotest.fail "a missing release was found"
    | Error e ->
      Alcotest.(check bool)
        ("names it not found: " ^ e)
        true
        (contains_needle ~needle:"release r-aaaabbbbccccdddd not found" e))
;;

(* ...while a failure that is not absence stays a failure. *)
let test_forbidden_release_read_is_not_absence () =
  with_fake_kubectl ~mode:"forbidden" ~live_json:"" (fun _log ->
    match
      Sol_cli_release_store.get ~ctx ~workspace:"pluto" ~release_id:"r-aaaabbbbccccdddd"
    with
    | Ok _ -> Alcotest.fail "a forbidden read succeeded"
    | Error e ->
      Alcotest.(check bool)
        ("not reported as absence: " ^ e)
        false
        (contains_needle ~needle:"not found" e);
      Alcotest.(check bool)
        ("carries kubectl's reason: " ^ e)
        true
        (contains_needle ~needle:"forbidden" e))
;;

let () =
  Alcotest.run
    "release_store"
    [ ( "release record write (INFRA-055)"
      , [ Alcotest.test_case
            "an absent object is created"
            `Quick
            test_absent_object_is_created
        ; Alcotest.test_case
            "an identical object is left alone"
            `Quick
            test_identical_object_is_left_alone
        ; Alcotest.test_case
            "a changed object is replaced with a precondition"
            `Quick
            test_changed_object_is_replaced_with_a_precondition
        ; Alcotest.test_case
            "a permission failure is not absence"
            `Quick
            test_permission_failure_is_not_absence
        ] )
    ; ( "release record read (REFAC-116)"
      , [ Alcotest.test_case
            "a missing release is not found"
            `Quick
            test_missing_release_is_not_found
        ; Alcotest.test_case
            "a forbidden read is not absence"
            `Quick
            test_forbidden_release_read_is_not_absence
        ] )
    ]
;;
