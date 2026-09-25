(** REFAC-091: the cloud apply as a result-returning sequence. The bootstrap
    window opens with the cloud apply; any failure while it is open removes it
    before the outcome is returned, and the removal the sequence performs itself
    is never retried as its own cleanup. Every provider-specific step is a
    dependency, and nothing here exits: the command edge maps the outcome to the
    process exit. *)

type failure =
  | Terraform_failed of string
  (** A Terraform command failed; the text is Terraform's own classification. *)
  | Refused of string (** Sol refused to continue; the text is the reason. *)

type outcome =
  | Applied
  | Apply_failed of
      { failure : failure
      ; cleanup : Sol_cli_cloud_destroy.cleanup
        (** Whether the bootstrap window had to be removed on the way out. *)
      }

type ('outputs, 'env, 'control) deps =
  { substrate_exists : unit -> (bool, string) result
    (** Whether the cloud substrate exists before this run; an error is unknown. *)
  ; plan : unit -> (Sol_cli_terraform_plan.change list, failure) result
    (** Save the cloud plan (bootstrap window enabled) and read its changes. *)
  ; confirm_ecr_removal : bool
  ; apply_plan : unit -> (unit, failure) result (** Apply the saved plan. *)
  ; discard_plan : unit -> unit
  ; outputs : unit -> ('outputs option, string) result
  ; open_window : 'outputs -> ('control option, string) result
    (** The provider's gate on the opened window, and its positive control. *)
  ; platform_vars : 'outputs -> (string list, string) result
  ; cloud_ready : 'outputs -> (unit, string) result
  ; with_cluster_access :
      'outputs -> ('env -> (unit, failure) result) -> (unit, failure) result
  ; platform_init : unit -> (unit, failure) result
  ; platform_installed : 'env -> bool
  ; apply_prerequisites : 'env -> string list -> (unit, failure) result
  ; await_crds : 'env -> bool
  ; apply_platform : 'env -> string list -> (unit, failure) result
  ; await_readiness : 'env -> (string * Sol_cli_cloud_lifecycle.readiness) list
  ; remove_bootstrap_access : unit -> (unit, failure) result
  ; verify_deescalation : 'outputs -> 'control option -> (unit, string) result
  ; provisioner_effective : 'env -> bool
  ; report : string -> unit
  }

val failure_to_string : failure -> string
val execute : deps:('outputs, 'env, 'control) deps -> outcome
