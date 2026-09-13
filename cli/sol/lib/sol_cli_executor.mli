(** Deployment executors — plan-in, side-effect-out.

    Each executor renders a [service_spec] to YAML via
    [Sol_cli_deployment_render.render_spec] and then dispatches to the
    appropriate apply or emit primitive. Command logic selects the executor; the
    executor owns the dispatch.

    FEAT-063: every executor takes the destination-side context, because
    applying is a Kubernetes operation. [Emit_to] writes files and touches no
    cluster, but keeps the same shape. *)

(** Summary of what was applied or emitted for a single service. *)
type result =
  { namespace : string
  ; name : string
  ; image : string
  }

type mode =
  | Dry_run
  | Emit_to of string
  | Apply

(** Apply to the cluster [ctx] names. In dry-run mode the rendered YAML is
    printed to stdout rather than applied. Pass [~image] indirectly via the spec;
    callers that need to show a push-registry image should override [spec.image]
    before calling. *)
val local
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> dry_run:bool
  -> Sol_cli_deployment_plan.service_spec
  -> result

(** Write manifests to [dir/<namespace>-<name>.yaml] for GitOps workflows. The
    directory is created if it does not already exist. When [~secret_backend] is
    [External_secrets _], an ExternalSecret CRD is emitted instead of a
    placeholder Kubernetes Secret. Returns [result] with [namespace] and [name]
    from the spec and [image] from the spec. *)
val gitops
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> dir:string
  -> ?secret_backend:Sol_cli_manifest.secret_backend
  -> Sol_cli_deployment_plan.service_spec
  -> result

(** [run_plan ~ctx ~mode ?env ?secret_backend services] renders all service specs
    upfront ([~env], the resolved deployment environment, is threaded into every
    spec's [env] manifest label — omit it when no target resolved one)
    (returning [Error msg] on the first render failure before any side effect),
    then executes according to [mode]:
    - [Dry_run] — prints rendered YAML to stdout; no kubectl called.
    - [Emit_to dir] — writes YAML files under [dir]; no kubectl called.
    - [Apply] — applies manifests to the cluster [ctx] names via kubectl. *)
val run_plan
  :  Sol_cli_execution.context
  -> mode:mode
  -> ?secret_backend:Sol_cli_manifest.secret_backend
  -> Sol_cli_deployment_plan.t
  -> (result list, string) Stdlib.result
