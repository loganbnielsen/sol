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
  match
    Unix.openfile (Sol_cli_state.lock_file name) [ Unix.O_RDWR; Unix.O_CREAT ] 0o600
  with
  | exception Unix.Unix_error _ -> false
  | fd ->
    Fun.protect
      ~finally:(fun () ->
        try Unix.close fd with
        | Unix.Unix_error _ -> ())
      (fun () ->
         match Unix.lockf fd Unix.F_TLOCK 0 with
         | () ->
           (match Unix.lockf fd Unix.F_ULOCK 0 with
            | () -> ()
            | exception Unix.Unix_error _ -> ());
           false
         | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) -> true
         | exception Unix.Unix_error _ -> false)
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
let quick_fail_threshold_s = 5.

let next_fail_streak ~streak ~elapsed_s =
  if elapsed_s < quick_fail_threshold_s then streak + 1 else 0
;;

let exhausted streak = streak >= max_fail_streak

let kubectl_argv ~context (pf : spec) =
  [ "kubectl"
  ; "--context"
  ; context
  ; "port-forward"
  ; "-n"
  ; pf.namespace
  ; pf.target
  ; Printf.sprintf "%d:%d" pf.local_port pf.remote_port
  ]
;;

let run_kubectl ~context (pf : spec) =
  match
    Sol_cli_process.spawn
      ~output:Unix.stdout
      (Sol_cli_process.cmd (kubectl_argv ~context pf))
  with
  | Ok background -> Sol_cli_process.join background
  | Error _ -> ()
;;

let already_running_message name =
  Printf.sprintf "[sol port-forward] %s is already running; not starting a second" name
;;

let give_up_message ~context =
  Printf.sprintf
    "[sol port-forward] giving up after %d consecutive failed attempts (pinned context \
     %s unreachable or gone)"
    max_fail_streak
    context
;;

let rec acquire_lock fd remaining =
  match Unix.lockf fd Unix.F_TLOCK 0 with
  | () -> true
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) when remaining > 0 ->
    Unix.sleepf 0.1;
    acquire_lock fd (remaining - 1)
  | exception Unix.Unix_error _ -> false
;;

let supervise ~name ~context =
  match read_record (Sol_cli_state.record_file name) with
  | Error why ->
    Sol_cli_report.err "[sol port-forward] %s: %s" name why;
    exit 2
  | Ok pf ->
    let lock =
      Unix.openfile (Sol_cli_state.lock_file name) [ Unix.O_RDWR; Unix.O_CREAT ] 0o600
    in
    if not (acquire_lock lock 20)
    then (
      Sol_cli_report.err "%s" (already_running_message name);
      exit 0);
    write_file (Sol_cli_state.pid_file name) (string_of_int (Unix.getpid ()))
    |> Result.iter_error (fun why ->
      Sol_cli_report.err "[sol port-forward] %s: %s" name why);
    let rec loop streak =
      let started = Unix.gettimeofday () in
      run_kubectl ~context pf;
      let streak =
        next_fail_streak ~streak ~elapsed_s:(Unix.gettimeofday () -. started)
      in
      if exhausted streak
      then (
        Sol_cli_report.err "%s" (give_up_message ~context);
        exit 1)
      else (
        Unix.sleepf 1.;
        loop streak)
    in
    loop 0
;;

let dispatch_if_supervisor () =
  match Array.to_list Sys.argv with
  | _ :: "__port-forward" :: name :: context :: _ ->
    (try supervise ~name ~context with
     | e ->
       Sol_cli_report.err "sol __port-forward: %s" (Printexc.to_string e);
       exit 125)
  | _ -> ()
;;

let start ?(supervisor = Sys.executable_name) ~ctx (pf : spec) =
  let* () = Sol_cli_state.ensure () in
  let* () = write_record pf in
  let context = ctx.Sol_cli_kube_destination.destination.context in
  flush_all ();
  match Unix.fork () with
  | 0 ->
    (try
       ignore (Unix.setsid ());
       let devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
       let log =
         Unix.openfile
           (Sol_cli_state.log_file pf.name)
           [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ]
           0o600
       in
       Unix.dup2 devnull Unix.stdin;
       Unix.dup2 log Unix.stdout;
       Unix.dup2 log Unix.stderr;
       Unix.close devnull;
       Unix.close log;
       Unix.execve
         supervisor
         (Array.of_list [ supervisor; "__port-forward"; pf.name; context ])
         (Unix.environment ())
     with
     | _ -> Unix._exit 127)
  | _ -> Ok ()
  | exception Unix.Unix_error (e, _, _) -> Error (Unix.error_message e)
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

type readiness_error =
  | Not_started of string
  | Port_conflict of string
  | Not_ready of
      { log : string
      ; log_tail : string list
      }

let readiness_error_to_string = function
  | Not_started message -> message
  | Port_conflict message -> message
  | Not_ready { log; log_tail } ->
    let tail =
      match log_tail with
      | [] -> ""
      | lines -> "\n  " ^ String.concat "\n  " lines
    in
    Printf.sprintf "the port-forward did not become ready; see %s%s" log tail
;;

let loopback_accepts_connection port =
  let is_not_listening_yet = function
    | Unix.ECONNREFUSED
    | Unix.ETIMEDOUT
    | Unix.ENETUNREACH
    | Unix.EHOSTUNREACH
    | Unix.ECONNRESET -> true
    | _ -> false
  in
  match Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 with
  | exception Unix.Unix_error _ -> false
  | socket ->
    Fun.protect
      ~finally:(fun () ->
        try Unix.close socket with
        | Unix.Unix_error _ -> ())
      (fun () ->
         match Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) with
         | () -> true
         | exception Unix.Unix_error (e, _, _) when is_not_listening_yet e -> false
         | exception Unix.Unix_error _ -> false)
;;

let endpoint_ready_timeout_s = 20.
let endpoint_ready_interval_s = 0.25
let endpoint_ready_log_lines = 5

let ensure_ready
      ?(supervisor = Sys.executable_name)
      ?(timeout_s = endpoint_ready_timeout_s)
      ?(interval_s = endpoint_ready_interval_s)
      ~ctx
      (pf : spec)
  =
  let log = Sol_cli_state.log_file pf.name in
  let* () =
    if is_running pf.name
    then Ok ()
    else if loopback_accepts_connection pf.local_port
    then
      Error
        (Port_conflict
           (Printf.sprintf
              "something is already listening on localhost:%d, so the %s port-forward \
               cannot own it"
              pf.local_port
              pf.name))
    else start ~supervisor ~ctx pf |> Result.map_error (fun e -> Not_started e)
  in
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec wait () =
    if is_running pf.name && loopback_accepts_connection pf.local_port
    then Ok ()
    else if Unix.gettimeofday () >= deadline
    then (
      let log_tail = last_lines log endpoint_ready_log_lines in
      stop pf.name;
      Error (Not_ready { log; log_tail }))
    else (
      Unix.sleepf interval_s;
      wait ())
  in
  wait ()
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
