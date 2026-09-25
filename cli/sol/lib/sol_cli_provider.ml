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

(* AUDIT-POST-003: which target-file keys are a *provider's own*, so the config parser
   can reject a flat one with a message naming the block it belongs in.

   The mapping lives here rather than in Sol_cli_config because (a) this is the provider
   tier and config already depends on it -- asking the capabilities module would be a
   dependency cycle -- and (b) the form it had was a *string* literal ("aws"/"gcp"), which
   the provider-dispatch guard cannot see: it counts constructors. Expressed as
   constructors in the approved provider module, the same knowledge is inside the
   boundary the guard exists to draw. *)
let owned_legacy_keys : (string * t) list =
  [ "state_lock_table", Aws
  ; "provisioner_role_arn", Aws
  ; "cluster_access_role_arn", Aws
  ; "deploy_role_arn", Aws
  ; "operator_role_arn", Aws
  ; "provisioner_impersonator", Gcp
  ]
;;

let owned_legacy_key name = List.assoc_opt name owned_legacy_keys
