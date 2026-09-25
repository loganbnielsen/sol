(** What `sol cloud destroy` is justified in claiming happened (HARDEN-004 step 5,
    narrowed by DEC-045 / REFAC-094).

    For resources Terraform is configured to delete, a successful `terraform
    destroy` plus an empty state is the authority for absence (DEC-045), so this
    module does not re-query them and does not model provider identity.
    Independent provider inventories belong to qualification. Three legs remain,
    each for something Terraform's destroy cannot speak for: the post-destroy state
    itself, residue Terraform does not own, and retention. UNKNOWN is never read as
    absence.

    The module is pure: the caller runs every query and hands in what it
    returned. *)

(** What running a provider query returned. [Unavailable] is "nothing was asked"
    -- a missing tool is never absence. *)
type lookup_result =
  | Answered of
      { status : int
      ; stdout : string
      ; stderr : string
      }
  | Unavailable of string

(** Independent post-destroy Terraform-state observation. The caller supplies
    [Ok addresses] from a fresh read of the *disposable* root's own state ([Ok []]
    is the empty state); [Error] is UNKNOWN. *)
type state_evidence =
  | State_absent
  | State_residue of string list
  | State_unreadable of string

val state_evidence : (string list, string) result -> state_evidence

(** Residue Terraform does not own (DEC-045 classes 1 and 4). [residues] are
    violations; [indeterminate] checks are reported and never read as absence. *)
type sweep =
  | Sweep_not_run
  | Sweep_ran of
      { residues : string list
      ; indeterminate : string list
      }

(** Retention as observed evidence. The payloads are the operator-facing sentence,
    because "what survives, why, and how it is eventually removed" are all part of
    the claim (DEC-033). *)
type retention =
  | Retention_required_and_observed of string
  | Retention_not_required of string
  | Retention_violated of string
  | Retention_unknown of string

(** The retention evidence classified and abbreviated, for diagnostics and test
    failures; {!report} prints the sentence itself. *)
val retention_to_string : retention -> string

(** [Pending] is the provider saying "not yet": the promised snapshot exists and
    has not reached the state the retention contract requires. The caller keeps
    observing for a bounded time; it is never reported as success. *)
type retention_probe =
  | Settled of retention
  | Pending of string

val final_snapshot_query : snapshot_id:string -> region:string -> string list
val instance_snapshots_query : instance:string -> region:string -> string list

(** The promised final snapshot must exist *and* be `available`; a provider answer
    about a different identifier is not evidence about this one. *)
val classify_final_snapshot
  :  declared:Sol_cli_cloud_lifecycle.destroy_retention
  -> snapshot_id:string
  -> lookup_result
  -> retention_probe

(** Retain-nothing: no manual or automated snapshot attributable to this
    destruction's database instance may remain. *)
val classify_instance_snapshots : lookup_result -> retention

(** gcloud's "this does not exist" wording, for the residue checks that ask gcloud.
    GCP answers 404 for a resource that is gone *and* for a project that is not
    visible, so a not-found whose subject names a project other than [project] is
    not absence (finding C). *)
val gcp_absence_message : ?project:string -> string -> bool

(** The combined evidence. *)
type observation =
  { state : state_evidence
  ; sweep : sweep
  ; retention : retention
  }

(** [violations] are postconditions with positive evidence against them;
    [unknowns] are required observations that could not be obtained. Both fail
    ([is_verified] demands both be empty), and they are not the same claim. *)
type verdict =
  { violations : string list
  ; unknowns : string list
  }

val classify : observation -> verdict
val is_verified : verdict -> bool
val verdict_message : verdict -> string

(** The operator-facing evidence report. *)
val report : observation -> string
