(** Verifying destruction from observed provider/state evidence (HARDEN-004 step 5).

    Steps 2-4 established what destruction is *allowed* to do; this module
    establishes what Sol is justified in *claiming* happened. The governing rule
    is that failure to obtain evidence is not evidence of the desired
    postcondition, and its destruction-specific form is that a successful destroy
    command is not itself evidence that the target is absent.

    The module is pure: {!query_of} builds the provider argv from the *captured*
    pre-destroy identity, {!lookup_result} carries what running it returned, and
    {!classify} decides what the evidence establishes. Nothing here queries a
    provider, reads a clock or reads a file. *)

type identity =
  { address : string
  ; kind : string
  ; provider_id : string option
  ; arn : string option
  ; project : string option
  ; region : string option
  }

val region_of_arn : string -> string option
val account_of_arn : string -> string option

(** The provider's own short name for the object this identity points at (the last
    path segment of its id/self-link), or [None] when the captured identity does
    not carry one. *)
val object_name : identity -> string option

(** What running a provider query returned. [Unavailable] is "nothing was asked"
    -- a missing tool is never absence. *)
type lookup_result =
  | Answered of
      { status : int
      ; stdout : string
      ; stderr : string
      }
  | Unavailable of string

(** The provider's own "this does not exist" signal: AWS's typed error code, or
    gcloud's absence wordings (unstructured, so matched explicitly). *)
type not_found =
  | Aws_error_code of string
  | Gcp_absence_wording

type recipe =
  { identity : identity
  ; operation : string (** the exact query, for the operator *)
  ; argv : string list
  ; not_found : not_found
  }

type provider_verdict =
  | Present
  | Absent
  | Unknown of string

type provider_observation =
  { identity : identity
  ; operation : string
  ; status : int option
  ; evidence : string
  ; verdict : provider_verdict
  }

(** What can be asked about one captured identity. [No_recipe] is a *coverage*
    statement (the kind has no provider lookup, so its absence rests on
    {!state} alone and must be reported as such); [Identity_incomplete] is an
    observation that could not even be attempted, so it is UNKNOWN -- never
    absence, and never a silent skip. *)
type queryability =
  | Queryable of recipe
  | No_recipe of string
  | Identity_incomplete of string

val query_of : provider:Sol_cli_provider.t -> identity -> queryability
val classify_lookup : recipe -> lookup_result -> provider_verdict
val observation_of_lookup : recipe:recipe -> lookup_result -> provider_observation

(** The observation for an identity whose kind *is* queryable but whose captured
    fields are not enough: UNKNOWN, never a silent skip. *)
val unqueryable : identity -> reason:string -> provider_observation

(** Independent post-destroy Terraform-state observation. The caller supplies
    [Ok addresses] from a fresh read of the *disposable* root's own state ([Ok []]
    is the empty state); [Error] is UNKNOWN. *)
type state_evidence =
  | State_absent
  | State_residue of string list
  | State_unreadable of string

val state_evidence : (string list, string) result -> state_evidence

(** The name/tag-derived checks that used to *be* the verification, demoted to a
    secondary orphan sweep. [residues] are violations; [indeterminate] checks are
    reported and never read as absence; and neither can override a captured
    identity's evidence. *)
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
    destruction may remain, queried by the *captured* database instance
    identifier. *)
val classify_instance_snapshots : lookup_result -> retention

(** The same absence rule for a gcloud answer that has no {!recipe} of its own:
    the name-derived orphan sweep classifies with it, so the two cannot drift into
    two different spellings of "not found". [project] is the project the identity
    was captured in: GCP answers 404 for a resource that is gone *and* for a
    project that is not visible, so a not-found whose subject names another project
    is UNKNOWN rather than absence (finding C). *)
val gcp_absence_message : ?project:string -> string -> bool

(** The combined evidence. [unqueried] is not a failure and not a silence: it is
    the set of represented resources for which no provider lookup is defined (with
    the reason), whose absence therefore rests on {!state} alone. *)
type observation =
  { state : state_evidence
  ; identities : provider_observation list
  ; unqueried : (identity * string) list
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

(** The operator-facing evidence report (step 5 section 9): what was expected
    absent, the exact identity queried, the evidence returned and its
    classification, what Terraform state says, and what remains unproven. *)
val report : observation -> string
