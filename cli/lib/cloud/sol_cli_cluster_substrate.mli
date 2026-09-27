type t =
  | Standard
  | Autopilot
  | Absent
  | Unknown of string

val support_contract : string
val acceptable : t -> (unit, string) result
val to_string : t -> string
