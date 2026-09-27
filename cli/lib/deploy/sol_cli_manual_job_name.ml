let max_length = 63

let entropy_hex (entropy : string) : string =
  String.sub (Digest.to_hex (Digest.string entropy)) 0 8
;;

let rec trim_trailing_hyphen s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '-' then trim_trailing_hyphen (String.sub s 0 (n - 1)) else s
;;

let of_parts ~k8s_name ~(now : float) ~entropy =
  let suffix = Printf.sprintf "-manual-%d-%s" (int_of_float now) (entropy_hex entropy) in
  let budget = max 1 (max_length - String.length suffix) in
  let base =
    if String.length k8s_name <= budget
    then k8s_name
    else String.sub k8s_name 0 budget |> trim_trailing_hyphen
  in
  let base = if String.equal base "" then "fn" else base in
  base ^ suffix
;;

let mint ~k8s_name =
  of_parts
    ~k8s_name
    ~now:(Unix.gettimeofday ())
    ~entropy:(Sol_cli_deployment_id.random_entropy ())
;;
