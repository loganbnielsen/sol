(* INFRA-093 / FND-0064: which Kubernetes substrate the standard Sol platform profile supports.

   GCP qualification Attempt 14 measured what happens without this contract: the platform applied
   the cloud root and its prerequisites, then GKE Autopilot's admission webhook refused three
   manifests -- `hostNetwork`/`hostPID` for the platform's node-exporter, and `SYS_RESOURCE` for
   Redpanda's `tuning` container -- about ten minutes and one billable cluster after the run began,
   with no path to `Ready`.

   The contract is deliberately about the *profile*, not about those manifests. Naming the two
   components would make yesterday's component list the architectural definition of GCP support,
   and a third component with the same requirement would then be a new finding rather than a case
   the profile already answers. What the profile requires is a substrate that permits ordinary
   node-level capabilities; Autopilot does not, by policy, and that is the whole of it:

     - what Sol provisions is GKE Standard (the GCP driver's own configuration -- see
       `platform/cloud/gcp/cluster/main.tf`), so this refusal is not the mechanism that makes
       Standard the substrate;
     - this type is how Sol *reconciles with an existing cluster* whose mode it can observe, so
       that it refuses before asking Terraform to touch a cluster Autopilot would then refuse to
       host.

   How much of a cluster exists is part of the observation, not a guess: `Absent` is a fresh
   target, and anything Sol cannot read is `Unknown` -- never absence. *)

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

(* [Ok] means "carry on": a Standard cluster is what the profile expects, and a target with no
   cluster yet is a target Sol is about to provision Standard into. *)
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
