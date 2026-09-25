(** The destroy execution core (HARDEN-004 steps 2-5; REFAC-091).

    A typed inventory of what Terraform's state representation owns, plus a
    result-returning destroy sequence with every provider operation injected
    through {!deps}. The sequence never exits; the caller owns the process exit
    (see {!exit_code}). The elevated bootstrap access is bracketed around the one
    operation that uses it, so its removal cannot be skipped by a failing branch
    (FND-0047).

    Step 4 adds the *consequence* of a failed preparation: the preparation declares,
    through {!Sol_cli_cloud_lifecycle.failure_policy}, whether its failure permits
    destruction to continue (best-effort) or must block it (an explicit
    destruction-time safety guarantee the target declared, DEC-033). Destruction
    remains available from a half-built target unless proceeding would violate such
    a guarantee.

    Step 5 adds the *evidence*: success is no longer "the sequence reached its
    end", it is "every required postcondition was positively established from the
    provider and from Terraform state" ({!Sol_cli_destroy_verification}). An
    UNKNOWN observation is a failure, never a degraded success. *)

type resource =
  { address : string (** The real Terraform address, module prefix included. *)
  ; kind : string (** The provider resource type. *)
  ; name : string option
    (** The resource's `name` attribute as Terraform recorded it; the residue checks
        name the cluster and network they refer to from it. *)
  ; identifier : string option
    (** The `identifier` attribute where there is one (the RDS instance), for the
        retain-nothing retention check only. No generic provider identity is kept:
        Sol does not re-verify what Terraform manages (DEC-045 / REFAC-094). *)
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
  | Platform_destroy_failed of string
  | Substrate_destroy_failed of string
  | Verification_failed of string
  | Elevated_access_not_removed of string

(** What the destruction ultimately did.

    [Destroy_succeeded] with no [degradations] is the clean history.
    [Destroy_succeeded] with [degradations] is a different one: a
    [Continue_to_destroy] preparation failed or its plan was refused, destruction
    proceeded anyway, and absence was still reached -- both end at absence, and
    they are not the same run.

    [Destroy_blocked] means a [Block_destroy] preparation failed, so destruction
    did not run: proceeding would have violated an explicit destruction-time
    guarantee the target declared (DEC-033). The guarantee is named. There is no
    cleanup to report -- a block happens before the elevated-access bracket is ever
    entered -- so the outcome carries none.

    [Destroy_failed] means destruction did not reach its postcondition; it carries
    [degradations] too, so a degraded preparation is preserved even when a later
    step fails, and a cleanup failure is evidence alongside the primary failure
    rather than a replacement for it.

    Step 5 adds one *dimension* rather than a fifth outcome: [verification] is the
    observed evidence that justifies -- or refuses to justify -- the claim of
    absence. It is required on [Destroy_succeeded] (success now *is* "every
    required postcondition was positively established") and [None] on
    [Destroy_failed] exactly when the run never reached the verification stage. A
    `Block_destroy` block reaches neither: destruction did not happen, so there is
    no postcondition to verify. *)
type outcome =
  | Destroy_succeeded of
      { preparation : preparation
      ; degradations : string list
      ; substrate : substrate_presence
      ; cleanup : cleanup
      ; verification : Sol_cli_destroy_verification.observation
      }
  | Destroy_blocked of { guarantee : string }
  | Destroy_failed of
      { failure : failure
      ; degradations : string list
      ; cleanup : cleanup
      ; verification : Sol_cli_destroy_verification.observation option
      }

val failure_message : failure -> string

(** The exit-code contract (HARDEN-004 step 4): [0] only when every applicable
    preparation succeeded or had nothing to do *and* the destroy reached and
    verified absence; [3] when it reached absence with a [Continue_to_destroy]
    preparation degraded; [1] for a failed or blocked destroy. [2] is reserved for
    this CLI's refusal / cannot-proceed-as-requested semantics. *)
val exit_clean : int

val exit_degraded : int
val exit_failure : int
val exit_code : outcome -> int

type deps =
  { require_credentials : unit -> (unit, string) result
  ; terraform_init : unit -> (unit, string) result
  ; observe_state : unit -> (string, string) result
    (** [Ok stdout] of `terraform show -json`, or [Error] when the read failed. *)
  ; cloud_outputs : unit -> outputs_read
  ; prepare : state:state_read -> preparation Sol_cli_cloud_lifecycle.preparation_outcome
    (** The preparation declares the consequence of its own failure (DEC-033), so
        this is not a [result]: only [Block_destroy] stops destruction, and
        everything else is a degradation the sequence carries and reports. *)
  ; reconcile_and_enable : unit -> (unit, string) result
    (** Obtain the bootstrap authority and reconcile the guarded resources in one
        asserted apply. A failure means the authority was not obtained, so the
        operation the window authorises cannot run -- the protected operation is
        skipped and reported as a degradation, while the substrate destroy, which
        needs no cluster authority, proceeds. *)
  ; destroy_platform : unit -> (unit, string) result
  ; remove_elevated_access : unit -> (unit, string) result
  ; observe_window_before : unit -> (unit, string) result
  ; verify_window_after : unit -> (unit, string) result
  ; destroy_substrate : unit -> (unit, string) result
  ; verify_destruction :
      pre_destroy:state_read
      -> preparation:preparation
      -> Sol_cli_destroy_verification.observation
    (** Step 5's one observation (narrowed by DEC-045): a fresh read of the
        disposable root's own state, residue Terraform does not own, and retention.
        Not a [result]: every evidence leg is itself three-valued, and composing
        them is {!Sol_cli_destroy_verification.classify}'s job. *)
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
