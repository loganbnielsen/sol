(* REFAC-088: the resolution seam between `sol local <command>` and
   `sol <command> --target <t>`.

   The two surfaces are free to differ in how they present a workload operation;
   what must agree is the core's inputs -- destination and scope. This file
   pins the destination half: one policy, total over the two spellings, with no
   third ambient case. *)

let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

let context_name (ctx : Sol_cli_kube_destination.context) =
  ctx.Sol_cli_kube_destination.destination.context
;;

let write path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/"
  then ()
  else if Sys.file_exists dir
  then ()
  else (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)
;;

let with_temp_dir f =
  let dir = Filename.temp_file "sol-destination-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir dir;
       f ())
;;

let write_base () = write "sol.yml" "project: pluto\n"

(* The target overlay names the cluster it deploys to; `kube_context` is what
   makes it reachable (FEAT-063). *)
let write_target kube_context =
  mkdir_p "sol/prod/aws";
  write
    "sol/prod/aws/us-east-1.yml"
    (Printf.sprintf
       "target:\n  cluster_name: prod-cluster\n%s"
       (match kube_context with
        | Some c -> Printf.sprintf "  kube_context: %s\n" c
        | None -> ""))
;;

let ok_or_fail = function
  | Ok value -> value
  | Error message -> Alcotest.fail ("unexpected error: " ^ message)
;;

let error_or_fail = function
  | Error message -> message
  | Ok _ -> Alcotest.fail "expected the resolution to fail closed"
;;

let contains ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec loop i =
    if i + n > h
    then false
    else if String.sub haystack i n = needle
    then true
    else loop (i + 1)
  in
  loop 0
;;

(* The local entry point names Sol's own cluster literally -- it does not load a
   target, and it does not consult anything ambient. *)
let test_local_entry_point_is_the_literal_local_cluster () =
  let ctx =
    ok_or_fail (Sol_cli_destination.resolve ~command:"status" ~local:true ~target:None)
  in
  check_string "local destination" "k3d-sol-local" (context_name ctx)
;;

(* A local invocation is local by construction: if a target were somehow also
   present it must not silently become the destination. *)
let test_local_wins_even_if_a_target_is_supplied () =
  let ctx =
    ok_or_fail
      (Sol_cli_destination.resolve
         ~command:"status"
         ~local:true
         ~target:(Some "prod/aws/us-east-1"))
  in
  check_string "local destination" "k3d-sol-local" (context_name ctx)
;;

(* The fail-closed case, and the load-bearing part of the message: it names the
   local spelling of *this* command, so the refusal states the fix. *)
let test_top_level_without_target_fails_closed_naming_local_form () =
  let message =
    error_or_fail
      (Sol_cli_destination.resolve ~command:"status" ~local:false ~target:None)
  in
  check_bool "names --target" true (contains ~needle:"--target" message);
  check_bool "names the local spelling" true (contains ~needle:"sol local status" message)
;;

let test_local_form_message_is_command_specific () =
  let message =
    error_or_fail
      (Sol_cli_destination.resolve ~command:"rollback" ~local:false ~target:None)
  in
  check_bool
    "names rollback's local spelling, not status's"
    true
    (contains ~needle:"sol local rollback" message)
;;

(* The named entry point takes its destination from the target's configuration. *)
let test_top_level_target_supplies_the_destination () =
  with_temp_dir (fun () ->
    write_base ();
    write_target (Some "prod-cluster");
    let ctx =
      ok_or_fail
        (Sol_cli_destination.resolve
           ~command:"status"
           ~local:false
           ~target:(Some "prod/aws/us-east-1"))
    in
    check_string "target's destination" "prod-cluster" (context_name ctx))
;;

let test_target_without_context_fails_closed () =
  with_temp_dir (fun () ->
    write_base ();
    write_target None;
    let message =
      error_or_fail
        (Sol_cli_destination.resolve
           ~command:"status"
           ~local:false
           ~target:(Some "prod/aws/us-east-1"))
    in
    check_bool
      "the message says what to add"
      true
      (contains ~needle:"kube_context" message))
;;

(* The reserved execution mode is not reachable through the named entry point:
   a target pointed at Sol's own cluster is refused and redirected. *)
let test_reserved_local_target_points_at_local_form () =
  with_temp_dir (fun () ->
    write_base ();
    write_target (Some "k3d-sol-local");
    let message =
      error_or_fail
        (Sol_cli_destination.resolve
           ~command:"status"
           ~local:false
           ~target:(Some "prod/aws/us-east-1"))
    in
    check_bool
      "redirects to the local spelling"
      true
      (contains ~needle:"sol local <command>" message))
;;

(* Same inputs, same destination: resolution is a function of how the command
   was spelled and nothing else. *)
let test_resolution_is_deterministic () =
  let resolve () =
    Sol_cli_destination.resolve ~command:"logs" ~local:false ~target:None
  in
  match resolve (), resolve () with
  | Error a, Error b -> check_string "same error twice" a b
  | Ok a, Ok b -> check_string "same context twice" (context_name a) (context_name b)
  | _ -> Alcotest.fail "resolution disagreed with itself"
;;

let () =
  Alcotest.run
    "destination"
    [ ( "seam"
      , [ Alcotest.test_case
            "local entry point is the literal local cluster"
            `Quick
            test_local_entry_point_is_the_literal_local_cluster
        ; Alcotest.test_case
            "local wins even if a target is supplied"
            `Quick
            test_local_wins_even_if_a_target_is_supplied
        ; Alcotest.test_case
            "top-level without target fails closed naming local form"
            `Quick
            test_top_level_without_target_fails_closed_naming_local_form
        ; Alcotest.test_case
            "the local spelling in the message is command-specific"
            `Quick
            test_local_form_message_is_command_specific
        ; Alcotest.test_case
            "top-level target supplies the destination"
            `Quick
            test_top_level_target_supplies_the_destination
        ; Alcotest.test_case
            "target without a kube_context fails closed"
            `Quick
            test_target_without_context_fails_closed
        ; Alcotest.test_case
            "a reserved-local target points at the local form"
            `Quick
            test_reserved_local_target_points_at_local_form
        ; Alcotest.test_case
            "resolution is deterministic"
            `Quick
            test_resolution_is_deterministic
        ] )
    ]
;;
