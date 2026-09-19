type t =
  | Aws
  | Gcp

let of_string = function
  | "aws" -> Some Aws
  | "gcp" -> Some Gcp
  | _ -> None
;;

let to_string = function
  | Aws -> "aws"
  | Gcp -> "gcp"
;;

let is_known s = Option.is_some (of_string s)

(* Every provider, in one place. Used where a check has to cover all of them
   rather than the one a command was addressed to -- validating each provider's
   readiness invocations against kubectl, for instance -- so a provider added
   later cannot be silently left unvalidated. *)
let all = [ Aws; Gcp ]
