(** Before a cloud command touches a Terraform state, the last operation against
    it decides whether it may (INFRA-076, REFAC-139). *)

type verdict =
  | Proceed
  | Warn of string (** proceed, and report this warning *)
  | Acknowledge of string
  (** the operator accepted an unresolved operation: record that, report this
      warning, and proceed *)
  | Refuse of string

(** [verdict ~constructive ~accept_unresolved status]. A running operation is
    never raced or unlocked. An unresolved one stops a constructive command
    (apply) unless the operator reconciled it and says so; a plan or a destroy
    proceeds with a warning, since neither constructs from the gap. A graceful
    Ctrl-C is [Resolved], not suspicious. *)
val verdict
  :  constructive:bool
  -> accept_unresolved:bool
  -> Sol_cli_supervised.status
  -> verdict

(** [check ~constructive ~accept_unresolved ~chdir ~backend_config]: read the
    previous operation against that state and act on its {!verdict}. *)
val check
  :  constructive:bool
  -> accept_unresolved:bool
  -> chdir:string
  -> backend_config:string list
  -> (unit, string) result
