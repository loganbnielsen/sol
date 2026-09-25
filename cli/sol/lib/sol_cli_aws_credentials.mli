(** Credentials for a lifecycle operation that may run for hours (INFRA-039).

    Sol resolves provider credentials per operation rather than inheriting whatever
    the environment held when it started, and reports the principal it resolved so
    a stage is attributable to an identity. See the implementation for why this is
    the answer rather than longer-lived credentials. *)

type t =
  { access_key_id : string
  ; secret_access_key : string
  ; session_token : string option
  ; principal : string
  }

(** Reads the three variables out of `aws configure export-credentials --format env`
    output. Exposed for testing: the parsing is the part most likely to rot. *)
val parse_env_format : string -> (string * string * string option) option

(** Resolve credentials for [profile] through the AWS CLI, so the CLI performs any
    refresh the provider SDK cannot. [Error] carries a short reason; the caller
    turns it into an operator-facing message with {!unresolved_message}. *)
val resolve
  :  run:(string list -> string option)
  -> profile:string option
  -> (t, string) result

(** Install resolved credentials into Sol's own environment, so every child
    process (terraform, aws, kubectl) inherits credentials known to be valid now.
    The platform's provider blocks pin no profile, so environment credentials are
    what the AWS SDK uses. *)
val install : t -> unit

(** The operator-facing failure. [leaves_target_standing] adds the part that
    matters most: a destroy that cannot authenticate leaves billable
    infrastructure standing and disables the only supported path to remove it. *)
val unresolved_message
  :  operation:string
  -> profile:string option
  -> leaves_target_standing:bool
  -> detail:string
  -> string
