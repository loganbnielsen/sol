(* Pure parsing/summarizing of kubectl pod + event JSON for 'sol status'
   rollout diagnosis. The parse_*/format_* functions below do no I/O —
   callers fetch JSON via Sol_cli_kubectl and pass it in. The one exception is
   [diagnose_service_live], which fetches cluster state itself; see its own
   doc comment. *)

type container_state =
  | Waiting of
      { reason : string
      ; message : string option
      }
  | Running
  | Terminated of
      { reason : string
      ; exit_code : int
      ; message : string option
      }
  | Unknown_state

type pod_status =
  { name : string
  ; phase : string
  ; ready : bool
  ; restarts : int
  ; image : string option
  ; state : container_state
  ; last_terminated_reason : string option
  }

type event =
  { ev_type : string
  ; reason : string
  ; message : string
  ; count : int
  ; last_timestamp : string option
  ; involved_name : string
  }

(** Parse the output of [kubectl get pods -n <ns> -l <selector> -o json]. *)
val parse_pods_json : string -> pod_status list

(** Parse the output of [kubectl get events -n <ns> -o json]. *)
val parse_events_json : string -> event list

(** Most recent [limit] events (default 5) involving the given pod name, newest
    first. *)
val events_for_pod : ?limit:int -> pod_name:string -> event list -> event list

(** A pod is healthy when it is Running, ready, and its container state is also
    Running (not stuck Waiting/Terminated with a stale ready flag). *)
val is_healthy : pod_status -> bool

(** Workload health model. [Continuous] services should always have current
    pods. [Ephemeral] functions leave historical run-pods behind with no
    reliable way to pick the latest run from pod state alone, so they're
    diagnosed from CronJob status instead -- except a currently active run,
    identified unambiguously via [status.active]'s Job names. *)
type pod_expectation =
  | Continuous
  | Ephemeral

(** INFRA-057 / DEC-038 §5: the result of reading a namespace's events.

    A failed read is **not** an empty result, and the two must never render the
    same way:

    - [Events []] -- the read succeeded and there is nothing to report;
    - [Events_unavailable why] -- Sol could not look, and says so, naming why.

    The status contract stays best-effort (one denied read must not deny the
    operator the rest of the diagnosis), but it must never present a part it did
    not obtain as though it had. *)
type events_fetch_result =
  | Events of event list
  | Events_unavailable of string

(** Render one pod's diagnosis block: state/reason, restarts, last termination
    reason, image, and recent events. When the events read failed, the block says
    so rather than showing none. *)
val format_pod_diagnosis : pod_status -> events_fetch_result -> string

(** [Continuous] diagnosis over a confirmed pod list. Pass only a real pod list
    from a successful kubectl fetch: [] means confirmed zero pods, not "could
    not check." [None] means every pod is healthy. *)
val format_service_diagnosis
  :  service_name:string
  -> pod_status list
  -> events_fetch_result
  -> string option

(** CronJob status fields used for [Ephemeral] diagnosis. *)
type cronjob_status =
  { last_schedule_time : string option
  ; last_successful_time : string option
  ; active_count : int (** Number of currently-running Jobs for this CronJob. *)
  ; active_job_names : string list
    (** Active Job names from [status.active], for targeting current-run pods
          without scanning history. *)
  }

(** Parse [kubectl get cronjob <name> -n <ns> -o json]. A CronJob with no
    [status] object parses to defaults, not [None]. *)
val parse_cronjob_status : string -> cronjob_status option

(** CronJob fetch result. [Missing] is confirmed NotFound and should be
    reported; [Unavailable] is a transient fetch/parse failure and should stay
    silent. *)
type cronjob_fetch_result =
  | Found of cronjob_status
  | Missing
  | Unavailable

(** [Ephemeral] diagnosis of the CronJob's last *completed* run: healthy when no
    run has ever been scheduled or [lastSuccessfulTime >= lastScheduleTime]. A
    currently-active run is never a finding here regardless of its pod's state
    -- see [format_active_run_diagnosis] for that. *)
val format_cronjob_diagnosis
  :  service_name:string
  -> cronjob_fetch_result
  -> string option

(** [Ephemeral] diagnosis of an active run's own pod(s), scoped to exactly the
    Job(s) in [cronjob_status.active_job_names]. More lenient than
    [format_service_diagnosis]: a [Succeeded] pod, or one merely starting up
    with no restart history, is not a finding. *)
val format_active_run_diagnosis
  :  service_name:string
  -> pod_status list
  -> events_fetch_result
  -> string option

(** Live diagnosis for a deployed workload in the cluster [ctx] names. Unlike
    the rest of this module, this fetches cluster state itself (pods, events,
    cronjob status) via [Sol_cli_kubectl.get_raw] rather than taking
    already-fetched JSON. [Ephemeral] tries [format_active_run_diagnosis]
    first when a run is currently active and its pod(s) can be fetched,
    falling back to [format_cronjob_diagnosis] otherwise (no active run, or
    the active pod fetch itself failed). *)
val diagnose_service_live
  :  ctx:Sol_cli_kube_destination.context
  -> pod_expectation:pod_expectation
  -> ns:string
  -> service_name:string
  -> k8s_name:string
  -> unit
  -> string option
