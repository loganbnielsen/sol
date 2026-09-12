(** Sol_cli_command_request — typed CLI input records for [sol up] and
    [sol deploy].

    Each command's Cmdliner terms produce raw strings and option values. The
    [make] constructors below validate those raw values and return a typed
    request record (or an error) before any deployment logic runs.

    The command body pattern is:
    {[
      parse raw Cmdliner args
      → Sol_cli_command_request.{up,deploy}_request.make ...
      → call pipeline
    ]} *)

type execution_mode =
  | Dry_run
  | Apply

type deploy_action =
  | Deploy_dry_run of { emit_to : string option }
  | Deploy_emit_to of string
  | Deploy_apply

(** A validated request for [sol up]: build images and deploy to a local
    cluster. *)
type up_request =
  { scope : string option
    (** Raw [--scope] value: a domain or ["domain/unit"], resolved once in
          [cmd_up.ml] via [Sol_cli_workload_selection]. *)
  ; mode : execution_mode
  ; image_tag : string
  ; confirm_group_change : bool
  }

(** A validated request for [sol deploy]: deploy pre-built images (CI/CD path).
*)
type deploy_request =
  { target : string
    (** Deployment target path, [<env>/<provider>/<region>] — resolved via
          [Sol_cli_config.load_for_target]. Required: [sol deploy]'s positional
          target argument, matching [sol plan]'s existing convention. *)
  ; scope : string option
  ; action : deploy_action
  ; emit_plan_to : string option
  ; image_tag : string
  ; registry : string option
    (** Raw [--registry] value, unresolved. [None] means "use the target
          file's registry, or fail if it has none" — that resolution (no
          hardcoded local-registry fallback; [sol deploy] is always the
          customer-cluster path) happens in [cmd_deploy.ml] once the target
          loads, not here, since this constructor never touches
          [Sol_cli_config]. *)
  ; secret_backend : Sol_cli_manifest.secret_backend
  ; confirm_group_change : bool
  ; loki_push_url : string option
    (** Raw [--loki-push-url] value (OBS-037). [None] means "resolve the push
          URL from the target's observability backend" -- see
          [Sol_cli_deploy_event.resolve_push_url]. Only meaningful for a real
          apply (not [--dry-run]/[--emit-to], which push no deploy event at
          all). *)
  }

(** Validate raw Cmdliner values for [sol up] into an [up_request]. [git_sha] is
    a thunk so callers can inject a real or stub implementation. Returns
    [Error msg] if validation fails. *)
val make_up_request
  :  scope:string option
  -> dry_run:bool
  -> tag:string option
  -> confirm_group_change:bool
  -> git_sha:(unit -> string)
  -> (up_request, string) result

(** Validate raw Cmdliner values for [sol deploy] into a [deploy_request].
    [git_sha] is a thunk so callers can inject a real or stub implementation.
    Returns [Error msg] if validation fails — including [target] being empty
    (cmdliner's [required] should already prevent this, but this constructor
    doesn't assume its caller enforced that). *)
val make_deploy_request
  :  target:string
  -> scope:string option
  -> dry_run:bool
  -> emit_to:string option
  -> emit_plan_to:string option
  -> image_tag:string option
  -> registry:string option
  -> secret_backend:Sol_cli_manifest.secret_backend
  -> confirm_group_change:bool
  -> loki_push_url:string option
  -> git_sha:(unit -> string)
  -> (deploy_request, string) result
