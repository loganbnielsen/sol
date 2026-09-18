type trigger =
  | Cron of string (** Cron expression, e.g. ["0 * * * *"] for hourly. *)
  | Lambda
  (** Runs via the AWS Lambda Runtime API loop ([lambda-eio]) instead of
          once-and-exit — see [aws-audit.md] and [lambda-eio.md] for the full
          design. Not a general event-processing trigger: v1 does not thread the
          Lambda event payload into [F.run] at all, matching this module's
          existing "run once, report status" contract; a Lambda-triggered [-fn]
          is a cron job hosted on Lambda instead of a Kubernetes CronJob, not an
          S3/SQS/DynamoDB-Streams event handler. *)

module type FN = sig
  val trigger : trigger

  (** The function body. Called once per invocation; must return. *)
  val run : unit -> (unit, string) result
end

type run_error =
  [ `Config of string
  | `Run of string
  | `Signalled
  ]

val run_error_to_string : run_error -> string

module Make (F : FN) : sig
  (** [Cron _]: run [F.run ()] once, record metrics, push to Pushgateway if
      configured, then return. [F.run () = Error msg] becomes
      [Error (`Run msg)]. Ordinary exceptions from [F.run] become
      [Error (`Run ...)] while Eio cancellation and fatal runtime exceptions
      continue to propagate. SIGTERM or SIGINT returns [Error `Signalled].

      [Lambda]: loop forever via [Lambda_runtime.run_loop] ([lambda-eio]),
      calling [F.run ()] once per invocation and recording/pushing metrics per
      invocation — never exits on a successful invocation. A single invocation's
      [Error msg] is reported to the Runtime API via
      [Lambda_runtime.respond_error] and the loop continues. On SIGTERM/SIGINT
      the loop stops after finishing whatever invocation is currently in flight
      (a Lambda execution environment being frozen/shut down sends SIGTERM —
      this is expected, routine shutdown, not the abnormal-exit signal [Cron]'s
      exit code 130 represents), then this function returns normally instead of
      exiting the process — a Lambda runtime process should not call [exit]
      itself; the execution environment manages the process lifecycle. Requires
      [AWS_LAMBDA_RUNTIME_API] to be set, otherwise returns
      [Error (`Config ...)]. *)
  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> ?pushgateway_url:string
         (** Pushgateway base URL, e.g. "http://pushgateway:9091". If absent,
          metrics are recorded in-process but not pushed. *)
    -> ?job:string
         (** Pushgateway job label. Defaults to the cron schedule string for
          [Cron], or ["lambda"] for [Lambda]. *)
    -> ?ot:Sol_obs.t
         (** Observability handle. Its composed backend + renderer are used for
          this invocation's metrics and push; defaults to a bare
          [Obs_prometheus.create ()] backend when absent. *)
    -> ?stop:unit Eio.Promise.t
         (** External stop signal. [Cron] returns [`Signalled] without starting a
          new run if it is already resolved; [Lambda] leaves the runtime loop
          after the current invocation. *)
    -> unit
    -> (unit, run_error) result
end
