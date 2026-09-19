type aws_outputs

val backend_config
  :  Sol_cli_config.target
  -> root:[ `Cloud | `Platform ]
  -> (string list, string) result

val aws_outputs_of_json : string -> (aws_outputs, string) result
val cluster_name : aws_outputs -> string
val provisioner_role_arn : aws_outputs -> string

(* HARDEN-002 run 4, finding 12: the kubeconfig env the platform Terraform
   providers actually resolve. See the implementation for why all three names
   are needed. *)
val provisioner_kube_env : string -> (string * string) list

(** The provider-neutral facts a lifecycle operation needs from a target, plus the
    backend config each provider's roots expect. [provisioner_role_arn] is
    [None] on a provider whose caller is not a role-assuming one -- the field is
    optional rather than empty so "names no role" and "names an empty role" cannot
    be confused. *)
type cloud_target =
  { target : Sol_cli_config.target
  ; cloud_backend : string list
  ; platform_backend : string list
  ; base_domain : string
  ; letsencrypt_email : string
  ; provisioner_role_arn : string option
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

val platform_inputs : cloud_target -> aws_outputs -> (platform_inputs, string) result
val platform_terraform_vars : platform_inputs -> string list

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
val policy_vars : phase:phase -> destroy_snapshot_id:string -> (string * string) list

(** ADR 0003's own spelling of a phase, for operator-facing messages. *)
val phase_to_string : phase -> string

(** [observed_phase ~cloud_exists ~platform_installed] is the phase a target is
    actually in, recomputed from observation on every run: [Absent] when the
    cloud substrate does not exist, [Ready] when an earlier run completed the
    platform install, and [Platform_installing] otherwise. Never persisted. *)
val observed_phase : cloud_exists:bool -> platform_installed:bool -> phase

(** [enter ~from ~to_] is the only way an operation may move between phases. It
    is [Error] for any edge [transition_allowed] rejects, so an illegal phase
    combination cannot be expressed by a call site (ADR 0003 invariant 5). *)
val enter : from:phase -> to_:phase -> (phase, string) result
