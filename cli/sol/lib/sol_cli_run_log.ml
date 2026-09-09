(* Per-invocation run-log directory for noisy subprocess output (Terraform,
   Helm, Docker, kubectl). Normal command output stays compact: one line per
   phase (name, elapsed time, ok/FAILED); the full log goes to a file and is
   only ever printed (last N lines) when that phase fails. *)

let base_dir = Filename.concat Sol_cli_state.dir "runs"

(* Timestamp-prefixed so lexicographic sort of run ids is chronological. *)
let generate_run_id ~prefix ~now ~pid =
  let tm = Unix.gmtime now in
  Printf.sprintf "%s-%04d%02d%02dT%02d%02d%02dZ-%d" prefix
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec pid

let tail_lines ~n (s : string) : string =
  let lines = String.split_on_char '\n' s in
  let len = List.length lines in
  if len <= n then s
  else String.concat "\n" (List.filteri (fun i _ -> i >= len - n) lines)

let phase_log_content ~stdout ~stderr : string =
  Printf.sprintf "%s%s" stdout
    (if stderr = "" then "" else "\n--- stderr ---\n" ^ stderr)

let format_phase_line ~name ~elapsed_s ~ok : string =
  Printf.sprintf "[%s] %s (%.1fs)" name
    (if ok then "ok" else "FAILED")
    elapsed_s

let format_failure_report ~log_path ~tail : string =
  Printf.sprintf "  log: %s\n  last lines:\n%s\n" log_path
    (String.concat "\n"
       (List.map (fun l -> "    " ^ l) (String.split_on_char '\n' tail)))

(* Run ids are lexicographically sortable timestamps; keep the most recent
   [keep], report the rest for pruning. *)
let runs_to_prune ~all_run_ids ~keep : string list =
  if keep < 0 then []
  else
    let sorted = List.sort compare all_run_ids in
    let n = List.length sorted in
    if n <= keep then [] else List.filteri (fun i _ -> i < n - keep) sorted

type t = { run_id : string; dir : string }

let create ?(keep = 20) ~prefix () : t =
  Sol_cli_scaffold.mkdir_p base_dir;
  let run_id =
    generate_run_id ~prefix ~now:(Unix.gettimeofday ()) ~pid:(Unix.getpid ())
  in
  let dir = Filename.concat base_dir run_id in
  Sol_cli_scaffold.mkdir_p dir;
  (let existing =
     try Array.to_list (Sys.readdir base_dir) with Sys_error _ -> []
   in
   List.iter
     (fun stale_id ->
       let stale_dir = Filename.concat base_dir stale_id in
       try
         Array.iter
           (fun f ->
             try Sys.remove (Filename.concat stale_dir f) with _ -> ())
           (Sys.readdir stale_dir);
         Unix.rmdir stale_dir
       with _ -> ())
     (runs_to_prune ~all_run_ids:existing ~keep));
  { run_id; dir }

let phase_log_path t ~phase = Filename.concat t.dir (phase ^ ".log")

let run_phase t ~name
    (thunk : unit -> (Sol_cli_process.result, Sol_cli_process.error) result) :
    (Sol_cli_process.result, Sol_cli_process.error) result =
  let start = Unix.gettimeofday () in
  let result = thunk () in
  let elapsed_s = Unix.gettimeofday () -. start in
  let log_path = phase_log_path t ~phase:name in
  let ok, contents =
    match result with
    | Ok r ->
        ( r.Sol_cli_process.exit_code = 0,
          phase_log_content ~stdout:r.Sol_cli_process.stdout
            ~stderr:r.Sol_cli_process.stderr )
    | Error e ->
        ( false,
          phase_log_content ~stdout:""
            ~stderr:(Sol_cli_process.error_to_string e) )
  in
  (let oc = open_out log_path in
   output_string oc contents;
   close_out oc);
  Printf.printf "%s\n%!" (format_phase_line ~name ~elapsed_s ~ok);
  if not ok then
    Printf.printf "%s%!"
      (format_failure_report ~log_path ~tail:(tail_lines ~n:40 contents));
  result
