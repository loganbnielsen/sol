(** Production profiles (DEC-026): a target's explicit, versioned claim to a
    production contract. A profile is selected by a target, never implied by an
    environment name, and describes what a (target, evidence) pair must
    establish — not the content of a release.

    Exactly one profile exists. This module is the vocabulary only: identity,
    the guarantees a profile requires, and which of them a given plan's workloads
    make applicable. Establishing a guarantee is {!Sol_cli_profile_preflight}'s
    job. *)

type t = Production_single_region

(** The profile's contract version. It changes only when what "conformant"
    means changes (DEC-026's versioning rule). *)
val version : t -> int

(** The versioned identity recorded in plans, deployment events and conformance
    evidence, e.g. ["production-single-region/v1"]. *)
val to_string : t -> string

(** Inverse of {!to_string}. An unknown profile or version is an error, never a
    weaker or stronger claim than the one written. *)
val of_string : string -> (t, string) result

(** Parses the unversioned name a target selects in its target file
    ([profile: production-single-region]). *)
val of_selection : string -> (t, string) result

(** A guarantee a profile requires, named as a platform capability. *)
type capability =
  | Qualified_substrate (** A provider/substrate the profile is qualified on. *)
  | Qualified_versions (** The exact qualified Kubernetes/component/framework set. *)
  | Direct_apply_authority (** Sol's direct apply owns reconciliation (DEC-027). *)
  | Remote_state (** Encrypted, locked, recoverable infrastructure state. *)
  | Scoped_operator_identities
  (** Named identities separate from cluster-creator admin. *)
  | Alert_delivery (** A routed, owned alert receiver. *)
  | Immutable_artifacts (** Workloads are deployed by resolved digest. *)
  | Credential_posture (** No ambient workload credentials; rotatable secrets. *)
  | Workload_availability (** Declared failure tolerance and honest readiness. *)
  | Postgres_durability (** Postgres high availability and restore. *)
  | Kafka_durability (** Replicated, quorum-safe topics. *)

(** Stable machine name, e.g. ["immutable_artifacts"]. *)
val capability_to_string : capability -> string

(** Human description of the guarantee, e.g. ["immutable artifact identity"]. *)
val capability_description : capability -> string

(** What a plan's workloads use. A guarantee applies only when the workload uses
    the corresponding capability (DEC-026). *)
type usage =
  { long_running_workloads : bool (** Any service or worker. *)
  ; postgres : bool
  ; kafka : bool
  }

(** The guarantees [t] requires for [usage], in a fixed order. *)
val requirements : t -> usage -> capability list
