let base_dir = Filename.concat Sol_cli_state.dir "runs"

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

let run_sort_key id =
  match List.rev (String.split_on_char '-' id) with
  | _pid :: ts :: _ -> ts, id
  | _ -> "", id
;;

let run_is_live id =
  match List.rev (String.split_on_char '-' id) with
  | pid :: _ ->
    String.length pid > 0
    && String.for_all (fun c -> c >= '0' && c <= '9') pid
    && Sys.file_exists (Filename.concat "/proc" pid)
  | [] -> false
;;

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

let mkdir_reporting dir =
  Sol_cli_fs.mkdir_p dir
  |> Result.iter_error (Sol_cli_report.warn "warning: run log unavailable: %s")
;;

let create ?(base = base_dir) ?(keep = 20) ~prefix () : t =
  let base_dir = base in
  mkdir_reporting base_dir;
  let run_id =
    generate_run_id ~prefix ~now:(Unix.gettimeofday ()) ~pid:(Unix.getpid ())
  in
  let dir = Filename.concat base_dir run_id in
  let existing =
    try Array.to_list (Sys.readdir base_dir) with
    | Sys_error _ -> []
  in
  mkdir_reporting dir;
  List.iter
    (fun stale_id ->
       Sol_cli_fs.remove_tree (Filename.concat base_dir stale_id)
       |> Result.iter_error (Sol_cli_report.warn "warning: could not prune a run log: %s"))
    (runs_to_prune
       ~exclude:(run_id :: List.filter run_is_live existing)
       ~all_run_ids:existing
       ~keep
       ());
  { run_id; dir }
;;

let phase_log_path t ~phase = Filename.concat t.dir (phase ^ ".log")
let run_id t = t.run_id
let dir t = t.dir
let ensure_parent path = mkdir_reporting (Filename.dirname path)

let write_file path contents =
  ensure_parent path;
  match
    Out_channel.with_open_gen
      [ Open_wronly; Open_creat; Open_trunc; Open_text ]
      0o600
      path
      (fun oc -> Out_channel.output_string oc contents)
  with
  | () -> ()
  | exception Sys_error message ->
    Sol_cli_report.warn "warning: run log unavailable: %s" message
;;

let finish_phase t ~name ~elapsed_s ~ok ~contents =
  let log_path = phase_log_path t ~phase:name in
  write_file log_path contents;
  Sol_cli_report.app "%s" (format_phase_line ~name ~elapsed_s ~ok);
  if not ok
  then
    Sol_cli_report.app_block
      (format_failure_report ~run_id:t.run_id ~log_path ~tail:(tail_lines ~n:40 contents))
;;

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
      (thunk : unit -> (Sol_cli_process.output, Sol_cli_process.error) result)
  : (Sol_cli_process.output, Sol_cli_process.error) result
  =
  let start = Unix.gettimeofday () in
  let result = thunk () in
  let elapsed_s = Unix.gettimeofday () -. start in
  let ok, contents =
    match result with
    | Ok r -> Result.is_ok result, phase_log_content ~stdout:r.stdout ~stderr:r.stderr
    | Error e ->
      false, phase_log_content ~stdout:"" ~stderr:(Sol_cli_process.error_to_string e)
  in
  finish_phase t ~name ~elapsed_s ~ok ~contents;
  result
;;

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
