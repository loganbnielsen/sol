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
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val get_raw
  :  ctx:Sol_cli_kube_destination.context
  -> args:string list
  -> (Sol_cli_process.output, Sol_cli_process.error) result

(** What kind of failure a kubectl error is (REFAC-125): a view onto the error for
    the callers that act on it, never a replacement for it -- render messages from
    the error, which keeps kubectl's own words. [No_resource_type]: the cluster
    does not serve the type at all (no CRD), an empty set to a caller that lists
    it. [Refused]: unauthenticated or forbidden. [Other]: nothing a caller acts
    on. *)
type reason =
  | Not_found
  | Already_exists
  | Conflict
  | No_resource_type
  | Refused
  | Other

(** [classify e] reads kubectl's status reason ("Error from server (<Reason>)")
    and the two client-side messages that have none. The one place kubectl's
    wording is known. *)
val classify : Sol_cli_process.error -> reason

(** [get_if_present ~ctx ~args] is a [kubectl get] (args start with ["get"]):
    [Ok None] when kubectl answers NotFound, [Ok (Some stdout)] when the object
    exists, and [Error] for every other failure -- a failed read is never
    absence (REFAC-125). *)
val get_if_present
  :  ctx:Sol_cli_kube_destination.context
  -> args:string list
  -> (string option, Sol_cli_process.error) result

val logs
  :  ctx:Sol_cli_kube_destination.context
  -> pod:string
  -> namespace:string
  -> container:string option
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val rollout_status
  :  ctx:Sol_cli_kube_destination.context
  -> kind_name:string
  -> namespace:string
  -> (Sol_cli_process.output, Sol_cli_process.error) result

(** Like {!rollout_status} but bounded by [timeout_s]
    ([kubectl rollout status --timeout=<n>s]), so a rotation that never becomes
    healthy fails instead of hanging. *)
val rollout_status_with_timeout
  :  ctx:Sol_cli_kube_destination.context
  -> kind_name:string
  -> namespace:string
  -> timeout_s:int
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val rollout_restart
  :  ctx:Sol_cli_kube_destination.context
  -> kind:string
  -> namespace:string
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val patch
  :  ctx:Sol_cli_kube_destination.context
  -> resource:string
  -> name:string
  -> namespace:string
  -> patch_type:string
  -> patch:string
  -> (Sol_cli_process.output, Sol_cli_process.error) result

(** [create ~ctx ~file]: kubectl's "AlreadyExists" arrives in the [Non_zero]
    branch, where the boundary lease (FEAT-072) reads it as the atomic-acquire
    signal rather than as a failure. *)
val create
  :  ctx:Sol_cli_kube_destination.context
  -> file:string
  -> (Sol_cli_process.output, Sol_cli_process.error) result

(** [replace ~ctx ~file]: optimistic concurrency travels in the object. When the
    file carries [metadata.resourceVersion], the API server rejects a stale write
    with a conflict, which arrives in the [Non_zero] branch. There is deliberately
    no [--resource-version] flag — not every kubectl has one. *)
val replace
  :  ctx:Sol_cli_kube_destination.context
  -> file:string
  -> (Sol_cli_process.output, Sol_cli_process.error) result

(** FEAT-079: [sol fn run]'s primitive — [kubectl create job
    --from=cronjob/<cronjob>]. Copies the deployed [CronJob]'s [jobTemplate]
    verbatim into a new ad-hoc [Job] named [job_name]; this is the substrate
    mechanism that makes a manual invocation run the exact definition a
    scheduled one would, without Sol reconstructing or storing a second copy
    of it. *)
val create_job_from_cronjob
  :  ctx:Sol_cli_kube_destination.context
  -> cronjob:string
  -> job_name:string
  -> namespace:string
  -> (Sol_cli_process.output, Sol_cli_process.error) result

(** Delete an object, tolerating an absent one (["--ignore-not-found"]). *)
val delete
  :  ctx:Sol_cli_kube_destination.context
  -> resource:string
  -> name:string
  -> namespace:string
  -> (unit, Sol_cli_process.error) result

(** What a probe established. Three states, because a bool cannot distinguish
    "kubectl answered no" from "kubectl could not be run", and presenting the
    second as the first asserts an absence that was never observed (FND-0024).
    [Absent reason] carries what kubectl said; [Uncheckable why] is that kubectl
    could not be asked at all. *)
type presence =
  | Present
  | Absent of string
  | Uncheckable of string

(** What kubectl answered to a probe: it succeeded, or it ran and failed, with the
    exit code and what it said. *)
type probe =
  | Succeeded
  | Failed of Sol_cli_process.failure

(** [presence ~ctx ~args] probes through [probe_result]. *)
val presence : ctx:Sol_cli_kube_destination.context -> args:string list -> presence

(** The pure classifier behind {!presence}, exposed so the distinction can be
    tested without a cluster. *)
val presence_of_probe_result : (probe, string) result -> presence

(** The probe keeping what kubectl said. [Error] means kubectl could not be run
    at all, which is a different failure from running and failing.
    Bounded by a timeout, and non-interactive because the runner gives children
    /dev/null on stdin. *)
val probe_result
  :  ctx:Sol_cli_kube_destination.context
  -> args:string list
  -> (probe, string) result
