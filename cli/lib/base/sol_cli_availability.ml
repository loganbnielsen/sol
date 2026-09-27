type t =
  | Single
  | Node_failure_tolerant

let all = [ Single; Node_failure_tolerant ]

let to_string = function
  | Single -> "single"
  | Node_failure_tolerant -> "node-failure-tolerant"
;;

let of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "single" -> Ok Single
  | "node-failure-tolerant" | "node_failure_tolerant" -> Ok Node_failure_tolerant
  | other ->
    Error
      (Printf.sprintf
         "unknown availability %S (supported: %s)"
         other
         (all |> List.map to_string |> String.concat ", "))
;;

let is_node_failure_tolerant = function
  | Node_failure_tolerant -> true
  | Single -> false
;;
