(** Local port-forwards Sol starts for `sol local infra up` and `sol up`
    (REFAC-126). Sol records each forward it starts and asks the record; a
    forward is running exactly while its wrapper holds the forward's lock, so
    nothing reads other processes' command lines and a reused pid is never
    mistaken for a forward. *)

type spec =
  { name : string
  ; namespace : string
  ; target : string
  ; local_port : int
  ; remote_port : int
  }

(** [write_record pf] records that Sol started [pf]; [start] does this first. *)
val write_record : spec -> (unit, string) result

(** Every forward Sol has a record of, and the records it could not read (each
    with why), so a corrupt record is reported rather than skipped. *)
val records : unit -> spec list * string list

(** [is_running name]: the forward's lock is held -- its wrapper or kubectl is
    alive. *)
val is_running : string -> bool

(** [stop name] signals the forward's whole process group, only while its lock
    is held, and removes its record. *)
val stop : string -> unit

val stop_all : unit -> unit

(** Records [pf], writes a self-restarting wrapper script pinned to [ctx]'s
    context, and starts it in its own session. *)
val start : ctx:Sol_cli_kube_destination.context -> spec -> (unit, string) result

type liveness =
  | Alive
  | Dead of
      { log : string
      ; log_tail : string list (** the log's last lines; [[]] when it has none *)
      }

(** Gives a just-started forward 200 ms, then says whether it is alive, and if
    not, where its log is and what it said last. *)
val check_alive : name:string -> liveness

(** The forwards Sol started on [local_port] for a different namespace or target,
    stopped so a new one can bind, and returned so the caller can say so. A
    process Sol did not start is never touched. *)
val replace_conflicting : local_port:int -> namespace:string -> target:string -> spec list
