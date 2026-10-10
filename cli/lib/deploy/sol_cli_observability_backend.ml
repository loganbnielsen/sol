type backend =
  | Local
  | Self_hosted_durable
  | External

let backend_of_string = function
  | "local" -> Some Local
  | "self_hosted_durable" -> Some Self_hosted_durable
  | "external" -> Some External
  | _ -> None
;;

let backend_to_string = function
  | Local -> "local"
  | Self_hosted_durable -> "self_hosted_durable"
  | External -> "external"
;;
