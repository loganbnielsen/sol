type aws_outputs

val backend_config
  :  Sol_cli_config.target
  -> root:[ `Cloud | `Platform ]
  -> (string list, string) result

val aws_outputs_of_json : string -> (aws_outputs, string) result
val cluster_name : aws_outputs -> string
val provisioner_role_arn : aws_outputs -> string

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
