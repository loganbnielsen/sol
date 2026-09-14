(** FEAT-063: every operation is scoped to an explicit destination.

    Each function takes the destination-side {!Sol_cli_kube_destination.context}
    and applies it once — [--context], plus [KUBECONFIG] when a kubeconfig is
    scoped. No call inherits kubectl's current context, and because the parameter
    is required, a call site cannot compile without saying which cluster it
    reaches. *)

val apply
  :  ctx:Sol_cli_kube_destination.context
  -> file:string
  -> (unit, Sol_cli_process.error) result

val apply_dry_run
  :  ctx:Sol_cli_kube_destination.context
  -> file:string
  -> (unit, Sol_cli_process.error) result

val get
  :  ctx:Sol_cli_kube_destination.context
  -> resource:string
  -> name:string
  -> namespace:string
  -> output:string
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val get_raw
  :  ctx:Sol_cli_kube_destination.context
  -> args:string list
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val logs
  :  ctx:Sol_cli_kube_destination.context
  -> pod:string
  -> namespace:string
  -> container:string option
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val rollout_status
  :  ctx:Sol_cli_kube_destination.context
  -> kind_name:string
  -> namespace:string
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val rollout_restart
  :  ctx:Sol_cli_kube_destination.context
  -> kind:string
  -> namespace:string
  -> (Sol_cli_process.result, Sol_cli_process.error) result

val patch
  :  ctx:Sol_cli_kube_destination.context
  -> resource:string
  -> name:string
  -> namespace:string
  -> patch_type:string
  -> patch:string
  -> (Sol_cli_process.result, Sol_cli_process.error) result

(** [create] returns the raw result: a non-zero exit is not folded into an
    error, because the boundary lease (FEAT-072) uses kubectl's "AlreadyExists"
    as its atomic acquire signal and that outcome is not a failure of the call
    itself. *)
val create
  :  ctx:Sol_cli_kube_destination.context
  -> file:string
  -> (Sol_cli_process.result, Sol_cli_process.error) result

(** [replace ?resource_version] returns the raw result; [--resource-version]
    turns the write into an optimistic compare-and-swap, so a lease held by a
    live holder cannot be overwritten by a stale take-over candidate. *)
val replace
  :  ctx:Sol_cli_kube_destination.context
  -> file:string
  -> ?resource_version:string
  -> unit
  -> (Sol_cli_process.result, Sol_cli_process.error) result

(** Delete an object, tolerating an absent one (["--ignore-not-found"]). *)
val delete
  :  ctx:Sol_cli_kube_destination.context
  -> resource:string
  -> name:string
  -> namespace:string
  -> (unit, Sol_cli_process.error) result

val probe : ctx:Sol_cli_kube_destination.context -> args:string list -> bool

(** The same probe, but keeping what kubectl said: the exit code and the reason
    a human should see (stderr when present, else stdout). [Error] means kubectl
    could not be run at all, which is a different failure from running and
    failing. Bounded by a timeout, and non-interactive because the runner gives
    children /dev/null on stdin. *)
val probe_result
  :  ctx:Sol_cli_kube_destination.context
  -> args:string list
  -> (int * string, string) result
