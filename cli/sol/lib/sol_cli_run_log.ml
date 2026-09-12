(* Per-invocation run-log directory for noisy subprocess output (Terraform,
   Helm, Docker, kubectl). Normal command output stays compact: one line per
   phase (name, elapsed time, ok/FAILED); the full log goes to a file and is
   only ever printed (last N lines) when that phase fails. *)

let base_dir = Filename.concat Sol_cli_state.dir "runs"

(* Timestamp-prefixed so lexicographic sort of run ids is chronological. *)
let generate_run_id ~prefix ~now ~pid =
  let tm = Unix.gmtime now in
  Printf.sprintf
    "%s-%04d%02d%02dT%02d%02d%02dZ-%d"
    prefix
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec
    pid
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

(* Run ids are lexicographically sortable timestamps; keep the most recent
   [keep], report the rest for pruning. *)
let runs_to_prune ~all_run_ids ~keep : string list =
  if keep < 0
  then []
  else (
    let sorted = List.sort compare all_run_ids in
    let n = List.length sorted in
    if n <= keep then [] else List.filteri (fun i _ -> i < n - keep) sorted)
;;

type t =
  { run_id : string
  ; dir : string
  }

let create ?(keep = 20) ~prefix () : t =
  Sol_cli_scaffold.mkdir_p base_dir;
  let run_id =
    generate_run_id ~prefix ~now:(Unix.gettimeofday ()) ~pid:(Unix.getpid ())
  in
  let dir = Filename.concat base_dir run_id in
  Sol_cli_scaffold.mkdir_p dir;
  (let existing =
     try Array.to_list (Sys.readdir base_dir) with
     | Sys_error _ -> []
   in
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
     (runs_to_prune ~all_run_ids:existing ~keep));
  { run_id; dir }
;;

let phase_log_path t ~phase = Filename.concat t.dir (phase ^ ".log")
let run_id t = t.run_id
let dir t = t.dir

let write_file path contents =
  let oc = open_out path in
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
  let oc = open_out_gen [ Open_creat; Open_append; Open_text ] 0o644 path in
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
      ( r.Sol_cli_process.exit_code = 0
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
