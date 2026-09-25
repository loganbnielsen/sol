(** INFRA-076: run Terraform so that Sol cannot kill it abruptly.

    Terraform used to write into pipes only Sol read, in Sol's own process group.
    When Sol died -- SIGKILL, OOM, a crash, a closed terminal, or Ctrl-C, since Sol
    kept SIGINT's default action -- Terraform died of SIGPIPE at its next line of
    output, without its graceful stop: an in-flight create went unrecorded and the
    state lock stayed held.

    Now a small supervisor (this same binary, re-invoked as [__supervise]) runs in a
    session of its own and launches Terraform with its output going to durable
    files. The supervisor outlives Sol and records Terraform's outcome. Sol only
    reads the files and waits. On an interrupt (INT, TERM or HUP) Sol sends one
    SIGINT to Terraform's own pid -- never to its provider plugins, never by name --
    and keeps waiting while Terraform stops itself; a second interrupt is forwarded
    as Terraform's documented "cancel now". No timeouts, no SIGKILL, and no lock is
    ever unlocked.

    Every run leaves an operation record, so the next command can tell whether the
    previous one is still running, finished, or ended in a way Sol cannot vouch
    for. *)

(** How Terraform ended, as the supervisor recorded it. *)
type outcome =
  | Exited of int
  | Signaled of int

(** The previous operation against one Terraform state. *)
type status =
  | No_previous
  | Running of
      { pid : int
      ; host : string
      ; started_at : float
      ; dir : string
      }
  (** No outcome yet, and its supervisor or Terraform is alive on this host --
          or it was started on another host, where liveness cannot be checked. *)
  | Resolved of
      { outcome : outcome
      ; dir : string
      }
  (** Terraform completed its own protocol: an exit status was recorded
          (including a graceful non-zero exit after Ctrl-C) and it left no
          emergency state. *)
  | Unresolved of
      { reason : string
      ; dir : string
      } (** Sol cannot establish that Terraform completed its protocol. *)

(** The facts one classification rests on, observed from an operation record. *)
type facts =
  { recorded_outcome : outcome option
  ; same_host : bool
  ; alive : bool (** the supervisor or Terraform process is still running *)
  ; errored_state : string option (** path of a [errored.tfstate] the run left *)
  ; acknowledged : bool (** an operator accepted this Unresolved outcome *)
  ; pid : int
  ; host : string
  ; started_at : float
  ; dir : string
  }

(** Pure: the status the facts establish. A graceful non-zero exit is
    [Resolved]; only an unknown or abrupt ending, or an emergency state file, is
    [Unresolved]. *)
val classify : facts -> status

val status_to_string : status -> string

(** The operation record's directory for one Terraform state, under Sol's data
    home. [key] identifies the state (see {!Sol_cli_terraform.operation_key}). *)
val operations_dir : key:string -> string

(** The status of the latest operation recorded under [key]. *)
val latest : key:string -> status

(** Record that an operator accepted the latest [Unresolved] operation under
    [key], so later commands proceed. *)
val acknowledge : key:string -> unit

(** [run ~key ~root cmd] runs [cmd] under a supervisor, recording the operation
    under [key]; [root] is the Terraform working directory, where an
    [errored.tfstate] would be written. Returns Terraform's result as
    {!Sol_cli_process.run} would. [cmd]'s [timeout_s] is ignored: Terraform is
    never stopped by a timer. [supervisor] is the executable that answers
    [__supervise] (default: this one). *)
val run
  :  ?echo:bool
  -> ?supervisor:string
  -> key:string
  -> root:string
  -> Sol_cli_process.cmd
  -> (Sol_cli_process.result, Sol_cli_process.error) result

(** If this process was started as a supervisor ([argv.(1) = "__supervise"]),
    run the supervision and exit; otherwise return. Call it first thing in any
    executable that can be a [supervisor]. *)
val dispatch_if_supervisor : unit -> unit
