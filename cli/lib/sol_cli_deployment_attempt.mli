(** FEAT-072: one deploy *attempt* as a unit.

    A release record is written only when an apply succeeded; a deployment event
    is written once for every attempt, success or failure (FEAT-070/071). This
    module names that lifecycle so a command's orchestration can read as
    "attempt, then outcome, then exactly one event" instead of an interleaved
    block. It never exits: the caller decides what a failure to record means. *)

(** An in-flight attempt: its deployment id and the timestamp its event carries. *)
type t

(** Mint an attempt. *)
val start : unit -> t

val deployment_id : t -> Sol_cli_deployment_id.t

(** [outcome_of applied] is [Applied] for [Ok _] and [Apply_failed] for
    [Error _] — the event records the attempt, not the release. *)
val outcome_of : ('a, string) result -> Sol_cli_deployment.outcome

(** [record ~ctx ~target plan attempt outcome] writes the one immutable event for
    [attempt]. Non-fatal: a write failure is warned and reported as [false], so
    the caller can decide whether a telemetry marker may be emitted. *)
val record
  :  ctx:Sol_cli_kube_destination.context
  -> target:string option
  -> Sol_cli_deployment_plan.t
  -> t
  -> Sol_cli_deployment.outcome
  -> bool
