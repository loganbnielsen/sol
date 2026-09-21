type aws_outputs

val backend_config
  :  Sol_cli_config.target
  -> root:[ `Cloud | `Platform ]
  -> (string list, string) result

val aws_outputs_of_json : string -> (aws_outputs, string) result
val cluster_access_role_arn : aws_outputs -> string

(** GCP's cloud-root contract. A separate type rather than a relabelled
    [aws_outputs], because the two providers publish different facts: a GCP root
    names the project and region (every GCP API is addressed through them, and the
    cluster credential is derived from them) and names no role ARN, because a
    caller there impersonates a service account through short-lived credentials. *)
type gcp_outputs =
  { cluster_name : string
  ; project_id : string
  ; region : string
  ; artifact_registry : string
  ; loki_gcs_bucket : string option
  ; loki_workload_identity_sa_email : string option
  ; thanos_gcs_bucket : string option
  ; thanos_workload_identity_sa_email : string option
  ; provisioner_service_account : string
  }

val gcp_outputs_of_json : string -> (gcp_outputs, string) result

(** Either provider's outputs. This is the whole of "provider-neutral" at this
    layer: the lifecycle carries one, and the provider-shaped facts are read
    through the branch that knows which it has. *)
type cloud_outputs =
  | Aws_outputs of aws_outputs
  | Gcp_outputs of gcp_outputs

val cluster_name : cloud_outputs -> string

(* HARDEN-002 run 4, finding 12: the kubeconfig env the platform Terraform
   providers actually resolve. See the implementation for why all three names
   are needed. *)
val provisioner_kube_env : string -> (string * string) list

(** The provider-neutral facts a lifecycle operation needs from a target, plus the
    backend config each provider's roots expect. [cluster_access_role_arn] is
    [None] on a provider whose caller is not a role-assuming one -- the field is
    optional rather than empty so "names no role" and "names an empty role" cannot
    be confused. *)
type cloud_target =
  { target : Sol_cli_config.target
  ; cloud_backend : string list
  ; platform_backend : string list
  ; base_domain : string
  ; letsencrypt_email : string
  ; cluster_access_role_arn : string option
  }

val cloud_target : Sol_cli_config.target -> (cloud_target, string) result
val target : cloud_target -> Sol_cli_config.target
val cloud_backend : cloud_target -> string list
val platform_backend : cloud_target -> string list

(** The platform root for a provider, relative to the Sol home. The platform
    definition is shared; the root differs because a Terraform root's backend type
    is part of its own configuration. *)
val platform_root : Sol_cli_provider.t -> string

(** A resource address inside the platform root. A root that reaches the shared
    definition through a module addresses its resources through it, so the prefix
    is applied here rather than at each `-target`. *)
val platform_address : Sol_cli_provider.t -> string -> string

type platform_inputs

val platform_inputs : cloud_target -> cloud_outputs -> (platform_inputs, string) result

(** The platform definition's variables for this target. Fallible because a target
    can ask for a capability its provider's root cannot wire yet, and a refusal
    naming the gap is the honest answer there rather than a variable set that
    silently omits it. *)
val platform_terraform_vars : platform_inputs -> (string list, string) result

type plan_phase =
  | Plannable
  | Deferred of string

val platform_plan_phases
  :  cluster_exists:bool
  -> rbac_established:bool
  -> crds_established:bool
  -> plan_phase * plan_phase

type authorization =
  | Required
  | Forbidden

val provisioner_authorization_checks : (authorization * string list) list
val provisioner_authorization_established : can_i:(string list -> bool) -> bool

type readiness =
  | Established
  | Unmet of string

type platform_storage =
  { storage_class : string
  ; csi_driver : string
  }

(** The Kubernetes storage facts that are the cloud provider's rather than Sol's:
    the StorageClass the platform's durable volumes bind to, and the block-storage
    CSI driver that must back it. `Ready` asserts them, and the platform root has
    to agree with them, so they are data here rather than conditionals at each
    use. Exposed for the same reason [readiness_invocations] is: a test has to be
    able to derive "this cluster is converged for provider X" from the contract
    rather than restate it, or the test would agree with a wrong table. *)
val platform_storage : Sol_cli_provider.t -> platform_storage

(** Every readiness check, run against a live cluster. A check is [Established]
    only when its kubectl invocation succeeds *and* its output satisfies the
    check's own predicate — exit status alone is not evidence.

    The checks assert the platform's convergence from authoritative Kubernetes
    state and take the target's provider, because the storage assertion is the
    one that is the provider's rather than Sol's: the class that is the sole
    default, backed by the provider's block-storage CSI driver. See the
    implementation for why probing the platform across the network, and any
    external ACME round trip, are deliberately absent from what gates [Ready]. *)
val readiness
  :  provider:Sol_cli_provider.t
  -> run:(string list -> string option)
  -> (string * readiness) list

(** The kubectl invocations [readiness] runs, by check name, without running them.

    Exposed per provider because an invocation is otherwise only reachable
    through a live cluster, so an argv kubectl does not accept cannot be tested
    until a real install fails — which is how `rollout status … --all` shipped
    and made every platform report [Unmet] (INFRA-035). CI validates every
    provider's set against a real kubectl; nothing in production calls this. *)
val readiness_invocations : provider:Sol_cli_provider.t -> (string * string list) list

val readiness_summary : (string * readiness) list -> string

(* Lifecycle phases, authority and desired-state policy (ADR 0003). A phase is
   the operation/transition Sol is performing -- not infrastructure truth -- and
   it decides both the authority and the desired-state policy that apply. *)
type phase =
  | Absent
  | Cloud_bootstrap
  | Platform_installing
  | Ready
  | Platform_updating
  | Preparing_destroy
  | Destroying

type phase_policy =
  | Bootstrap
  | Installation
  | Production
  | Destroy

val policy_of_phase : phase -> phase_policy

(** The forward lifecycle relation: the edges of ADR 0003's diagram. It describes
    progressive establishment, so it rejects every edge that would move the target
    backwards. It is deliberately not the only way to enter a phase -- see
    [destruction_available]. *)
val transition_allowed : from:phase -> to_:phase -> bool

(** The abort edge (ADR 0003 invariant 6): whether a destroy may begin, or resume,
    from this phase. True for every phase that can hold infrastructure and false
    only for [Absent], so a failed or partially installed target is always
    destructible. Separate from [transition_allowed] on purpose: destruction is
    teardown, not a forward transition, and folding it into the relation would
    stop the relation from meaning "the diagram". *)
val destruction_available : phase -> bool

(** [enter_destruction ~from] is the phase a destroy operation proceeds in:
    [Preparing_destroy] from any destructible phase, and [Absent] from [Absent]
    (the post-destroy state), which is what makes destroy idempotent. Total -- it
    has no failure case, because no observation may be able to block teardown. *)
val enter_destruction : from:phase -> phase

val ready_policy_applies : phase -> bool

(** What a destroy deliberately keeps (DEC-033). Production retention must be
    explicit -- what survives, why, and how it is eventually removed -- while a
    disposable qualification target's postcondition is [Absent], with nothing
    billable left behind. The default is [Retain_final_snapshot]: a qualification
    run retaining nothing must not become "Sol destroys every recovery artifact". *)
type destroy_retention =
  | Retain_final_snapshot
  | Retain_nothing

val default_destroy_retention : destroy_retention
val destroy_retention_to_string : destroy_retention -> string
val destroy_retention_of_string : string -> (destroy_retention, string) result

(** What the destroy says afterwards, by identifier, so an operator never has to
    infer what survived. *)
val retention_report : retention:destroy_retention -> destroy_snapshot_id:string -> string

(** The desired-state overrides a phase imposes, appended *after* the caller's own
    variables so the phase policy wins. The levers are the provider's: AWS lifts RDS
    deletion protection and names its final snapshot, and GCP lifts Cloud SQL's and
    the GKE cluster's. Deletion protection (a guard on a resource that exists) and
    retention (DEC-033: what a destroy deliberately keeps) are separate things, and
    this carries only the former. *)
val policy_vars
  :  provider:Sol_cli_provider.t
  -> phase:phase
  -> destroy_snapshot_id:string
  -> retention:destroy_retention
  -> (string * string) list

(** ADR 0003's own spelling of a phase, for operator-facing messages. *)
val phase_to_string : phase -> string

(** [observed_phase ~cloud_exists ~platform_installed] is the phase a target is
    actually in, recomputed from observation on every run: [Absent] when the
    cloud substrate does not exist, [Ready] when an earlier run completed the
    platform install, and [Platform_installing] otherwise. Never persisted. *)
val observed_phase : cloud_exists:bool -> platform_installed:bool -> phase

(** DEC-040 / FND-0021: whether the effective authorization surface shows the
    bootstrap capability is gone.

    The probe must be run as **the principal whose elevation is being removed**. A
    different principal answering establishes nothing about that one -- FND-0021's
    whole shape is a revocation reported complete while the capability remained
    usable, and probing elsewhere would reproduce exactly that error. *)
type deescalation_principal =
  | Principal_confirmed of string
  | Principal_refused_by_cluster of string
  | Principal_probe_failed of string
  | Principal_unexpected of string

type deescalation_verdict =
  | Deescalated
  | Still_elevated of string list
  | Undetermined of string

(** [probes] is (capability, still_permitted) as answered by the *authorizer* -- the
    component that enforces the boundary -- for the capabilities only the bootstrap
    authority held.

    - [Principal_unexpected] is [Undetermined]: the probe proves nothing.
    - [Principal_cannot_authenticate] is [Deescalated]: the elevated capability needs
      cluster authentication, so its absence is its revocation.
    - Otherwise any permitted capability is [Still_elevated], an empty probe list is
      [Undetermined] (never [Deescalated]), and only a confirmed principal with no
      permitted capability is [Deescalated]. *)
val deescalation_verdict
  :  principal:deescalation_principal
  -> (string * bool) list
  -> deescalation_verdict

(** DEC-040's positive control: [Deescalated] only when the *same* principal is observed
    permitted the bootstrap-only capabilities inside the bootstrap window and denied them
    afterwards.

    A final denial alone proves nothing -- a credential that never worked, a different
    principal, or a capability that was never granted all look identical afterwards. So:

    - the bootstrap capabilities were never observed permitted -> [Undetermined];
    - a different principal answered after de-escalation -> [Undetermined];
    - the post-de-escalation probe obtained no evidence -> [Undetermined];
    - the same principal, permitted before and denied after -> [Deescalated];
    - still permitted after -> [Still_elevated]. *)
val deescalation_transition
  :  before:(string * bool) list
  -> after_principal:deescalation_principal
  -> after:(string * bool) list
  -> deescalation_verdict

(** The principal from `kubectl auth whoami -o json`, parsed rather than
    pattern-matched. [Error] when the response is not JSON or carries no arn -- never a
    default, because a default would let a wrong principal look like a right one. *)
val principal_arn_of_whoami : string -> (string, string) result

val deescalation_verdict_to_string : deescalation_verdict -> string

(** [enter ~from ~to_] is the only way an operation may move between phases. It
    is [Error] for any edge [transition_allowed] rejects, so an illegal phase
    combination cannot be expressed by a call site (ADR 0003 invariant 5). *)
val enter : from:phase -> to_:phase -> (phase, string) result
