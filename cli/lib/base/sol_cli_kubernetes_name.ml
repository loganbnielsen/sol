type k8s_name = K8s_name of string
type namespace = Namespace of string

let normalize name =
  String.map (fun c -> if c = '_' then '-' else Char.lowercase_ascii c) name
;;

let is_alnum = function
  | 'a' .. 'z' | '0' .. '9' -> true
  | _ -> false
;;

let is_dns_label_char = function
  | 'a' .. 'z' | '0' .. '9' | '-' -> true
  | _ -> false
;;

let validate_dns_label value =
  let len = String.length value in
  if len = 0
  then Error "must be between 1 and 63 characters"
  else if len > 63
  then Error "must be between 1 and 63 characters"
  else if not (is_alnum value.[0])
  then Error "must start with a lowercase alphanumeric character"
  else if not (is_alnum value.[len - 1])
  then Error "must end with a lowercase alphanumeric character"
  else (
    let rec loop i =
      if i = len
      then Ok ()
      else if is_dns_label_char value.[i]
      then loop (i + 1)
      else Error "must contain only lowercase alphanumeric characters or hyphens"
    in
    loop 0)
;;

let make_k8s_name value = Result.map (fun () -> K8s_name value) (validate_dns_label value)

let make_namespace value =
  Result.map (fun () -> Namespace value) (validate_dns_label value)
;;

let k8s_name_of_source source = source |> normalize |> make_k8s_name

let namespace_of_parts ~workspace ~domain =
  Printf.sprintf "%s-%s" (normalize workspace) (normalize domain) |> make_namespace
;;

let k8s_name_to_string (K8s_name value) = value
let namespace_to_string (Namespace value) = value

let sanitize_label_value v =
  let buf = Buffer.create (String.length v) in
  v
  |> String.iter (fun c ->
    match Char.lowercase_ascii c with
    | ('a' .. 'z' | '0' .. '9' | '-') as c -> Buffer.add_char buf c
    | _ -> Buffer.add_char buf '-');
  let s = Buffer.contents buf in
  let s = if String.length s > 63 then String.sub s 0 63 else s in
  let len = String.length s in
  let start = ref 0 in
  while !start < len && not (is_alnum s.[!start]) do
    incr start
  done;
  let s = String.sub s !start (len - !start) in
  let len = String.length s in
  if len = 0
  then "unknown"
  else if is_alnum s.[len - 1]
  then s
  else String.sub s 0 (len - 1) ^ "0"
;;

let sanitize_name (s : string) : string =
  let buf = Buffer.create (String.length s) in
  s
  |> String.iter (fun c ->
    match c with
    | 'a' .. 'z' | '0' .. '9' | '-' | '.' -> Buffer.add_char buf c
    | 'A' .. 'Z' -> Buffer.add_char buf (Char.lowercase_ascii c)
    | _ -> Buffer.add_char buf '-');
  let out = Buffer.contents buf in
  let out = if String.length out > 253 then String.sub out 0 253 else out in
  let len = String.length out in
  let start = ref 0 in
  while !start < len && not (is_alnum out.[!start]) do
    incr start
  done;
  let stop = ref (len - 1) in
  while !stop >= !start && not (is_alnum out.[!stop]) do
    decr stop
  done;
  let trimmed =
    if !stop < !start then "" else String.sub out !start (!stop - !start + 1)
  in
  if trimmed = "" then "none" else trimmed
;;

let service_url ~(namespace : namespace) ~(k8s_name : k8s_name) : string =
  Printf.sprintf
    "http://%s.%s.svc.cluster.local"
    (k8s_name_to_string k8s_name)
    (namespace_to_string namespace)
;;

let call_env_var source_name =
  source_name
  |> String.map (function
    | 'a' .. 'z' as c -> Char.uppercase_ascii c
    | ('A' .. 'Z' | '0' .. '9') as c -> c
    | _ -> '_')
  |> fun s -> s ^ "_URL"
;;
