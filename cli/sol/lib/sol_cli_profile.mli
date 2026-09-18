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
  | Platform_capacity
  (** Enough capacity, after reserved node-failure headroom, to host the
      platform's own declared resource requirements (INFRA-030). *)
  | Workload_availability (** Declared failure tolerance and honest readiness. *)
  | Postgres_durability (** Postgres high availability and restore. *)
  | Kafka_durability (** Replicated, quorum-safe topics. *)

(** Stable machine name, e.g. ["immutable_artifacts"]. *)
val capability_to_string : capability -> string

(** Human description of the guarantee, e.g. ["immutable artifact identity"]. *)
val capability_description : capability -> string

(** A capability the plan's workloads positively use. Each must come from
    declared, language-neutral evidence: a workload's runtime shape says nothing
    about its dependencies. *)
type workload_capability =
  | Long_running (** A service or worker, the subject of availability tiers. *)
  | Postgres
  | Kafka

(** The guarantees [t] requires when the workloads use [uses]: the target-level
    guarantees always, plus one guarantee per used capability, in a fixed order. *)
val requirements : t -> workload_capability list -> capability list

(** The platform's own resource envelope, and the shape the profile recommends
    for it. These are kept apart on purpose: the envelope is the contract, the
    shape is one configuration that satisfies it comfortably. Both are data, and
    the offline tests pin them together so neither can drift silently. *)
type capacity_envelope =
  { largest_pod_vcpu : int
  ; min_vcpu_per_node : int
  ; min_memory_gib_per_node : int
  ; platform_vcpu : int
  ; platform_memory_gib : int
  }

type node_shape =
  { instance_type : string
  ; vcpu_per_node : int
  ; memory_gib_per_node : int
  ; nodes : int
  }

val platform_capacity_envelope : capacity_envelope
val recommended_node_shape : node_shape

(** Why [shape] cannot host the platform envelope once [headroom_nodes] are
    reserved for node-failure tolerance. Empty means it can. Conservative by
    design: it states per-node and post-headroom floors, not a schedule. *)
val capacity_shortfall
  :  envelope:capacity_envelope
  -> shape:node_shape
  -> headroom_nodes:int
  -> string list

(** [Ok ()] when [shape] satisfies the envelope with [headroom_nodes] reserved,
    otherwise [Error reason] naming the shortfall. *)
val satisfies_capacity
  :  envelope:capacity_envelope
  -> shape:node_shape
  -> headroom_nodes:int
  -> (unit, string) result

(** The provider variables that select [shape] (node instance types and sizes). *)
val node_shape_vars : node_shape -> (string * string) list
