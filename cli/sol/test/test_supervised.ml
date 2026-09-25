(* INFRA-076: Terraform survives Sol, a graceful interrupt reaches Terraform only,
   and every run leaves an operation record the next command can classify.

   Hermetic: "terraform" is a shell script that records the signals it receives and
   runs a child standing in for a provider plugin, which records its own. "Sol" is a
   forked copy of this test that calls [Sol_cli_supervised.run], so the test can kill
   it, interrupt it, or signal its process group -- the failures being fixed. *)

module S = Sol_cli_supervised

let contains haystack needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with
  | Not_found -> false
;;

let check = Alcotest.(check bool)
let tmp_root = Filename.concat (Filename.get_temp_dir_name ()) "sol-supervised-test"

let fresh name =
  let dir =
    Filename.concat
      tmp_root
      (Printf.sprintf "%s-%d-%f" name (Unix.getpid ()) (Unix.gettimeofday ()))
  in
  Sol_cli_scaffold.mkdir_p dir;
  dir
;;

let read path =
  match In_channel.with_open_bin path In_channel.input_all with
  | s -> Some s
  | exception Sys_error _ -> None
;;

let fake_terraform =
  {|#!/bin/sh
MARK="$FAKE_MARK"
echo $$ > "$MARK/tf.pid"
on_int() {
  echo INT >> "$MARK/tf.signals"
  echo "Interrupt received. Gracefully shutting down..."
  kill -KILL "$PROV" 2>/dev/null
  exit 1
}
trap on_int INT
trap 'echo TERM >> "$MARK/tf.signals"; kill -KILL "$PROV" 2>/dev/null; exit 1' TERM
sh -c 'trap "echo TERM >> \"$1/provider.signals\"; exit 0" TERM
       echo $$ > "$1/provider.pid"
       while :; do sleep 0.1; done' provider "$MARK" &
PROV=$!
echo "Creating..."
i=0
while [ "$i" -lt "${FAKE_TICKS:-30}" ]; do
  echo "Still creating... [$i]"
  sleep 0.1
  i=$((i + 1))
done
case "$FAKE_MODE" in
  selfkill) kill -KILL "$PROV"; kill -KILL $$ ;;
  errored) echo '{}' > errored.tfstate; kill -KILL "$PROV"; echo "Failed to save state" >&2; exit 1 ;;
esac
kill -KILL "$PROV" 2>/dev/null
echo "Apply complete!"
exit 0
|}
;;

type case =
  { mark : string
  ; root : string
  ; key : string
  ; script : string
  }

let make name =
  let mark = fresh (name ^ "-mark") in
  let root = fresh (name ^ "-root") in
  let script = Filename.concat mark "terraform" in
  Out_channel.with_open_gen
    [ Open_wronly; Open_creat; Open_trunc ]
    0o755
    script
    (fun oc -> Out_channel.output_string oc fake_terraform);
  { mark; root; key = "test-" ^ name ^ "-" ^ Filename.basename mark; script }
;;

(* Fork an emulated Sol: its own process group (so the test can signal "Sol's
   group" without signalling itself), running one supervised Terraform. *)
let spawn_sol ?(mode = "") ?(ticks = 30) c =
  match Unix.fork () with
  | 0 ->
    (try
       ignore (Unix.setsid ());
       let result =
         S.run
           ~key:c.key
           ~root:c.root
           (Sol_cli_process.cmd
              ~cwd:c.root
              ~env:
                [ "FAKE_MARK", c.mark
                ; "FAKE_MODE", mode
                ; "FAKE_TICKS", string_of_int ticks
                ]
              [ c.script; "apply" ])
       in
       let line =
         match result with
         | Ok r -> Printf.sprintf "exit %d" r.Sol_cli_process.exit_code
         | Error e -> "error " ^ Sol_cli_process.error_to_string e
       in
       Out_channel.with_open_bin (Filename.concat c.mark "sol.result") (fun oc ->
         Out_channel.output_string oc line)
     with
     | _ -> ());
    Unix._exit 0
  | pid -> pid
;;

let rec wait_until ?(tries = 200) what f =
  if f ()
  then ()
  else if tries = 0
  then Alcotest.failf "timed out waiting for %s" what
  else (
    Unix.sleepf 0.05;
    wait_until ~tries:(tries - 1) what f)
;;

let wait_child pid =
  let rec go () =
    match Unix.waitpid [] pid with
    | _ -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> go ()
  in
  go ()
;;

let tf_started c () = Sys.file_exists (Filename.concat c.mark "provider.pid")

let not_running key () =
  match S.latest ~key with
  | S.Running _ | S.No_previous -> false
  | _ -> true
;;

let signals c who = read (Filename.concat c.mark (who ^ ".signals"))

let latest_dir key =
  match S.latest ~key with
  | S.Running { dir; _ } | S.Resolved { dir; _ } | S.Unresolved { dir; _ } -> dir
  | S.No_previous -> Alcotest.fail "no operation recorded"
;;

let is_resolved_exit n = function
  | S.Resolved { outcome = S.Exited m; _ } -> m = n
  | _ -> false
;;

let is_unresolved = function
  | S.Unresolved _ -> true
  | _ -> false
;;

let meta_field c name =
  let meta = Option.get (read (Filename.concat (latest_dir c.key) "meta")) in
  String.split_on_char '\n' meta
  |> List.find_map (fun l ->
    match String.index_opt l '=' with
    | Some i when String.sub l 0 i = name ->
      Some (String.sub l (i + 1) (String.length l - i - 1))
    | _ -> None)
  |> Option.get
;;

(* Terraform's process group is its supervisor's session, led by the supervisor. *)
let terraform_group c = int_of_string (meta_field c "supervisor_pid")

(* ── Cases ─────────────────────────────────────────────────────────────────── *)

let test_clean_run () =
  let c = make "clean" in
  let sol = spawn_sol ~ticks:3 c in
  wait_child sol;
  check "Sol saw exit 0" true (read (Filename.concat c.mark "sol.result") = Some "exit 0");
  check "Resolved, exited 0" true (is_resolved_exit 0 (S.latest ~key:c.key));
  check
    "output is durable in the operation record"
    true
    (match read (Filename.concat (latest_dir c.key) "stdout") with
     | Some out -> String.length out > 0 && contains out "Apply complete!"
     | None -> false)
;;

let test_sol_death_does_not_kill_terraform () =
  let c = make "death" in
  let sol = spawn_sol ~ticks:30 c in
  wait_until "terraform to start" (tf_started c);
  Unix.sleepf 0.4;
  (match S.latest ~key:c.key with
   | S.Running _ -> ()
   | other ->
     Alcotest.failf "expected Running mid-apply, got %s" (S.status_to_string other));
  (* The failure being removed: Sol dies mid-apply. *)
  Unix.kill sol Sys.sigkill;
  wait_child sol;
  wait_until ~tries:400 "terraform to finish on its own" (not_running c.key);
  check
    "terraform finished normally: Resolved, exited 0 (no SIGPIPE)"
    true
    (is_resolved_exit 0 (S.latest ~key:c.key));
  check "terraform received no signal" true (signals c "tf" = None);
  check
    "terraform kept writing after Sol died"
    true
    (match read (Filename.concat (latest_dir c.key) "stdout") with
     | Some out -> contains out "Apply complete!"
     | None -> false)
;;

let test_interrupt_reaches_terraform_only () =
  let c = make "interrupt" in
  (* An unrelated process that must not be touched. *)
  let bystander =
    Unix.create_process "sleep" [| "sleep"; "30" |] Unix.stdin Unix.stdout Unix.stderr
  in
  let sol = spawn_sol ~ticks:60 c in
  wait_until "terraform to start" (tf_started c);
  Unix.sleepf 0.3;
  (* A terminal Ctrl-C: SIGINT to Sol's whole process group. Terraform runs in a
     session of its own, so only Sol's forwarding can reach it. *)
  Unix.kill (-sol) Sys.sigint;
  wait_child sol;
  check
    "Sol returned terraform's graceful non-zero exit"
    true
    (read (Filename.concat c.mark "sol.result") = Some "exit 1");
  check "terraform received exactly one SIGINT" true (signals c "tf" = Some "INT\n");
  check "the provider plugin received nothing from Sol" true (signals c "provider" = None);
  check
    "a graceful interrupt is Resolved, not suspicious"
    true
    (is_resolved_exit 1 (S.latest ~key:c.key));
  check
    "an unrelated process is untouched"
    true
    (match Unix.kill bystander 0 with
     | () -> true
     | exception Unix.Unix_error _ -> false);
  Unix.kill bystander Sys.sigkill;
  wait_child bystander
;;

(* Positive control: the fake provider does record a group-wide signal, so
   "received nothing" above is an observation that could have failed. *)
let test_positive_control_group_kill_reaches_provider () =
  let c = make "control" in
  let sol = spawn_sol ~ticks:60 c in
  wait_until "terraform to start" (tf_started c);
  Unix.sleepf 0.3;
  (* What Attempt 6 did: SIGTERM to Terraform's process group, provider included. *)
  Unix.kill (-terraform_group c) Sys.sigterm;
  wait_child sol;
  check
    "the provider recorded the group SIGTERM"
    true
    (signals c "provider" = Some "TERM\n")
;;

let test_signal_death_is_unresolved () =
  let c = make "selfkill" in
  let sol = spawn_sol ~mode:"selfkill" ~ticks:2 c in
  wait_child sol;
  check "killed by a signal is Unresolved" true (is_unresolved (S.latest ~key:c.key))
;;

let test_errored_state_is_unresolved () =
  let c = make "errored" in
  let sol = spawn_sol ~mode:"errored" ~ticks:2 c in
  wait_child sol;
  check
    "errored.tfstate in the root is Unresolved"
    true
    (match S.latest ~key:c.key with
     | S.Unresolved { reason; _ } -> contains reason "errored.tfstate"
     | _ -> false);
  check
    "the file is preserved"
    true
    (Sys.file_exists (Filename.concat c.root "errored.tfstate"));
  S.acknowledge ~key:c.key;
  check
    "acknowledged is no longer Unresolved"
    true
    (not (is_unresolved (S.latest ~key:c.key)))
;;

let test_supervisor_killed_is_unresolved () =
  let c = make "supkill" in
  let sol = spawn_sol ~ticks:60 c in
  wait_until "terraform to start" (tf_started c);
  Unix.sleepf 0.3;
  let supervisor = terraform_group c in
  let tf =
    int_of_string (String.trim (Option.get (read (Filename.concat c.mark "tf.pid"))))
  in
  (* The machine-level failures: supervisor and Terraform both gone, no outcome. *)
  Unix.kill supervisor Sys.sigkill;
  (try Unix.kill tf Sys.sigkill with
   | Unix.Unix_error _ -> ());
  (try Unix.kill (-supervisor) Sys.sigkill with
   | Unix.Unix_error _ -> ());
  wait_child sol;
  wait_until "processes to disappear" (not_running c.key);
  check
    "no outcome and nothing alive is Unresolved"
    true
    (is_unresolved (S.latest ~key:c.key))
;;

(* ── Pure classification ───────────────────────────────────────────────────── *)

let facts
      ?(outcome = None)
      ?(same_host = true)
      ?(alive = false)
      ?(errored = None)
      ?(ack = false)
      ()
  =
  { S.recorded_outcome = outcome
  ; same_host
  ; alive
  ; errored_state = errored
  ; acknowledged = ack
  ; pid = 42
  ; host = "h"
  ; started_at = 0.
  ; dir = "d"
  }
;;

let test_classify () =
  check
    "exit 0 Resolved"
    true
    (is_resolved_exit 0 (S.classify (facts ~outcome:(Some (S.Exited 0)) ())));
  check
    "graceful non-zero Resolved"
    true
    (is_resolved_exit 1 (S.classify (facts ~outcome:(Some (S.Exited 1)) ())));
  check
    "signal Unresolved"
    true
    (is_unresolved (S.classify (facts ~outcome:(Some (S.Signaled 9)) ())));
  check
    "errored.tfstate Unresolved"
    true
    (is_unresolved
       (S.classify
          (facts ~outcome:(Some (S.Exited 1)) ~errored:(Some "x/errored.tfstate") ())));
  check
    "no outcome, alive: Running"
    true
    (match S.classify (facts ~alive:true ()) with
     | S.Running _ -> true
     | _ -> false);
  check
    "no outcome, other host: Running (never read as abandoned)"
    true
    (match S.classify (facts ~same_host:false ()) with
     | S.Running _ -> true
     | _ -> false);
  check
    "no outcome, nothing alive: Unresolved"
    true
    (is_unresolved (S.classify (facts ())));
  check
    "acknowledged signal: not Unresolved"
    true
    (not (is_unresolved (S.classify (facts ~outcome:(Some (S.Signaled 9)) ~ack:true ()))))
;;

let () =
  S.dispatch_if_supervisor ();
  Alcotest.run
    "supervised"
    [ "classify", [ Alcotest.test_case "pure" `Quick test_classify ]
    ; ( "process"
      , [ Alcotest.test_case "clean run" `Quick test_clean_run
        ; Alcotest.test_case "Sol's death" `Quick test_sol_death_does_not_kill_terraform
        ; Alcotest.test_case "interrupt" `Quick test_interrupt_reaches_terraform_only
        ; Alcotest.test_case
            "positive control"
            `Quick
            test_positive_control_group_kill_reaches_provider
        ; Alcotest.test_case "signal death" `Quick test_signal_death_is_unresolved
        ; Alcotest.test_case "errored.tfstate" `Quick test_errored_state_is_unresolved
        ; Alcotest.test_case
            "supervisor killed"
            `Quick
            test_supervisor_killed_is_unresolved
        ] )
    ]
;;
