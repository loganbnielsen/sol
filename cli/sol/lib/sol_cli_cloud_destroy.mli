(** The destroy execution core (HARDEN-004 step 2; REFAC-091).

    A typed inventory of what Terraform's state representation owns, plus a
    result-returning destroy sequence with every provider operation injected
    through {!deps}. The sequence never exits; the caller owns the process exit
    (see {!exit_code}). The elevated bootstrap access is bracketed around the one
    operation that uses it, so its removal cannot be skipped by a failing branch
    (FND-0047). *)

type resource =
  { address : string (** The real Terraform address, module prefix included. *)
  ; kind : string (** The provider resource type. *)
  ; provider_id : string option (** The provider's own id/self-link. *)
  ; project : string option (** GCP project or AWS account id. *)
  ; region : string option (** Region/location; a zone is reduced to its region. *)
  ; deletion_protection : bool option
    (** The provider's deletion guard; [None] is "no such attribute", not false. *)
  ; final_snapshot_identifier : string option
  ; skip_final_snapshot : bool option (** Retention-relevant state (AWS). *)
  }

(** One `terraform show -json` observation, classified. A missing `values` is
    [State_empty] (a valid absence); anything unparseable is [State_unreadable]
    (UNKNOWN), which is never absence. *)
type state_read =
  | State_empty
  | State_represented of resource list
  | State_unreadable of string

(** Three-valued substrate existence. [Substrate_unknown] exists so that folding
    an unreadable state into "absent" is unrepresentable. *)
type substrate_presence =
  | Substrate_present
  | Substrate_absent
  | Substrate_unknown

(** Parse a `terraform show -json` document into the typed inventory, walking
    the root module and every child module and retaining real addresses. *)
val inventory_of_show_json : string -> state_read

val resources : state_read -> resource list
val addresses : state_read -> string list
val substrate_presence : state_read -> substrate_presence
val find_address : state_read -> string -> resource option

(** What destruction preparation did, carried to the report. *)
type preparation =
  | Nothing_prepared
  | Aws_prepared of string
  | Gcp_prepared

(** The result of the elevated bootstrap-access window. *)
type cleanup =
  | Cleanup_not_needed
  | Cleanup_succeeded
  | Cleanup_failed of string

(** Whether the install-time outputs could be read. This only gates whether the
    platform teardown can be *wired*; it never decides whether the target exists. *)
type outputs_read =
  | Outputs_available
  | Outputs_unavailable of string

type failure =
  | Credentials_failed of string
  | Init_failed of string
  | Preparation_refused of string
  | Preparation_failed of string
  | Reconciliation_failed of string
  | Platform_destroy_failed of string
  | Substrate_destroy_failed of string
  | Verification_failed of string
  | Elevated_access_not_removed of string

type outcome =
  | Destroy_succeeded of
      { preparation : preparation
      ; substrate : substrate_presence
      ; cleanup : cleanup
      }
  | Destroy_failed of
      { failure : failure
      ; cleanup : cleanup
      }

val failure_message : failure -> string
val exit_code : outcome -> int

type deps =
  { require_credentials : unit -> (unit, string) result
  ; terraform_init : unit -> (unit, string) result
  ; observe_state : unit -> (string, string) result
  ; cloud_outputs : unit -> outputs_read
  ; prepare : state:state_read -> (preparation, string) result
  ; reconcile_and_enable : unit -> (unit, string) result
  ; destroy_platform : unit -> (unit, string) result
  ; remove_elevated_access : unit -> (unit, string) result
  ; observe_window_before : unit -> (unit, string) result
  ; verify_window_after : unit -> (unit, string) result
  ; destroy_substrate : unit -> (unit, string) result
  ; verify_absent : unit -> (unit, string) result
  ; report : string -> unit
  ; warn : string -> unit
  }

(** Run the destruction. Returns a typed {!outcome}; never exits. *)
val execute : deps:deps -> outcome

(** Phase allowlists for the destroy-path applies. Each apply is planned and
    classified against one of these before it runs; a change outside the list is
    refused and the apply is never invoked. See {!Sol_cli_terraform_plan}. *)

val guard_preparation_policy : addresses:string list -> Sol_cli_terraform_plan.policy

val bootstrap_enable_policy
  :  bootstrap:Sol_cli_terraform_plan.matcher list
  -> Sol_cli_terraform_plan.policy

val reconciliation_policy
  :  bootstrap:Sol_cli_terraform_plan.matcher list
  -> guarded:string list
  -> Sol_cli_terraform_plan.policy

val bootstrap_removal_policy
  :  bootstrap:Sol_cli_terraform_plan.matcher list
  -> Sol_cli_terraform_plan.policy
