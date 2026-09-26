(* AUDIT-080: the application-declared availability semantic.

   A workload admitted to [production-single-region] declares the failure it must
   tolerate; Sol renders and validates the minimum native controls that make the
   claim true. A replica count alone is not an availability guarantee.

   The valid matrix (DEC-026 §3, FEAT-083):

   - services and workers may be [single] or [node-failure-tolerant];
   - functions are scheduled jobs — availability is not applicable;
   - a persistent volume pins a workload to a single writable attachment, so a
     volume-backed workload can only be [single] (FEAT-083 already forces
     [replicas = 1] there).

   This is deliberately the only availability input. PodDisruptionBudget,
   affinity/topology, probe timing and termination-grace are rendered *from* the
   semantic, never exposed as the application contract. *)

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
