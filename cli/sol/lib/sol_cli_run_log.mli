(* Per-invocation run-log directory for noisy subprocess output (Terraform,
   Helm, Docker, kubectl). Normal command output stays compact — one line
   per phase; the full log goes to a file under [base_dir] and is only
   printed (tailed) when that phase fails. *)

(** [<Sol_cli_state.dir>/runs] — the parent of every run directory. *)
val base_dir : string

(** [generate_run_id ~prefix ~now ~pid] builds a run id from a Unix timestamp
    and pid so it's both unique and lexicographically sortable (chronological).
    Exposed for testing; [create] supplies real values. *)
val generate_run_id : prefix:string -> now:float -> pid:int -> string

(** Last [n] lines of [s], or all of [s] if it has [n] lines or fewer. *)
val tail_lines : n:int -> string -> string

(** The full log file content written for one phase: stdout, then stderr if
    non-empty. *)
val phase_log_content : stdout:string -> stderr:string -> string

(** The compact one-line status printed for every phase, success or not. *)
val format_phase_line : name:string -> elapsed_s:float -> ok:bool -> string

(** The block printed after a failing phase: the run id, where the full log
    lives, and its tail. Including the run id here is what lets someone recover
    a deploy after the terminal that ran it is gone. *)
val format_failure_report : run_id:string -> log_path:string -> tail:string -> string

(** Given all existing run ids (lexicographically sortable timestamps) and how
    many to [keep], returns the ids that should be pruned (oldest first). Pure —
    [create] uses this to decide what to delete. *)
val runs_to_prune : all_run_ids:string list -> keep:int -> string list

type t

(** Create a fresh run directory under [base_dir], named
    [<prefix>-<timestamp>-<pid>], and prune old run directories beyond [keep]
    (default 20). *)
val create : ?keep:int -> prefix:string -> unit -> t

(** The run's id and directory, so a command can print them at the start rather
    than only when something fails. *)
val run_id : t -> string

val dir : t -> string

(** Path to a phase's log file within this run's directory. *)
val phase_log_path : t -> phase:string -> string

(** Append [text] to a phase's log, creating it if needed. Use it to record
    diagnostics a phase produced outside [run_phase]/[run_task], such as the
    rendered plan it acted on. *)
val append_phase_log : t -> phase:string -> string -> unit

(** Run [thunk] as one named phase: writes its full output to
    [phase_log_path t ~phase:name], prints a compact one-line status, and — only
    on failure — prints the run id, the log path and its last 40 lines. Returns
    [thunk]'s result unchanged, so callers keep their existing success/failure
    handling.
*)
val run_phase
  :  t
  -> name:string
  -> (unit -> (Sol_cli_process.result, Sol_cli_process.error) result)
  -> (Sol_cli_process.result, Sol_cli_process.error) result

(** [run_task t ~name thunk] is [run_phase] for a phase that is not one
    subprocess: [thunk] returns [Ok v] or [Error msg], and [msg] becomes the
    phase's log content on failure. Same compact line and failure report, so the
    deploy path and the Terraform path share one run-log mechanism. *)
val run_task : t -> name:string -> (unit -> ('a, string) result) -> ('a, string) result
