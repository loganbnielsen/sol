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
  ; guarded_removals : string list
    (** Terraform resource types whose removal on this path discards data that
        re-applying cannot restore, so a plan that removes one is refused unless
        confirmed. The *provider* declares which types those are (AUDIT-POST-002);
        the sequence owns only the policy. A provider with no such type declares
        none, which is not the same as having AWS's. *)
  ; confirm_guarded_removal : bool
  ; confirmation_flag : string
    (** The flag that confirms such a removal, for the refusal text. The CLI owns the
        flag's spelling, so the sequence does not carry a provider's product name. *)
  ; apply_plan : unit -> (unit, failure) result (** Apply the saved plan. *)
  ; discard_plan : unit -> unit
  ; outputs : unit -> ('outputs option, string) result
  ; open_window : 'outputs -> ('control option, string) result
    (** The provider's gate on the opened window, and its positive control. *)
  ; platform_vars : 'outputs -> (string list, string) result
  ; cloud_ready : 'outputs -> (unit, string) result
  ; observe_disk_quota :
      'outputs -> (Sol_cli_disk_quota.observation option, string) result
    (** The provider's own reading of the disk quota governing the platform's storage class,
        taken after the cloud infrastructure exists and before the platform asks for a volume
        (INFRA-090). [Ok None] is a declared answer: this provider observes no such quota, and
        the sequence says so rather than treating silence as room. The comparison against
        Sol's declared minimum is the sequence's, not the provider's. *)
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
