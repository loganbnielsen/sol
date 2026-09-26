type cmd =
  { argv : string list
  ; cwd : string option
  ; env : (string * string) list option
  ; timeout_s : float option
  ; redact : string list
  }

type result =
  { exit_code : int
  ; stdout : string
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

(** [run c] is [Ok] whenever the command ran, whatever its exit status. Use it
    only when a specific non-zero exit means something to the caller (for
    example kubectl's "not found"); otherwise use {!run_success}. *)
val run : ?echo:bool -> cmd -> (result, error) Result.t

(** [check r] turns a [run] result into a success result: [Ok] only for exit 0,
    and [Error (Non_zero _)], carrying the exit code and both streams, for any
    other exit (REFAC-116). *)
val check : (result, error) Result.t -> (result, error) Result.t

(** [run_success c] is [check (run c)]: [Ok] only when the command succeeded. *)
val run_success : ?echo:bool -> cmd -> (result, error) Result.t

(** [output c] is the stdout of a successful [c]. *)
val output : ?echo:bool -> cmd -> (string, error) Result.t

(** What a failed command said: its trimmed stderr, or its trimmed stdout when
    stderr is empty ("" when both are). For the [Non_zero] branch of a checked
    result. *)
val failure_output : stdout:string -> stderr:string -> string

(** [run_ok c] is [run_success c] without its output. *)
val run_ok : ?echo:bool -> cmd -> (unit, error) Result.t

val run_shell : ?echo:bool -> string -> (result, error) Result.t
val error_to_string : error -> string

(** Print [argv] as the command line Sol is about to run, with each of [redact]
    replaced by [***]. *)
val echo_cmd : string list -> string list -> unit
