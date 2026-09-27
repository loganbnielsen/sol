type cmd =
  { argv : string list
  ; cwd : string option
  ; env : (string * string) list option
  ; timeout_s : float option
  ; redact : string list
  }

(** A command that ran and exited non-zero: the code and both streams, trimmed. *)
type failure =
  { exit_code : int
  ; stdout : string
  ; stderr : string
  }

(** What a successful command printed, trimmed. *)
type output =
  { stdout : string
  ; stderr : string
  }

type error =
  | Spawn_failed of string
  | Non_zero of failure
  | Timeout of float

val cmd
  :  ?cwd:string
  -> ?env:(string * string) list
  -> ?timeout_s:float
  -> ?redact:string list
  -> string list
  -> cmd

(** [run c] is [Ok] only when [c] exited 0 (REFAC-124). Any other exit is
    [Error (Non_zero _)] carrying the code and both streams, so a caller for which
    a particular exit means something -- kubectl's "not found" -- matches that
    branch. *)
val run : ?echo:bool -> cmd -> (output, error) result

(** A process Sol started and did not wait for (REFAC-134): a port-forward, a
    browser, a local service. *)
type background

(** [spawn ?output c]: start [c] without waiting. stdin is [/dev/null]; stdout
    and stderr go to [output] (default [/dev/null]). [c]'s [env] is merged over
    the environment as for {!run}; its [cwd] and [timeout_s] do not apply. *)
val spawn : ?output:Unix.file_descr -> cmd -> (background, error) result

val pid : background -> int

(** [stop b]: SIGTERM, then reap it if it has exited. Never raises: a process
    that is already gone is stopped. *)
val stop : background -> unit

(** [run_shell s] is {!run} for a shell command line. *)
val run_shell : ?echo:bool -> string -> (output, error) result

(** [completed ~exit_code ~stdout ~stderr] is the {!run} result for a process
    that exited with [exit_code]: for runners that wait on a process themselves. *)
val completed : exit_code:int -> stdout:string -> stderr:string -> (output, error) result

(** What a failed command said: its stderr, or its stdout when stderr is empty,
    or -- when it said nothing -- its exit code. Never empty (REFAC-123), so a
    caller never has to decide what a blank reason means. *)
val failure_message : failure -> string

val error_to_string : error -> string

(** Print [argv] as the command line Sol is about to run, with each of [redact]
    replaced by [***]. *)
val echo_cmd : string list -> string list -> unit
