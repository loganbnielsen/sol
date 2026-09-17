(** The application-declared availability semantic (AUDIT-080).

    [single] makes no failure-tolerance claim; [node-failure-tolerant] claims a
    workload survives losing one node. Sol renders the native controls that make
    the claim true; the raw controls are not the contract. *)
type t =
  | Single
  | Node_failure_tolerant

val all : t list
val to_string : t -> string

(** [of_string] accepts [single] and [node-failure-tolerant] (also the
    underscore spelling), case-insensitively. *)
val of_string : string -> (t, string) result

val is_node_failure_tolerant : t -> bool
