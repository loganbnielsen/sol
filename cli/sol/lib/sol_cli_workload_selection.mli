(** Workload selection: the one bridge between discovery and deployment scope
    (FEAT-065).

    A command that accepts [--scope] resolves the string exactly once, here,
    against the workloads discovery found. The result carries both facts the
    plan and, later, a release record need: the *requested* scope (intent) and
    the *resolved* services (exact membership). After resolution no command sees
    a selector string again, so commands cannot disagree about what a name
    means. *)

(** A resolved selection. [services] is empty exactly when the request matched
    nothing; whether that is an error is the caller's policy, not the
    selector's. *)
type resolved =
  { request : Sol_cli_deployment_scope.request
  ; scope : Sol_cli_deployment_scope.t
  ; services : Sol_cli_manifest.service list
  }

(** Adapt discovered services to the neutral vocabulary the resolver matches
    against. Exposed so a command can resolve without inventing a second
    adaptation. *)
val named_of_services
  :  Sol_cli_manifest.service list
  -> Sol_cli_deployment_scope.named list

(** [resolve ~what scope_value services] parses and resolves [scope_value]
    (absent or blank meaning the whole workspace) against [services], failing
    closed with what exists when it names something that does not.

    [what] names the flag in the error text (default ["--scope"]). *)
val resolve
  :  ?what:string
  -> string option
  -> Sol_cli_manifest.service list
  -> (resolved, string) result

(** [is_empty resolved] is [true] when resolution matched no workload. *)
val is_empty : resolved -> bool

(** The result of applying the target's [omit] declarations to a resolved
    selection (DEC-041). [selected] and [excluded] partition the resolved services,
    so nothing is dropped without being reported; [included] is a subset of
    [selected] naming what the target omits and the scope named back in. *)
type omission =
  { selected : Sol_cli_manifest.service list (** What the run should actually deploy. *)
  ; excluded : Sol_cli_manifest.service list
    (** Omitted by the target, and not named by the scope: dropped, and the caller
        should say so. *)
  ; included : Sol_cli_manifest.service list
    (** Omitted by the target but named by a unit-level `--scope`: included, and
        the caller should say so. *)
  }

(** [apply_omission ~is_omitted resolved] decides what the target's [omit]
    declarations do to a resolved selection. Pure, so the rule is testable without
    a workspace.

    The request kind is the whole point: a bare `--scope <domain>` (or no scope at
    all) never names a unit, so an omitted one is excluded rather than swept back
    in, while `--scope <domain>/<name>` is explicit intent about that unit and may
    include it — reporting that it did. Placement does not affect
    [is_omitted]'s meaning: it is already resolved to an absolute predicate over
    services, so a unit-level scope cannot be "defeated" by how names were written
    (DEC-036). *)
val apply_omission : is_omitted:(Sol_cli_manifest.service -> bool) -> resolved -> omission
