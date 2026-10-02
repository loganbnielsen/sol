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
    | Error e -> Windtrap.failf "installs should have succeeded: %s" e
    | Ok () ->
      let peak = peak_concurrency (read_lines path) in
      Windtrap.equal Windtrap.bool ~msg:"three installs do overlap" true (peak >= 2);
      Windtrap.equal
        Windtrap.bool
        ~msg:(Printf.sprintf "never more than three at once (saw %d)" peak)
        true
        (peak <= 3);
      Windtrap.equal
        Windtrap.int
        ~msg:"every install ran and finished"
        12
        (List.length (read_lines path)))
;;

let test_serial_mode_keeps_plan_order () =
  with_events (fun path ->
    let installs =
      List.init 4 (fun i -> install ~path ~delay:0.05 (Printf.sprintf "c%d" i))
    in
    match Sol_cli_local_infra.run_bounded ~max_in_flight:1 installs with
    | Error e -> Windtrap.failf "serial installs should have succeeded: %s" e
    | Ok () ->
      Windtrap.equal
        Windtrap.int
        ~msg:"one at a time"
        1
        (peak_concurrency (read_lines path));
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"started in the order given"
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
    | Ok () -> Windtrap.fail "a failing install must fail the run"
    | Error message ->
      let contains needle = Sol_cli_string.contains ~needle message in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the failure names the component that failed"
        true
        (contains "b failed");
      Windtrap.equal
        Windtrap.bool
        ~msg:"and says which components never ran, by name"
        true
        (contains "not attempted" && contains "c");
      let lines = read_lines path in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the failed component ran"
        true
        (List.mem "start b" lines);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the component after it never started"
        false
        (List.mem "start c" lines))
;;

let%test "bounded installs: overlap, bounded" = test_installs_overlap_within_the_bound ()
let%test "bounded installs: serial keeps order" = test_serial_mode_keeps_plan_order ()

let%test "bounded installs: a failure stops the queue" =
  test_a_failure_stops_new_installs ()
;;
