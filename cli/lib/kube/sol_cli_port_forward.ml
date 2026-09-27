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
  let* () = Sol_cli_state.ensure () in
  write_file (Sol_cli_state.record_file pf.name) (Yojson.Safe.to_string (record_json pf))
;;

let read_record path =
  match Yojson.Safe.from_file path with
  | json -> spec_of_json json |> Result.map_error (Printf.sprintf "%s: %s" path)
  | exception (Sys_error msg | Yojson.Json_error msg) -> Error msg
;;

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
    Sol_cli_fs.remove_if_present path
    |> Result.iter_error (Sol_cli_report.warn "warning: could not remove %s"))
;;

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
  ; Printf.sprintf "exec 9>%s" (Filename.quote (Sol_cli_state.lock_file pf.name))
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

let start ~ctx (pf : spec) =
  let* () = Sol_cli_state.ensure () in
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
      ; log_tail : string list
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

let check_alive ~name =
  Unix.sleepf 0.2;
  if is_running name
  then Alive
  else (
    let log = Sol_cli_state.log_file name in
    Dead { log; log_tail = last_lines log 5 })
;;

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
