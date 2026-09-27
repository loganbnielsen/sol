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

let next = function
  | Aws -> Some Gcp
  | Gcp -> None
;;

let all =
  let rec from p =
    p
    ::
    (match next p with
     | Some q -> from q
     | None -> [])
  in
  from Aws
;;

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
