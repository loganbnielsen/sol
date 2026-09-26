(* Per-invocation run-log directory for noisy subprocess output (Terraform,
   Helm, Docker, kubectl). Normal command output stays compact: one line per
   phase (name, elapsed time, ok/FAILED); the full log goes to a file and is
   only ever printed (last N lines) when that phase fails. *)

let base_dir = Filename.concat Sol_cli_state.dir "runs"

(* Timestamp-prefixed so lexicographic sort of run ids is chronological. *)
let generate_run_id ~prefix ~now ~pid =
  Printf.sprintf "%s-%s-%d" prefix (Sol_cli_time.compact now) pid
;;

let tail_lines ~n (s : string) : string =
  let lines = String.split_on_char '\n' s in
  let len = List.length lines in
  if len <= n
  then s
  else String.concat "\n" (List.filteri (fun i _ -> i >= len - n) lines)
;;

let phase_log_content ~stdout ~stderr : string =
  Printf.sprintf "%s%s" stdout (if stderr = "" then "" else "\n--- stderr ---\n" ^ stderr)
;;

let format_phase_line ~name ~elapsed_s ~ok : string =
  Printf.sprintf "[%s] %s (%.1fs)" name (if ok then "ok" else "FAILED") elapsed_s
;;

let format_failure_report ~run_id ~log_path ~tail : string =
  Printf.sprintf
    "  run: %s\n  log: %s\n  last lines:\n%s\n"
    run_id
    log_path
    (String.concat "\n" (List.map (fun l -> "    " ^ l) (String.split_on_char '\n' tail)))
;;

(* Run ids are timestamps with an arbitrary command prefix
   ([<prefix>-<YYYYMMDDTHHMMSSZ>-<pid>]), so the timestamp -- not the whole id --
   is what orders them. Sorting the whole string is NOT chronological across
   commands: "cloud-apply-…" sorts before "deploy-…" purely by prefix letter,
   which made a freshly created run look like the oldest one and let [create]
   prune the directory it had just made. The prefix may itself contain '-', so
   the timestamp is the second-to-last field. *)
let run_sort_key id =
  match List.rev (String.split_on_char '-' id) with
  | _pid :: ts :: _ -> ts, id
  | _ -> "", id
;;

(* A run directory belongs to a process that may still be running. A long command
   — a cloud apply or destroy takes tens of minutes — writes into that directory
   at the end of every phase, so pruning it underneath a live run makes the next
   write raise an uncaught [Sys_error]. For [cloud destroy] that aborts the
   teardown mid-flight and leaves the target provisioned and billing, which is
   exactly how HARDEN-002 Run 5 attempt 2's first destroy died.

   The run id already ends in the owning pid, so liveness is checkable directly.
   Where it cannot be established (a platform without [/proc], or an id whose
   tail is not a pid) this is conservatively [false] and pruning behaves as it
   did before. *)
let run_is_live id =
  match List.rev (String.split_on_char '-' id) with
  | pid :: _ ->
    String.length pid > 0
    && String.for_all (fun c -> c >= '0' && c <= '9') pid
    && Sys.file_exists (Filename.concat "/proc" pid)
  | [] -> false
;;

(* Keep the most recent [keep] (never [exclude]), report the rest for pruning,
   oldest first. *)
let runs_to_prune ?(exclude = []) ~all_run_ids ~keep () : string list =
  if keep < 0
  then []
  else (
    let candidates = List.filter (fun id -> not (List.mem id exclude)) all_run_ids in
    let sorted =
      List.sort (fun a b -> compare (run_sort_key a) (run_sort_key b)) candidates
    in
    let n = List.length sorted in
    if n <= keep then [] else List.filteri (fun i _ -> i < n - keep) sorted)
;;

type t =
  { run_id : string
  ; dir : string
  }

let create ?(base = base_dir) ?(keep = 20) ~prefix () : t =
  let base_dir = base in
  Sol_cli_scaffold.mkdir_p base_dir;
  let run_id =
    generate_run_id ~prefix ~now:(Unix.gettimeofday ()) ~pid:(Unix.getpid ())
  in
  let dir = Filename.concat base_dir run_id in
  (* Snapshot the existing runs BEFORE creating this one: the new directory must
     never be a pruning candidate for itself. (It previously was, and because
     pruning ordered whole ids lexicographically -- not chronologically across
     different command prefixes -- a fresh "cloud-apply-…" run could sort before
     the older "deploy-…" runs, be pruned as the oldest, and leave the phase-log
     write failing with an uncaught Sys_error.) [~exclude] keeps that guarantee
     even if the ordering is changed again. *)
  let existing =
    try Array.to_list (Sys.readdir base_dir) with
    | Sys_error _ -> []
  in
  Sol_cli_scaffold.mkdir_p dir;
  List.iter
    (fun stale_id ->
       let stale_dir = Filename.concat base_dir stale_id in
       try
         Array.iter
           (fun f ->
              try Sys.remove (Filename.concat stale_dir f) with
              | _ -> ())
           (Sys.readdir stale_dir);
         Unix.rmdir stale_dir
       with
       | _ -> ())
    (runs_to_prune
     (* INFRA-033: exclude every run whose process is still alive, not just
          this one. A long command writes to its phase logs throughout its life,
          so pruning a live run's directory makes its next write raise an
          uncaught [Sys_error] — and for [cloud destroy] that aborts a teardown
          mid-flight, leaving the target provisioned and billing. *)
       ~exclude:(run_id :: List.filter run_is_live existing)
       ~all_run_ids:existing
       ~keep
       ());
  { run_id; dir }
;;

let phase_log_path t ~phase = Filename.concat t.dir (phase ^ ".log")
let run_id t = t.run_id
let dir t = t.dir

(* INFRA-033: losing a phase log is never a reason to abort the command that is
   producing it. Pruning now skips runs whose process is alive, but a directory
   can still disappear underneath a long command (external cleanup, a stale-pid
   false negative, a shared run directory), and an uncaught [Sys_error] here used
   to kill a [cloud destroy] mid-teardown with the target still provisioned. So
   recreate the run directory if it is gone and keep going. *)
let ensure_parent path = Sol_cli_scaffold.mkdir_p (Filename.dirname path)

(* SEC-008: 0600. A phase log is a subprocess's full output, which can carry
   credentials a tool echoes; other local users have no reason to read it. *)
let write_file path contents =
  ensure_parent path;
  let oc = open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_text ] 0o600 path in
  output_string oc contents;
  close_out oc
;;

(* Shared finish for every phase kind: write the log, print the compact line
   and — only on failure — the run id, log path and tail. *)
let finish_phase t ~name ~elapsed_s ~ok ~contents =
  let log_path = phase_log_path t ~phase:name in
  write_file log_path contents;
  Printf.printf "%s\n%!" (format_phase_line ~name ~elapsed_s ~ok);
  if not ok
  then
    Printf.printf
      "%s%!"
      (format_failure_report ~run_id:t.run_id ~log_path ~tail:(tail_lines ~n:40 contents))
;;

(** Append [text] to a phase's log, creating it if needed. Lets a caller record
    diagnostics a phase produced outside [run_phase]/[run_task] — for example
    the rendered plan it acted on. *)
let append_phase_log t ~phase text =
  let path = phase_log_path t ~phase in
  ensure_parent path;
  let oc = open_out_gen [ Open_wronly; Open_creat; Open_append; Open_text ] 0o600 path in
  output_string oc text;
  close_out oc
;;

let run_phase
      t
      ~name
      (thunk : unit -> (Sol_cli_process.result, Sol_cli_process.error) result)
  : (Sol_cli_process.result, Sol_cli_process.error) result
  =
  let start = Unix.gettimeofday () in
  let result = thunk () in
  let elapsed_s = Unix.gettimeofday () -. start in
  let ok, contents =
    match result with
    | Ok r ->
      ( Result.is_ok (Sol_cli_process.check result)
      , phase_log_content
          ~stdout:r.Sol_cli_process.stdout
          ~stderr:r.Sol_cli_process.stderr )
    | Error e ->
      false, phase_log_content ~stdout:"" ~stderr:(Sol_cli_process.error_to_string e)
  in
  finish_phase t ~name ~elapsed_s ~ok ~contents;
  result
;;

(** Like [run_phase], but for a phase that is not one subprocess: [thunk]
    returns [Ok v] or [Error msg], and [msg] becomes the phase's log content on
    failure. Same compact line and failure report as [run_phase], so the deploy
    path and the Terraform path share one mechanism. *)
let run_task t ~name (thunk : unit -> ('a, string) result) : ('a, string) result =
  let start = Unix.gettimeofday () in
  let result = thunk () in
  let elapsed_s = Unix.gettimeofday () -. start in
  let ok, contents =
    match result with
    | Ok _ -> true, ""
    | Error msg -> false, msg
  in
  finish_phase t ~name ~elapsed_s ~ok ~contents;
  result
;;
