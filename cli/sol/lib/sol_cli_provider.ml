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
