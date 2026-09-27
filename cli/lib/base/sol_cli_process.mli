type cmd =
  { argv : string list
  ; cwd : string option
  ; env : (string * string) list option
  ; timeout_s : float option
  ; redact : string list
  }

(** What a successful command printed, trimmed. *)
type output =
  { stdout : string
  ; stderr : string
  }

type error =
  | Spawn_failed of string
  | Non_zero of
      { exit_code : int
      ; stdout : string
      ; stderr : string
      }
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

(** [run_shell s] is {!run} for a shell command line. *)
val run_shell : ?echo:bool -> string -> (output, error) result

(** [completed ~exit_code ~stdout ~stderr] is the {!run} result for a process
    that exited with [exit_code]: for runners that wait on a process themselves. *)
val completed : exit_code:int -> stdout:string -> stderr:string -> (output, error) result

(** What a failed command said: its trimmed stderr, or its trimmed stdout when
    stderr is empty ("" when both are). For the [Non_zero] branch. *)
val failure_output : stdout:string -> stderr:string -> string

val error_to_string : error -> string

(** Print [argv] as the command line Sol is about to run, with each of [redact]
    replaced by [***]. *)
val echo_cmd : string list -> string list -> unit
