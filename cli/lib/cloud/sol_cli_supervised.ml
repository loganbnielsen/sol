(* INFRA-076. See the interface for the failure this removes and the contract. *)

type outcome =
  | Exited of int
  | Signaled of int

type status =
  | No_previous
  | Running of
      { pid : int
      ; host : string
      ; started_at : float
      ; dir : string
      }
  | Resolved of
      { outcome : outcome
      ; dir : string
      }
  | Unresolved of
      { reason : string
      ; dir : string
      }

type facts =
  { recorded_outcome : outcome option
  ; same_host : bool
  ; alive : bool
  ; errored_state : string option
  ; acknowledged : bool
  ; pid : int
  ; host : string
  ; started_at : float
  ; dir : string
  }

let classify f =
  match f.recorded_outcome with
  | Some outcome when f.acknowledged -> Resolved { outcome; dir = f.dir }
  | Some (Exited _ as outcome) ->
    (match f.errored_state with
     | None -> Resolved { outcome; dir = f.dir }
     | Some path ->
       Unresolved
         { reason =
             Printf.sprintf
               "Terraform could not persist state to the backend and wrote it to %s \
                instead. Inspect it and push it deliberately (`terraform state push`); \
                Sol never pushes it for you."
               path
         ; dir = f.dir
         })
  | Some (Signaled n) ->
    Unresolved
      { reason =
          Printf.sprintf
            "Terraform was terminated by signal %d, so it did not finish its own \
             shutdown protocol (state persistence, lock release)."
            n
      ; dir = f.dir
      }
  | None when not f.same_host ->
    (* Liveness cannot be checked across hosts: never read that as abandoned. *)
    Running { pid = f.pid; host = f.host; started_at = f.started_at; dir = f.dir }
  | None when f.alive ->
    Running { pid = f.pid; host = f.host; started_at = f.started_at; dir = f.dir }
  | None when f.acknowledged -> Resolved { outcome = Signaled 0; dir = f.dir }
  | None ->
    Unresolved
      { reason =
          "no outcome was recorded and neither the supervisor nor Terraform is running \
           (the supervisor was killed, the machine restarted, or it ran out of memory)."
      ; dir = f.dir
      }
;;

let outcome_to_string = function
  | Exited n -> Printf.sprintf "exited %d" n
  | Signaled n -> Printf.sprintf "signaled %d" n
;;

(* OCaml reports signals in its own (negative) numbering; the record uses POSIX
   numbers, which is what an operator reading "signal 9" expects. *)
let posix_signal n =
  match n with
  | n when n = Sys.sighup -> 1
  | n when n = Sys.sigint -> 2
  | n when n = Sys.sigquit -> 3
  | n when n = Sys.sigill -> 4
  | n when n = Sys.sigabrt -> 6
  | n when n = Sys.sigfpe -> 8
  | n when n = Sys.sigkill -> 9
  | n when n = Sys.sigsegv -> 11
  | n when n = Sys.sigpipe -> 13
  | n when n = Sys.sigalrm -> 14
  | n when n = Sys.sigterm -> 15
  | n -> abs n
;;

let status_to_string = function
  | No_previous -> "no previous operation"
  | Running { pid; host; started_at; dir } ->
    Printf.sprintf
      "running: terraform pid %d on %s, started %s (record: %s)"
      pid
      host
      (Sol_cli_time.rfc3339 started_at)
      dir
  | Resolved { outcome; dir } ->
    Printf.sprintf "resolved: terraform %s (record: %s)" (outcome_to_string outcome) dir
  | Unresolved { reason; dir } -> Printf.sprintf "unresolved: %s (record: %s)" reason dir
;;

(* ── Files of one operation record ─────────────────────────────────────────── *)

(* Always absolute: the supervisor changes into Terraform's working directory
   before it writes, so a relative data home (XDG_DATA_HOME may be relative) would
   put the record somewhere the next command never looks. *)
let operations_dir ~key =
  let base = Filename.concat Sol_cli_state.dir "operations" in
  let base =
    if Filename.is_relative base then Filename.concat (Sys.getcwd ()) base else base
  in
  Filename.concat base key
;;

let latest_file ~key = Filename.concat (operations_dir ~key) "latest"
let file dir name = Filename.concat dir name

let read_file path =
  match In_channel.with_open_bin path In_channel.input_all with
  | s -> Some s
  | exception Sys_error _ -> None
;;

(* Write-then-rename, so a reader never sees half a record. *)
let write_atomic path contents =
  let tmp = path ^ ".tmp" in
  Out_channel.with_open_gen
    [ Open_wronly; Open_creat; Open_trunc; Open_binary ]
    0o600
    tmp
    (fun oc -> Out_channel.output_string oc contents);
  Sys.rename tmp path
;;

let outcome_of_string s =
  match String.split_on_char ' ' (String.trim s) with
  | [ "exited"; n ] -> Option.map (fun n -> Exited n) (int_of_string_opt n)
  | [ "signaled"; n ] -> Option.map (fun n -> Signaled n) (int_of_string_opt n)
  | _ -> None
;;

let meta_field meta name =
  String.split_on_char '\n' meta
  |> List.find_map (fun line ->
    match String.index_opt line '=' with
    | Some i when String.sub line 0 i = name ->
      Some (String.sub line (i + 1) (String.length line - i - 1))
    | _ -> None)
;;

(* A process's start time (clock ticks since boot, field 22 of /proc/<pid>/stat),
   so a recycled pid is not mistaken for the process we launched. [None] where
   /proc does not exist; there, liveness rests on the pid alone. *)
let start_time pid =
  match read_file (Printf.sprintf "/proc/%d/stat" pid) with
  | None -> None
  | Some stat ->
    (match String.rindex_opt stat ')' with
     | None -> None
     | Some i ->
       let fields =
         String.sub stat (i + 2) (String.length stat - i - 2) |> String.split_on_char ' '
       in
       (* After "pid (comm) ", field 3 is the first here; field 22 is index 19. *)
       List.nth_opt fields 19)
;;

let alive ~pid ~start =
  pid > 0
  && (match Unix.kill pid 0 with
      | () -> true
      | exception Unix.Unix_error (Unix.EPERM, _, _) -> true
      | exception Unix.Unix_error _ -> false)
  &&
  match start, start_time pid with
  | Some recorded, Some now -> String.equal recorded now
  | _ -> true
;;

let hostname () =
  try Unix.gethostname () with
  | Unix.Unix_error _ -> "unknown-host"
;;

let facts_of_dir dir =
  let meta = Option.value ~default:"" (read_file (file dir "meta")) in
  let int_field name =
    Option.value ~default:0 (Option.bind (meta_field meta name) int_of_string_opt)
  in
  let host = Option.value ~default:"" (meta_field meta "host") in
  let supervisor_pid = int_field "supervisor_pid" in
  (* An empty start time means it could not be read (no /proc), not a value to
     compare against: liveness then rests on the pid. *)
  let supervisor_start =
    match meta_field meta "supervisor_start" with
    | Some "" | None -> None
    | Some s -> Some s
  in
  let tf_pid, tf_start =
    match read_file (file dir "terraform.pid") with
    | None -> 0, None
    | Some s ->
      (match String.split_on_char ' ' (String.trim s) with
       | [ pid; start ] -> Option.value ~default:0 (int_of_string_opt pid), Some start
       | [ pid ] -> Option.value ~default:0 (int_of_string_opt pid), None
       | _ -> 0, None)
  in
  let same_host = String.equal host (hostname ()) in
  let errored_state =
    match meta_field meta "root" with
    | None -> None
    | Some root ->
      let path = Filename.concat root "errored.tfstate" in
      if Sys.file_exists path then Some path else None
  in
  { recorded_outcome = Option.bind (read_file (file dir "exit")) outcome_of_string
  ; same_host
  ; alive =
      same_host
      && (alive ~pid:supervisor_pid ~start:supervisor_start
          || alive ~pid:tf_pid ~start:tf_start)
  ; errored_state
  ; acknowledged = Sys.file_exists (file dir "acknowledged")
  ; pid = (if tf_pid > 0 then tf_pid else supervisor_pid)
  ; host
  ; started_at =
      Option.value
        ~default:0.
        (Option.bind (meta_field meta "started_at") float_of_string_opt)
  ; dir
  }
;;

let latest_dir ~key =
  match read_file (latest_file ~key) with
  | None -> None
  | Some name -> Some (Filename.concat (operations_dir ~key) (String.trim name))
;;

let latest ~key =
  match latest_dir ~key with
  | None -> No_previous
  | Some dir when not (Sys.file_exists dir) -> No_previous
  | Some dir -> classify (facts_of_dir dir)
;;

let acknowledge ~key =
  match latest_dir ~key with
  | None -> ()
  | Some dir ->
    write_atomic (file dir "acknowledged") (Printf.sprintf "%f\n" (Unix.gettimeofday ()))
;;

(* ── The supervisor (this binary, re-invoked) ──────────────────────────────── *)

let supervise ~dir = function
  | [] ->
    prerr_endline "sol __supervise: no command";
    exit 2
  | prog :: _ as argv ->
    let open_out name =
      Unix.openfile (file dir name) [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
    in
    let out = open_out "stdout"
    and err = open_out "stderr"
    and devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
    (* The supervisor keeps default signal dispositions: whatever it ignored, the
       exec'd Terraform would inherit. It needs none -- it has no controlling
       terminal (its own session), and nothing signals it by design. *)
    let pid =
      try Unix.create_process prog (Array.of_list argv) devnull out err with
      | Unix.Unix_error (e, _, _) ->
        write_atomic
          (file dir "stderr")
          (Printf.sprintf "could not start %s: %s\n" prog (Unix.error_message e));
        write_atomic (file dir "exit") "exited 127\n";
        exit 127
    in
    Unix.close devnull;
    Unix.close out;
    Unix.close err;
    write_atomic
      (file dir "terraform.pid")
      (Printf.sprintf
         "%d%s\n"
         pid
         (match start_time pid with
          | Some s -> " " ^ s
          | None -> ""));
    let rec wait () =
      match Unix.waitpid [] pid with
      | _, status -> status
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
    in
    let status = wait () in
    let recorded, code =
      match status with
      | Unix.WEXITED n -> Exited n, n
      | Unix.WSIGNALED n | Unix.WSTOPPED n ->
        let n = posix_signal n in
        Signaled n, 128 + n
    in
    write_atomic (file dir "exit") (outcome_to_string recorded ^ "\n");
    exit code
;;

let dispatch_if_supervisor () =
  match Array.to_list Sys.argv with
  | _ :: "__supervise" :: dir :: argv ->
    (try supervise ~dir argv with
     | e ->
       Printf.eprintf "sol __supervise: %s\n%!" (Printexc.to_string e);
       exit 125)
  | _ -> ()
;;

(* ── The parent: launch, forward interrupts, wait ──────────────────────────── *)

let operation_counter = ref 0

let new_operation_dir ~key =
  incr operation_counter;
  let base = operations_dir ~key in
  let name =
    Printf.sprintf
      "%s-%d-%d"
      (Sol_cli_time.compact (Unix.gettimeofday ()))
      (Unix.getpid ())
      !operation_counter
  in
  let dir = Filename.concat base name in
  Sol_cli_scaffold.mkdir_p dir;
  base, name, dir
;;

let tf_pid_of dir =
  Option.bind
    (read_file (file dir "terraform.pid"))
    (fun s ->
       match String.split_on_char ' ' (String.trim s) with
       | pid :: _ -> int_of_string_opt pid
       | [] -> None)
;;

let run
      ?(echo = false)
      ?(supervisor = Sys.executable_name)
      ~key
      ~root
      (c : Sol_cli_process.cmd)
  =
  match c.argv with
  | [] -> Error (Sol_cli_process.Spawn_failed "empty argv")
  | _ :: _ ->
    if echo then Sol_cli_process.echo_cmd c.argv c.redact;
    let base, name, dir = new_operation_dir ~key in
    let env =
      match c.env with
      | None -> Unix.environment ()
      | Some extras ->
        let keys = List.map fst extras in
        let kept =
          Array.to_list (Unix.environment ())
          |> List.filter (fun entry ->
            let k =
              match String.index_opt entry '=' with
              | Some i -> String.sub entry 0 i
              | None -> entry
            in
            not (List.mem k keys))
        in
        Array.of_list (kept @ List.map (fun (k, v) -> k ^ "=" ^ v) extras)
    in
    flush_all ();
    (match Unix.fork () with
     | 0 ->
       (* Child: its own session, so a terminal's Ctrl-C or hangup, or a signal to
          Sol's process group, never reaches Terraform or its provider plugins. *)
       (try
          ignore (Unix.setsid ());
          Option.iter Unix.chdir c.cwd;
          Unix.execve
            supervisor
            (Array.of_list (supervisor :: "__supervise" :: dir :: c.argv))
            env
        with
        | _ -> Unix._exit 127)
     | supervisor_pid ->
       write_atomic
         (file dir "meta")
         (String.concat
            "\n"
            [ "host=" ^ hostname ()
            ; Printf.sprintf "supervisor_pid=%d" supervisor_pid
            ; "supervisor_start=" ^ Option.value ~default:"" (start_time supervisor_pid)
            ; Printf.sprintf "sol_pid=%d" (Unix.getpid ())
            ; Printf.sprintf "started_at=%f" (Unix.gettimeofday ())
            ; "root=" ^ root
            ]
          ^ "\n");
       write_atomic (Filename.concat base "latest") (name ^ "\n");
       (* Interrupts: forward one SIGINT to Terraform's pid only, then a second as
          Terraform's own "cancel now"; ignore the rest. Never the provider
          plugins, never the process group, never SIGKILL. *)
       let interrupts = ref 0 in
       let forwarded = ref 0 in
       let forward () =
         while !forwarded < min !interrupts 2 do
           match tf_pid_of dir with
           | None -> raise Exit
           | Some pid ->
             incr forwarded;
             (try Unix.kill pid Sys.sigint with
              | Unix.Unix_error _ -> ());
             if !forwarded = 1
             then
               Printf.eprintf
                 "\n\
                  interrupt: sent one SIGINT to terraform (pid %d) only; it is stopping \
                  itself safely (persisting state, releasing the lock). Waiting for it. \
                  Interrupt again to ask Terraform to cancel immediately -- Terraform \
                  warns that this may lose data.\n\
                  %!"
                 pid
             else
               Printf.eprintf
                 "\n\
                  interrupt: sent a second SIGINT to terraform (pid %d): Terraform will \
                  cancel immediately and data loss may occur. Still waiting for it to \
                  exit.\n\
                  %!"
                 pid
         done
       in
       let forward () =
         try forward () with
         | Exit -> ()
       in
       let handler = Sys.Signal_handle (fun _ -> incr interrupts) in
       let previous =
         List.map
           (fun s -> s, Sys.signal s handler)
           [ Sys.sigint; Sys.sigterm; Sys.sighup ]
       in
       let restore () = List.iter (fun (s, b) -> Sys.set_signal s b) previous in
       let rec wait () =
         forward ();
         match Unix.waitpid [ Unix.WNOHANG ] supervisor_pid with
         | 0, _ ->
           (try Unix.sleepf 0.1 with
            | Unix.Unix_error (Unix.EINTR, _, _) -> ());
           wait ()
         | _, status -> status
         | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
       in
       let status = Fun.protect ~finally:restore wait in
       let read name = Option.value ~default:"" (read_file (file dir name)) in
       (match Option.bind (read_file (file dir "exit")) outcome_of_string with
        | Some outcome ->
          let exit_code =
            match outcome with
            | Exited n -> n
            | Signaled n -> 128 + n
          in
          Ok
            { Sol_cli_process.exit_code
            ; stdout = String.trim (read "stdout")
            ; stderr = String.trim (read "stderr")
            }
        | None ->
          Error
            (Sol_cli_process.Spawn_failed
               (Printf.sprintf
                  "terraform's supervisor ended (%s) without recording an outcome; the \
                   operation record is %s"
                  (match status with
                   | Unix.WEXITED n -> Printf.sprintf "exit %d" n
                   | Unix.WSIGNALED n -> Printf.sprintf "signal %d" (posix_signal n)
                   | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" (posix_signal n))
                  dir))))
;;
