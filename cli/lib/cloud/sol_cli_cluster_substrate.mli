(** INFRA-093 / FND-0064: the Kubernetes substrate the standard Sol platform profile supports. *)

type t =
  | Standard
  | Autopilot
  | Absent
  | Unknown of string

(** The message an operator gets when the substrate is Autopilot. It describes the support
    contract, with Autopilot's restrictions as the reason -- not the platform's current manifests
    as the definition. *)
val support_contract : string

(** [Ok] for [Standard] and for [Absent] (a fresh target Sol is about to provision Standard into);
    [Error] for [Autopilot], and for [Unknown] -- an unreadable cluster is never absence. *)
val acceptable : t -> (unit, string) result

val to_string : t -> string
