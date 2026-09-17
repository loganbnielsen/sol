(** Production-profile preflight (FEAT-089): checks a plan's profile claim once,
    before any render/apply mutation, and fails closed.

    A guarantee is either established or unmet. There is no "unverified but
    accepted" outcome: a guarantee Sol cannot yet establish for any target is
    reported as unmet with {!Platform} responsibility, so selecting a profile can
    never produce a stronger claim than Sol can back (DEC-026). A plan with no
    profile passes without any check. *)

(** Who has to act to satisfy an unmet guarantee. [Platform] means Sol itself
    cannot establish it yet; no application or target change can. *)
type side =
  | Application
  | Target
  | Platform

type status =
  | Established
  | Unmet of side * string

type finding =
  { capability : Sol_cli_profile.capability
  ; side : side
  ; reason : string
  }

(** The real establishment check for one guarantee against the resolved target,
    the apply path this invocation would use, and the plan itself (FEAT-050's
    artifact guarantee is a property of the plan's resolved images). *)
val establish
  :  target:Sol_cli_config.target
  -> apply_mode:Sol_cli_release.apply_mode
  -> plan:Sol_cli_deployment_plan.t
  -> Sol_cli_profile.capability
  -> status

(** [check ~target ~apply_mode plan] evaluates every guarantee the plan's
    profile requires. [establish] defaults to {!establish} and is injectable so
    the passing path is testable while real guarantees remain unmet. *)
val check
  :  ?establish:(Sol_cli_profile.capability -> status)
  -> target:Sol_cli_config.target
  -> apply_mode:Sol_cli_release.apply_mode
  -> Sol_cli_deployment_plan.t
  -> (unit, Sol_cli_profile.t * finding list) result

val side_to_string : side -> string
val finding_to_string : finding -> string

(** The operator-facing refusal for a failed preflight. *)
val report : Sol_cli_profile.t -> finding list -> string
