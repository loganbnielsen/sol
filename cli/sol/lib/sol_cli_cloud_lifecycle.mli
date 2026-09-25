val backend_config
  :  Sol_cli_config.target
  -> root:[ `Cloud | `Platform ]
  -> (string list, string) result

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

(** The shared platform inputs for [cluster], once the cluster has checked the
    identity its root reports against the one the target declared. *)
val platform_inputs
  :  cloud_target
  -> Sol_cli_cluster.t
  -> (platform_inputs, string) result

(** The platform definition's variables for this target. Fallible because a target
    can ask for a capability its provider's root cannot wire yet, and a refusal
    naming the gap is the honest answer there rather than a variable set that
    silently omits it. *)

type platform_vars_context = Sol_cli_cluster.platform_vars_context =
  | Install
  | Destruction

val platform_terraform_vars
  :  ?context:platform_vars_context
  -> platform_inputs
  -> (string list, string) result

(** What happens to destruction when a preparation fails. The preparation declares it, so the
    destruction path carries no growing list of provider exceptions: [Continue_to_destroy]
    for best-effort preparation, [Block_destroy] only where the failure stands for an
    explicit destruction-time safety guarantee the target declared (DEC-033). *)
type failure_policy =
  | Continue_to_destroy
  | Block_destroy

(** [Prepared] carries whatever the caller needs from a successful preparation. *)
type 'a preparation_outcome =
  | Nothing_to_prepare
  | Prepared of 'a
  | Preparation_failed of
      { reason : string
      ; policy : failure_policy
      }

(** The reason to report for a failed preparation, of either policy: a failure that permits
    destruction must still be visible in the result, not swallowed by it. *)
val preparation_failure : 'a preparation_outcome -> string option

(** [Some reason] only when destruction must not proceed. Nothing else blocks. *)
val destruction_blocked : 'a preparation_outcome -> string option

(** Which resources a destructive preparation may target: those the target's state already
    represents, i.e. [configuration INTERSECT state].

    This bounds what may be TARGETED, not what Terraform plans: [-target] pulls in
    dependencies and reconciles the whole resource, so a preparation must also assert on its
    plan before applying it -- only updates, only eligible addresses -- before the claim
    "nothing can be created during destruction" holds (FND-0030). *)
val preparations_eligible : state:string list -> desired:string list -> string list

(** The declared addresses the state does NOT hold. A destroy cannot reach these: Terraform
    destroys what its state knows about, so they may survive a successful destroy and remain
    billable. Reporting them is the minimum (FND-0030). *)
val preparations_unrepresented : state:string list -> desired:string list -> string list

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

type platform_storage = Sol_cli_provider_capabilities.platform_storage =
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

(** HARDEN-004 step 5 removed [retention_report]: retention is reported from
    observed evidence by {!Sol_cli_destroy_verification}, not rendered from the
    policy (FND-0046 / INFRA-072). *)

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

(** A single `kubectl auth can-i` answer. [Indeterminate] is **not** a denial: the
    probe obtained no usable answer (the API was unreachable, a token could not be
    minted, or the process failed for a reason other than the authorizer saying
    no). Folding those into [Denied] is the fail-open FND-0021 is about -- every
    capability reads as removed and the verdict reads as [Deescalated]. *)
type capability_answer =
  | Permitted
  | Denied
  | Indeterminate of string

type capability =
  { verb : string
  ; resource : string
  }

(** "verb resource", the form the capability is reported in. *)
val capability_label : capability -> string

(** Only an explicit [Permitted] is permitted; [Indeterminate] is not. *)
val answer_is_permitted : capability_answer -> bool

(** Classify a `kubectl auth can-i` result from its exit code and output.

    Real kubectl prints `yes`/`no` as the first token, and some versions append a
    reason after a denial (`no - no RBAC policy matched`), so only the first
    whitespace-delimited token is read. The token and the exit code must agree
    (`yes`/0, `no`/1); a mismatch is not an answer. Pure, so the decision is unit
    tested rather than only exercised through a shell stub. *)
val capability_answer_of_can_i_output
  :  exit_code:int
  -> stdout:string
  -> stderr:string
  -> capability_answer

(** The indeterminate reason for a probe, if it has one, labelled with its capability.
    Exposed so a caller can report *why* a window or a surface could not be
    established instead of only that it could not. *)
val indeterminate_reason : capability * capability_answer -> (string * string) option

(** [probes] is the *authorizer's* answer -- the component that enforces the
    boundary -- for the capabilities only the bootstrap authority held.

    - [Principal_unexpected] is [Undetermined]: the probe proves nothing.
    - [Principal_refused_by_cluster] is [Deescalated]: the elevated capability needs
      cluster authentication, so its absence is its revocation.
    - An [Indeterminate] answer, on any capability, is [Undetermined].
    - Otherwise any permitted capability is [Still_elevated], an empty probe list is
      [Undetermined] (never [Deescalated]), and only a confirmed principal with no
      permitted capability is [Deescalated]. *)
val deescalation_verdict
  :  principal:deescalation_principal
  -> (capability * capability_answer) list
  -> deescalation_verdict

(** DEC-040's positive control: [Deescalated] only when the *same* principal is observed
    permitted the bootstrap-only capabilities inside the bootstrap window and denied them
    afterwards.

    A final denial alone proves nothing -- a credential that never worked, a different
    principal, or a capability that was never granted all look identical afterwards. So:

    - a capability that was [Indeterminate] in the window -> [Undetermined], because a
      later denial of it would not demonstrate its removal;
    - the bootstrap capabilities were never observed permitted -> [Undetermined];
    - a different principal answered after de-escalation -> [Undetermined];
    - the post-de-escalation probe obtained no evidence -> [Undetermined];
    - the post-de-escalation probe did not cover a capability observed permitted
      during the window -> [Undetermined];
    - the same principal, permitted before and denied after -> [Deescalated];
    - still permitted after -> [Still_elevated]. *)
val deescalation_transition
  :  before:(capability * capability_answer) list
  -> after_principal:deescalation_principal
  -> after:(capability * capability_answer) list
  -> deescalation_verdict

(** The identity in a `kubectl auth whoami -o json` response (a SelfSubjectReview).

    On EKS the AWS authenticator reports these under `status.userInfo.extra`, where every
    value is an **array of strings** — including `arn` and `canonicalArn` — so the arn is
    not a plain field of `userInfo`. The flat string form is also accepted, because other
    authenticators and test stubs emit it. [Error] when the response is not JSON or names
    no principal at all: never a default, because a default would let a wrong principal
    look like a right one. *)
type whoami_identity =
  { arn : string option
  ; canonical_arn : string option
  ; username : string option
  ; source : string
    (** Which field the identity came from. The de-escalation comparison depends on
          canonicalArn, so a caller must be able to see whether it got that one. *)
  }

val whoami_identity_of_json : string -> (whoami_identity, string) result

(** The role name inside an ARN, whichever form it takes — handling the assumed-role form
    whose final segment is a *session* name, so two probes of the same principal do not
    read as a mismatch. *)
val role_name_of_arn : string -> string

(** The stable role name of an identity: `canonicalArn` first (a plain IAM role ARN), then
    `arn`, then the username. *)
val principal_role_name : whoami_identity -> string option

(** The path-free form canonicalArn reports, so an expected role ARN that carries a role
    path compares equal to the cluster's answer instead of producing a false mismatch. *)
val normalize_role_arn : string -> string

(** Whether the response names exactly the expected principal, compared as the full
    canonical ARN (account and path included). [None] when the response names no ARN.

    Strict on purpose: comparing an extracted role name fails *open* when the same role
    name appears in another account or behind a different role path. The strict form's
    worst case is a false mismatch, which the caller turns into [Undetermined]. *)
val principal_matches : expected:string -> whoami_identity -> bool option

(** Whether the probe's own credential could still be assumed. A named three-state
    rather than a [bool option], because "the role was refused" and "the assumption
    could not be attempted" are different diagnoses. *)
type credential_assumption =
  | Credential_assumable
  | Credential_refused
  | Credential_unchecked

(** A cluster refusal counts as de-escalation only when the credential is still good: a
    broken trust policy, clock skew or a wrong assumed role produces the same refusal as a
    revoked grant, and reading it as removal would be a fail-open into [Deescalated]. *)
val refusal_is_deescalation : credential_assumption -> string -> deescalation_principal

val deescalation_verdict_to_string : deescalation_verdict -> string

(** [enter ~from ~to_] is the only way an operation may move between phases. It
    is [Error] for any edge [transition_allowed] rejects, so an illegal phase
    combination cannot be expressed by a call site (ADR 0003 invariant 5). *)
val enter : from:phase -> to_:phase -> (phase, string) result
