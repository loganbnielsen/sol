(** `sol alert test`'s synthetic alert and its delivery (OBS-043, REFAC-117).

    Not a unit test: an operator command that pushes one fake alert through a
    target's real Alertmanager route, so the team can prove the route reaches its
    named owner -- HARDEN-002's delivery evidence -- without a real incident. *)

(** The alert. It carries no workspace/domain/service labels: the point is the
    route, whichever workload would have fired, and a fabricated taxonomy label
    would be indistinguishable from a real alert in the receiver's history.
    [synthetic="true"] makes that explicit to whoever is on call. [now] is the
    [startsAt] time. *)
val synthetic_alert : owner:string -> runbook_url:string -> now:float -> Yojson.Safe.t

(** Alertmanager's v2 alerts endpoint under [base_url]. *)
val endpoint : string -> string

type outcome =
  | Accepted
  | Rejected of
      { exit_code : int
      ; stderr : string
      } (** Alertmanager (or the path to it) refused the POST. *)
  | Unreachable of string (** [curl] could not be run. *)

(** POST [body] to [url]. *)
val send : url:string -> body:string -> outcome
