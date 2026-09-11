type spec =
  { name : string
  ; namespace : string
  ; target : string
  ; local_port : int
  ; remote_port : int
  }

(* ------------------------------------------------------------------ *)
(* Internal helpers                                                     *)
(* ------------------------------------------------------------------ *)

let string_contains ~needle haystack =
  let nl = String.length needle
  and hl = String.length haystack in
  if nl = 0
  then true
  else if nl > hl
  then false
  else (
    let stop = hl - nl in
    let rec go i =
      if i > stop
      then false
      else (
        let rec cmp j = j = nl || (needle.[j] = haystack.[i + j] && cmp (j + 1)) in
        cmp 0 || go (i + 1))
    in
    go 0)
;;

let read_last_lines path n =
  try
    let ic = open_in path in
    let content = In_channel.input_all ic in
    close_in ic;
    let lines = String.split_on_char '\n' (String.trim content) in
    let total = List.length lines in
    let tail =
      if total <= n then lines else List.filteri (fun i _ -> i >= total - n) lines
    in
    String.concat "\n" tail
  with
  | _ -> ""
;;

let extract_after_prefix s prefix =
  let pl = String.length prefix
  and sl = String.length s in
  let rec go i =
    if i + pl > sl
    then ""
    else if String.sub s i pl = prefix
    then (
      let j = ref (i + pl) in
      while !j < sl && s.[!j] >= '0' && s.[!j] <= '9' do
        incr j
      done;
      if !j > i + pl then String.sub s (i + pl) (!j - (i + pl)) else go (i + 1))
    else go (i + 1)
  in
  go 0
;;

let pid_owning_port local_port =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd [ "ss"; "-tlnp"; Printf.sprintf "sport = :%d" local_port ])
  with
  | Ok r ->
    let digits = extract_after_prefix r.Sol_cli_process.stdout "pid=" in
    if digits = ""
    then None
    else (
      try Some (int_of_string digits) with
      | _ -> None)
  | Error _ -> None
;;

let read_proc_cmdline pid =
  let path = Printf.sprintf "/proc/%d/cmdline" pid in
  try
    let ic = open_in path in
    let raw = In_channel.input_all ic in
    close_in ic;
    List.filter (fun s -> s <> "") (String.split_on_char '\x00' raw)
  with
  | _ ->
    (match
       Sol_cli_process.run
         (Sol_cli_process.cmd [ "ps"; "-p"; string_of_int pid; "-o"; "args=" ])
     with
     | Ok r when r.Sol_cli_process.exit_code = 0 ->
       String.split_on_char ' ' r.Sol_cli_process.stdout
     | _ -> [])
;;

let parse_kubectl_pf_args args =
  let rec find_ns = function
    | "-n" :: ns :: _ -> ns
    | _ :: rest -> find_ns rest
    | [] -> raise Not_found
  in
  let ns = find_ns args in
  let svc =
    List.find_map
      (fun a ->
         if String.length a > 4 && String.sub a 0 4 = "svc/"
         then Some (String.sub a 4 (String.length a - 4))
         else None)
      args
  in
  match svc with
  | Some s -> ns, s
  | None -> raise Not_found
;;

(* ------------------------------------------------------------------ *)
(* Public API                                                           *)
(* ------------------------------------------------------------------ *)

let is_running name =
  let pf = Sol_cli_state.pid_file name in
  if Sys.file_exists pf
  then (
    let ic = open_in pf in
    let pid_s = String.trim (In_channel.input_all ic) in
    close_in ic;
    try
      let pid = int_of_string pid_s in
      let alive =
        try
          Unix.kill pid 0;
          true
        with
        | Unix.Unix_error (Unix.ESRCH, _, _) -> false
        | Unix.Unix_error _ -> true
      in
      let args = if alive then String.concat " " (read_proc_cmdline pid) else "" in
      let ok =
        alive && string_contains ~needle:(Printf.sprintf "sol-pf-%s.sh" name) args
      in
      if not ok
      then (
        try Sys.remove pf with
        | _ -> ());
      ok
    with
    | _ ->
      (try Sys.remove pf with
       | _ -> ());
      false)
  else false
;;

(* AUDIT-065: the wrapper script's retry loop must never let a later ambient
   `kubectl config use-context` redirect an already-running port-forward.
   [start] pins the context that is current *at creation time* into every
   retry iteration via `--context`, so switching contexts elsewhere for
   unrelated work can no longer silently repoint a live port-forward at a
   different (possibly since-destroyed) cluster. *)

(* Consecutive fast failures before the retry loop gives up rather than
   spinning forever. A kubectl port-forward that exits in under
   [quick_fail_threshold_s] seconds counts as a fast failure; anything that
   ran longer (i.e. it was actually forwarding) resets the streak to 0. A
   pod restart typically reconnects within a few seconds, so this stays well
   clear of that case while still bounding a genuinely dead cluster. *)
let max_fail_streak = 30
let quick_fail_threshold_s = 5

let current_kube_context () =
  match Sol_cli_kubectl.config_current_context () with
  | Ok r
    when r.Sol_cli_process.exit_code = 0 && String.trim r.Sol_cli_process.stdout <> "" ->
    Some (String.trim r.Sol_cli_process.stdout)
  | _ -> None
;;

(** Write a self-restarting wrapper script and background it in a new session.
    On pod rollout, kubectl exits; the loop restarts it within ~1 s so the
    port-forward stays live across deploys without manual intervention. The
    kubectl context current at call time is captured and pinned into every retry
    (see AUDIT-065); the loop gives up after [max_fail_streak] consecutive fast
    failures instead of retrying forever against a context/cluster that is gone.
*)
let start (pf : spec) =
  Sol_cli_state.ensure ();
  let sf = Sol_cli_state.script_file pf.name in
  let lf = Sol_cli_state.log_file pf.name in
  let pf_file = Sol_cli_state.pid_file pf.name in
  let context = current_kube_context () in
  let kubectl_invocation =
    match context with
    | Some ctx ->
      Printf.sprintf
        "kubectl --context %s port-forward -n %s %s %d:%d"
        (Filename.quote ctx)
        (Filename.quote pf.namespace)
        (Filename.quote pf.target)
        pf.local_port
        pf.remote_port
    | None ->
      Printf.sprintf
        "kubectl port-forward -n %s %s %d:%d"
        (Filename.quote pf.namespace)
        (Filename.quote pf.target)
        pf.local_port
        pf.remote_port
  in
  let give_up_reason =
    match context with
    | Some ctx -> Printf.sprintf "pinned context %s unreachable or gone" ctx
    | None -> "repeated fast failures; no kubectl context was available to pin at start"
  in
  let lines =
    [ "#!/bin/sh"
    ; Printf.sprintf "echo $$ > %s" (Filename.quote pf_file)
    ; "fails=0"
    ; Printf.sprintf "max_fails=%d" max_fail_streak
    ; "while true; do"
    ; "  t0=$(date +%s)"
    ; Printf.sprintf "  %s </dev/null >> %s 2>&1" kubectl_invocation (Filename.quote lf)
    ; "  t1=$(date +%s)"
    ; Printf.sprintf "  if [ $((t1 - t0)) -lt %d ]; then" quick_fail_threshold_s
    ; "    fails=$((fails + 1))"
    ; "  else"
    ; "    fails=0"
    ; "  fi"
    ; "  if [ \"$fails\" -ge \"$max_fails\" ]; then"
    ; Printf.sprintf
        "    echo \"[sol port-forward] giving up after $max_fails consecutive failed \
         attempts (%s)\" >> %s"
        give_up_reason
        (Filename.quote lf)
    ; Printf.sprintf "    rm -f %s" (Filename.quote pf_file)
    ; "    exit 1"
    ; "  fi"
    ; "  sleep 1"
    ; "done"
    ; ""
    ]
  in
  let oc = open_out sf in
  output_string oc (String.concat "\n" lines);
  close_out oc;
  ignore (Sol_cli_process.run (Sol_cli_process.cmd [ "chmod"; "+x"; sf ]));
  ignore
    (Sol_cli_process.run_shell
       (Printf.sprintf "setsid %s </dev/null >/dev/null 2>&1 &" (Filename.quote sf)))
;;

let stop_all () =
  if Sys.file_exists Sol_cli_state.dir
  then (
    let entries =
      try Sys.readdir Sol_cli_state.dir with
      | _ -> [||]
    in
    Array.iter
      (fun f ->
         if Filename.check_suffix f ".pid"
         then (
           let path = Printf.sprintf "%s/%s" Sol_cli_state.dir f in
           try
             let ic = open_in path in
             let pid_s = String.trim (In_channel.input_all ic) in
             close_in ic;
             (match int_of_string_opt pid_s with
              | Some pid ->
                (try Unix.kill pid Sys.sigterm with
                 | Unix.Unix_error _ -> ())
              | None -> ());
             Sys.remove path
           with
           | _ -> ()))
      entries)
;;

(** Sleep 200 ms, then check whether the port-forward process for [name] is
    still alive. When dead, prints a warning with the log path and a suggested
    remediation command. Returns [true] if alive. *)
let check_alive ~name ~local_port =
  Unix.sleepf 0.2;
  let pf = Sol_cli_state.pid_file name in
  let alive =
    if Sys.file_exists pf
    then (
      try
        let ic = open_in pf in
        let pid_s = String.trim (In_channel.input_all ic) in
        close_in ic;
        let pid = int_of_string pid_s in
        try
          Unix.kill pid 0;
          true
        with
        | Unix.Unix_error (Unix.ESRCH, _, _) -> false
        | Unix.Unix_error _ -> true
      with
      | _ -> false)
    else false
  in
  if not alive
  then (
    let lf = Sol_cli_state.log_file name in
    let tail = read_last_lines lf 5 in
    Printf.printf
      "  warning: port-forward for %s failed (port %d may be in use by another workspace).\n"
      name
      local_port;
    Printf.printf "           See %s for details.\n" lf;
    if tail <> ""
    then
      Printf.printf
        "           Last log lines:\n             %s\n"
        (String.concat "\n             " (String.split_on_char '\n' tail));
    Printf.printf "           Run: kill $(lsof -ti:%d) && sol up\n%!" local_port);
  alive
;;

(** Check whether [local_port] is bound by a stale Sol-managed kubectl
    port-forward pointing at a different namespace or [target] than the one we
    are about to start. When detected, kills the stale process and prints a
    notice. Returns [true] if a stale was found and killed. *)
let detect_stale ~local_port ~namespace ~target =
  match pid_owning_port local_port with
  | None -> false
  | Some pid ->
    let args = read_proc_cmdline pid in
    let is_kubectl =
      match args with
      | prog :: _ ->
        let base = Filename.basename prog in
        base = "kubectl" || base = "kubectl.exe"
      | [] -> false
    in
    if not is_kubectl
    then false
    else (
      let has_pf = List.exists (fun a -> a = "port-forward") args in
      if not has_pf
      then false
      else (
        match
          try Some (parse_kubectl_pf_args args) with
          | Not_found -> None
        with
        | None -> false
        | Some (old_ns, old_svc) ->
          if old_ns <> namespace || "svc/" ^ old_svc <> target
          then (
            Printf.printf
              "  [sol up] replacing stale port-forward for %s/%s on port %d\n%!"
              old_ns
              old_svc
              local_port;
            (try Unix.kill pid Sys.sigterm with
             | Unix.Unix_error _ -> ());
            true)
          else false))
;;
