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

type aws_target

val aws_target : Sol_cli_config.target -> (aws_target, string) result
val target : aws_target -> Sol_cli_config.target
val cloud_backend : aws_target -> string list
val platform_backend : aws_target -> string list

type platform_inputs

val platform_inputs : aws_target -> aws_outputs -> (platform_inputs, string) result
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

val readiness
  :  cluster_issuer:string
  -> observability_backend:string
  -> run:(string list -> string option)
  -> (string * readiness) list

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
val transition_allowed : from:phase -> to_:phase -> bool
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
