(** What a `sol deploy` invocation deploys (REFAC-139, part C).

    Two steps, in the order the command runs them, so a bad selector fails
    before any target is loaded: {!select} resolves the scope and the supplied
    image references against the workspace; {!apply_target} then applies the
    resolved target -- it must be declared, and its [omit] list decides what the
    selection keeps (DEC-041). Both are pure, so the rules are testable without a
    workspace or a cluster. *)

type selection =
  { requested_scope : string
  ; resolved : Sol_cli_workload_selection.resolved
  ; image_refs : (string * string) list
    (** FEAT-050: [service_name -> repo@sha256:<digest>] for the services the
        scope selected. *)
  }

(** [select ~scope ~image_refs inventory]: the scope resolved against
    [inventory] (an empty selection is an error: a deploy never silently does
    nothing), and each [--image-ref] resolved against the selected services, so
    a typo or an ambiguous bare reference fails before the target is read. *)
val select
  :  scope:string option
  -> image_refs:(string option * string) list
  -> Sol_cli_manifest.service list
  -> (selection, string) result

(** What the deploy runs on, and what to tell the operator about how the target
    changed the selection. *)
type deployed =
  { services : Sol_cli_manifest.service list
  ; notes : string list
  }

(** [apply_target ~target ~config selection]. Refuses an undeclared target (a
    typo'd region must not inherit sol.yml's defaults and deploy anyway), an
    [--image-ref] naming a unit the target omits (it would be dropped silently),
    and a selection the target's [omit] empties. *)
val apply_target
  :  target:string
  -> config:Sol_cli_config.t
  -> selection
  -> (deployed, string) result

(** Why a deploy's plan could not be built: a refusal in Sol's words, or the
    profile preflight's findings, which the command renders as a report. *)
type plan_error =
  | Refused of string
  | Preflight of Sol_cli_profile.t * Sol_cli_profile_preflight.finding list

(** [plan ... services]: the deployment plan every path (dry run, [--emit-to],
    apply) acts on, built once, before any lease, cluster mutation or emitted
    file. Refuses [--secret-backend kubernetes-live] with [--emit-to] (it would
    write plaintext secrets into a GitOps repository), and runs the profile
    preflight (FEAT-089). *)
val plan
  :  workspace:string
  -> registry:string
  -> sha:string
  -> emit_to:string option
  -> secret_backend:Sol_cli_manifest.secret_backend
  -> config:Sol_cli_config.t
  -> facts:Sol_cli_workspace_model.t
  -> inventory:Sol_cli_manifest.service list
  -> requested_scope:string
  -> image_refs:(string * string) list
  -> Sol_cli_manifest.service list
  -> (Sol_cli_deployment_plan.t, plan_error) result
