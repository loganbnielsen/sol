type t =
  | Standard
  | Autopilot
  | Absent
  | Unknown of string

let support_contract =
  "GKE Autopilot is not supported by the standard Sol platform profile. The profile \
   requires a substrate that permits the node-level capabilities its components declare, \
   and Autopilot's admission policies restrict them -- host networking and host process \
   access, and the SYS_RESOURCE capability among them. Provision, or point the target \
   at, a GKE Standard cluster."
;;

let acceptable = function
  | Standard | Absent -> Ok ()
  | Autopilot -> Error support_contract
  | Unknown reason ->
    Error
      (Printf.sprintf
         "Sol could not establish the Kubernetes substrate of the existing cluster: %s. \
          It will not provision into, or reconcile, a cluster whose mode it cannot read."
         reason)
;;

let to_string = function
  | Standard -> "standard"
  | Autopilot -> "autopilot"
  | Absent -> "absent"
  | Unknown reason -> Printf.sprintf "unknown (%s)" reason
;;
