type cmd = {
  argv    : string list;
  cwd     : string option;
  env     : (string * string) list option;
  timeout_s : float option;
  redact  : string list;
}

type result = {
  exit_code : int;
  stdout    : string;
  stderr    : string;
}

type error =
  | Spawn_failed  of string
  | Non_zero      of { exit_code : int; stderr : string }
  | Timeout       of float

val cmd : ?cwd:string -> ?env:(string * string) list -> ?timeout_s:float -> ?redact:string list -> string list -> cmd

val run       : ?echo:bool -> cmd -> (result, error) Result.t
val run_ok    : ?echo:bool -> cmd -> (unit,   error) Result.t
val run_shell : ?echo:bool -> string -> (result, error) Result.t

val error_to_string : error -> string
