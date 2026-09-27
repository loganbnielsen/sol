type t =
  | Single
  | Node_failure_tolerant

val all : t list
val to_string : t -> string
val of_string : string -> (t, string) result
val is_node_failure_tolerant : t -> bool
