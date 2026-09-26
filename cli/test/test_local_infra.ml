(* Bounded-concurrency installs for `sol local infra up`.

   Seven independent Helm releases were installed strictly one after another --
   ~290s in every golden path, in both languages. The property that matters when
   they stop being serialized is the bound: a k3d cluster is one node, so what
   must not happen is seven `helm --wait` installs fighting over it (or a failed
   component leaving siblings half-installed and unreported).

   The installs run in forked children, so "how many were in flight" cannot be a
   shared in-memory counter -- each child records its own start and end in a file
   and the test reconstructs the overlap from that. That is also why the
   assertions are about observable events rather than about the parent's private
   bookkeeping. *)

let record path line =
  let oc = open_out_gen [ Open_append; Open_creat ] 0o600 path in
  output_string oc (line ^ "\n");
  close_out oc
;;

let read_lines path =
  let ic = open_in path in
  let rec go acc =
    match input_line ic with
    | line -> go (line :: acc)
    | exception End_of_file ->
      close_in ic;
      List.rev acc
  in
  go []
;;

(* The peak number of installs that were running at the same time, from the
   start/end events they recorded. *)
let peak_concurrency lines =
  let rec go concurrent peak = function
    | [] -> peak
    | line :: rest ->
      let is_start = String.length line > 6 && String.sub line 0 6 = "start " in
      let is_end = String.length line > 4 && String.sub line 0 4 = "end " in
      let concurrent =
        if is_start then concurrent + 1 else if is_end then concurrent - 1 else concurrent
      in
      go concurrent (max peak concurrent) rest
  in
  go 0 0 lines
;;

let install ~path ~delay ?(fail = false) label =
  { Sol_cli_local_infra.label
  ; run =
      (fun () ->
        record path ("start " ^ label);
        Unix.sleepf delay;
        record path ("end " ^ label);
        if fail then Error ("installed nothing: " ^ label) else Ok ())
  }
;;

let with_events f =
  let path = Filename.temp_file "sol-local-infra-test-" ".events" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () -> f path)
;;

let test_installs_overlap_within_the_bound () =
  with_events (fun path ->
    let installs =
      List.init 6 (fun i -> install ~path ~delay:0.2 (Printf.sprintf "c%d" i))
    in
    match Sol_cli_local_infra.run_bounded ~max_in_flight:3 installs with
    | Error e -> Alcotest.failf "installs should have succeeded: %s" e
    | Ok () ->
      let peak = peak_concurrency (read_lines path) in
      Alcotest.(check bool) "three installs do overlap" true (peak >= 2);
      Alcotest.(check bool)
        (Printf.sprintf "never more than three at once (saw %d)" peak)
        true
        (peak <= 3);
      Alcotest.(check int)
        "every install ran and finished"
        12
        (List.length (read_lines path)))
;;

let test_serial_mode_keeps_plan_order () =
  with_events (fun path ->
    let installs =
      List.init 4 (fun i -> install ~path ~delay:0.05 (Printf.sprintf "c%d" i))
    in
    match Sol_cli_local_infra.run_bounded ~max_in_flight:1 installs with
    | Error e -> Alcotest.failf "serial installs should have succeeded: %s" e
    | Ok () ->
      Alcotest.(check int) "one at a time" 1 (peak_concurrency (read_lines path));
      Alcotest.(check (list string))
        "started in the order given"
        [ "start c0"; "start c1"; "start c2"; "start c3" ]
        (List.filteri (fun i _ -> i mod 2 = 0) (read_lines path)))
;;

let test_a_failure_stops_new_installs () =
  with_events (fun path ->
    let installs =
      [ install ~path ~delay:0.05 "a"
      ; install ~path ~delay:0.05 ~fail:true "b"
      ; install ~path ~delay:0.05 "c"
      ]
    in
    match Sol_cli_local_infra.run_bounded ~max_in_flight:1 installs with
    | Ok () -> Alcotest.fail "a failing install must fail the run"
    | Error message ->
      let contains needle = Sol_cli_string.contains ~needle message in
      Alcotest.(check bool)
        "the failure names the component that failed"
        true
        (contains "b failed");
      Alcotest.(check bool)
        "and says which components never ran, by name"
        true
        (contains "not attempted" && contains "c");
      let lines = read_lines path in
      Alcotest.(check bool) "the failed component ran" true (List.mem "start b" lines);
      Alcotest.(check bool)
        "the component after it never started"
        false
        (List.mem "start c" lines))
;;

let () =
  Alcotest.run
    "local_infra"
    [ ( "bounded installs"
      , [ Alcotest.test_case
            "overlap, bounded"
            `Quick
            test_installs_overlap_within_the_bound
        ; Alcotest.test_case "serial keeps order" `Quick test_serial_mode_keeps_plan_order
        ; Alcotest.test_case
            "a failure stops the queue"
            `Quick
            test_a_failure_stops_new_installs
        ] )
    ]
;;
