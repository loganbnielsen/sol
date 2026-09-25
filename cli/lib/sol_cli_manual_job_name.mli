(** The name of one manually-triggered run of a scheduled workload (BUG-032).

    A [sol fn run] creates a Job from the workload's CronJob, and that Job needs a
    name that is unique per invocation: the previous
    [<k8s_name>-manual-<epoch seconds>] form collided whenever two runs landed in
    the same second, which is what firing several at once to generate burst load
    does immediately. *)

(** [of_parts ~k8s_name ~now ~entropy] is
    [<k8s_name>-manual-<seconds>-<hex entropy>], shortened in its base if necessary
    so the whole name is at most 63 characters — the cap on the [job-name] label
    Kubernetes derives from it. Deterministic for a given [now] and [entropy], so a
    test can pin the shape exactly; production uses {!mint}. *)
val of_parts : k8s_name:string -> now:float -> entropy:string -> string

(** [mint ~k8s_name] is {!of_parts} with the current clock and OS entropy, and is
    what a command calls. Two calls in immediate succession are distinct. *)
val mint : k8s_name:string -> string
