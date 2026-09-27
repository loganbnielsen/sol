(* REFAC-126: Sol records what it starts and asks the record, rather than
   rediscovering its forwards by parsing other processes' command lines.

   Each forward has, in Sol's state directory, a record (what was asked for), a
   pid file (the wrapper script's pid, which [setsid] makes its process-group
   id) and a lock file. The wrapper holds an exclusive [flock] on the lock file
   for as long as it -- or the kubectl it runs, which inherits the descriptor --
   is alive. So "is this forward running" is "is its lock held", which a reused
   pid cannot fake, and nothing reads /proc. *)

type spec =
  { name : string
  ; namespace : string
  ; target : string
  ; local_port : int
  ; remote_port : int
  }

open Result.Syntax

let record_json (pf : spec) : Yojson.Safe.t =
  `Assoc
    [ "name", `String pf.name
    ; "namespace", `String pf.namespace
    ; "target", `String pf.target
    ; "local_port", `Int pf.local_port
    ; "remote_port", `Int pf.remote_port
    ]
;;

let spec_of_json (json : Yojson.Safe.t) : (spec, string) result =
  match json with
  | `Assoc fields ->
    let str key =
      match List.assoc_opt key fields with
      | Some (`String s) -> Ok s
      | _ -> Error (Printf.sprintf "field %S is missing or not text" key)
    in
    let int key =
      match List.assoc_opt key fields with
      | Some (`Int n) -> Ok n
      | _ -> Error (Printf.sprintf "field %S is missing or not a number" key)
    in
    let* name = str "name" in
    let* namespace = str "namespace" in
    let* target = str "target" in
    let* local_port = int "local_port" in
    let* remote_port = int "remote_port" in
    Ok { name; namespace; target; local_port; remote_port }
  | _ -> Error "not an object"
;;

let write_file path content =
  match
    Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc content)
  with
  | () -> Ok ()
  | exception Sys_error msg -> Error msg
;;

let write_record (pf : spec) =
  Sol_cli_state.ensure ();
  write_file (Sol_cli_state.record_file pf.name) (Yojson.Safe.to_string (record_json pf))
;;

let read_record path =
  match Yojson.Safe.from_file path with
  | json -> spec_of_json json |> Result.map_error (Printf.sprintf "%s: %s" path)
  | exception (Sys_error msg | Yojson.Json_error msg) -> Error msg
;;

(* Every forward Sol has a record of, and the records it could not read (with
   why), so a corrupt one is reported rather than skipped silently. *)
let records () =
  match Sys.readdir Sol_cli_state.dir with
  | exception Sys_error _ -> [], []
  | entries ->
    entries
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f Sol_cli_state.record_suffix)
    |> List.sort String.compare
    |> List.map (fun f -> read_record (Filename.concat Sol_cli_state.dir f))
    |> List.partition_map (function
      | Ok spec -> Left spec
      | Error why -> Right why)
;;

(* Held exactly while the forward's wrapper or its kubectl is alive. [flock -n]
   exits non-zero when it cannot take the lock. *)
let is_running name =
  Result.is_error
    (Sol_cli_process.run
       (Sol_cli_process.cmd [ "flock"; "-n"; Sol_cli_state.lock_file name; "true" ]))
;;

let read_pid name =
  match In_channel.with_open_text (Sol_cli_state.pid_file name) In_channel.input_all with
  | text -> int_of_string_opt (String.trim text)
  | exception Sys_error _ -> None
;;

let remove_files name =
  [ Sol_cli_state.record_file name; Sol_cli_state.pid_file name ]
  |> List.iter (fun path ->
    try Sys.remove path with
    | Sys_error _ -> ())
;;

(* Stops the forward's whole process group -- the wrapper and the kubectl it
   runs -- but only while its lock is held, so a pid that has since been reused
   by an unrelated process is never signalled. *)
let stop name =
  if is_running name
  then
    read_pid name
    |> Option.iter (fun pid ->
      try Unix.kill (-pid) Sys.sigterm with
      | Unix.Unix_error _ -> ());
  remove_files name
;;

let stop_all () =
  let recorded, _unreadable = records () in
  recorded |> List.iter (fun pf -> stop pf.name)
;;

(* AUDIT-065 / FEAT-063: the wrapper script's retry loop must never let a later
   ambient `kubectl config use-context` redirect an already-running
   port-forward. The destination is passed in and named explicitly (the caller
   supplies the literal local destination — port-forwarding is a local-dev
   feature), so every retry pins the same `--context` and the ambient context is
   never consulted at all. *)

(* Consecutive fast failures before the retry loop gives up rather than
   spinning forever. A kubectl port-forward that exits in under
   [quick_fail_threshold_s] seconds counts as a fast failure; anything that
   ran longer (i.e. it was actually forwarding) resets the streak to 0. A
   pod restart typically reconnects within a few seconds, so this stays well
   clear of that case while still bounding a genuinely dead cluster. *)
let max_fail_streak = 30
let quick_fail_threshold_s = 5

let wrapper_script ~ctx (pf : spec) =
  let lf = Filename.quote (Sol_cli_state.log_file pf.name) in
  let context_name = ctx.Sol_cli_kube_destination.destination.context in
  let kubectl_invocation =
    Printf.sprintf
      "kubectl --context %s port-forward -n %s %s %d:%d"
      (Filename.quote context_name)
      (Filename.quote pf.namespace)
      (Filename.quote pf.target)
      pf.local_port
      pf.remote_port
  in
  [ "#!/bin/sh"
  ; (* The lock is the forward's liveness: held for this script's life, and
       inherited by kubectl. A second wrapper for the same name leaves. It waits
       briefly rather than not at all, because [is_running] probes by taking the
       lock for an instant, and a probe landing on this line must not look like a
       running forward. *)
    Printf.sprintf "exec 9>%s" (Filename.quote (Sol_cli_state.lock_file pf.name))
  ; Printf.sprintf
      "flock -w 2 9 || { echo \"[sol port-forward] %s is already running; not starting a \
       second\" >> %s; exit 0; }"
      pf.name
      lf
  ; Printf.sprintf "echo $$ > %s" (Filename.quote (Sol_cli_state.pid_file pf.name))
  ; "fails=0"
  ; Printf.sprintf "max_fails=%d" max_fail_streak
  ; "while true; do"
  ; "  t0=$(date +%s)"
  ; Printf.sprintf "  %s </dev/null >> %s 2>&1" kubectl_invocation lf
  ; "  t1=$(date +%s)"
  ; Printf.sprintf "  if [ $((t1 - t0)) -lt %d ]; then" quick_fail_threshold_s
  ; "    fails=$((fails + 1))"
  ; "  else"
  ; "    fails=0"
  ; "  fi"
  ; "  if [ \"$fails\" -ge \"$max_fails\" ]; then"
  ; Printf.sprintf
      "    echo \"[sol port-forward] giving up after $max_fails consecutive failed \
       attempts (pinned context %s unreachable or gone)\" >> %s"
      context_name
      lf
  ; "    exit 1"
  ; "  fi"
  ; "  sleep 1"
  ; "done"
  ; ""
  ]
  |> String.concat "\n"
;;

(** Write a self-restarting wrapper script and background it in a new session.
    On pod rollout, kubectl exits; the loop restarts it within ~1 s so the
    port-forward stays live across deploys without manual intervention. The
    destination's context is pinned into every retry (see AUDIT-065); the loop
    gives up after [max_fail_streak] consecutive fast failures instead of
    retrying forever against a context/cluster that is gone. *)
let start ~ctx (pf : spec) =
  Sol_cli_state.ensure ();
  let script = Sol_cli_state.script_file pf.name in
  let* () = write_record pf in
  let* () = write_file script (wrapper_script ~ctx pf) in
  let* () =
    match Unix.chmod script 0o755 with
    | () -> Ok ()
    | exception Unix.Unix_error (e, _, _) -> Error (script ^ ": " ^ Unix.error_message e)
  in
  Sol_cli_process.run_shell
    (Printf.sprintf "setsid %s </dev/null >/dev/null 2>&1 &" (Filename.quote script))
  |> Result.map ignore
  |> Result.map_error Sol_cli_process.error_to_string
;;

type liveness =
  | Alive
  | Dead of
      { log : string
      ; log_tail : string list (** the log's last lines; [[]] when it has none *)
      }

let last_lines path n =
  match In_channel.with_open_text path In_channel.input_all with
  | text ->
    let lines =
      String.split_on_char '\n' text |> List.filter_map Sol_cli_string.non_blank
    in
    List.filteri (fun i _ -> i >= List.length lines - n) lines
  | exception Sys_error _ -> []
;;

(** Give a just-started forward 200 ms, then report whether it is still alive,
    and if not, where its log is and what it said last. *)
let check_alive ~name =
  Unix.sleepf 0.2;
  if is_running name
  then Alive
  else (
    let log = Sol_cli_state.log_file name in
    Dead { log; log_tail = last_lines log 5 })
;;

(** The forwards Sol started on [local_port] for a different namespace or
    target, stopped so the new one can bind. A process Sol did not start is
    never touched. *)
let replace_conflicting ~local_port ~namespace ~target =
  let recorded, _unreadable = records () in
  recorded
  |> List.filter (fun pf ->
    pf.local_port = local_port
    && (pf.namespace <> namespace || pf.target <> target)
    && is_running pf.name)
  |> List.map (fun pf ->
    stop pf.name;
    pf)
;;
