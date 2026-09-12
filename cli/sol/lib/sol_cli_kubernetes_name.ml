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

(* OBS-021: a lenient sibling to [normalize]/[validate_dns_label] for
   taxonomy label values (workspace/domain/etc.) -- those get sanitized
   into something safe rather than rejected, since a bad label value is
   far cheaper than a failed deploy. [normalize] alone isn't enough here:
   it only rewrites underscores, so anything else invalid (spaces, other
   punctuation) survives untouched. This is also the one function
   [Sol_cli_manifest_yaml.render_taxonomy_labels] and
   [Sol_cli_open.dashboard_url] must both call for workspace/domain --
   two different transforms there is exactly how a rendered label and a
   dashboard link's query param end up disagreeing for the same value. *)
let sanitize_label_value v =
  let buf = Buffer.create (String.length v) in
  String.iter
    (fun c ->
       match Char.lowercase_ascii c with
       | ('a' .. 'z' | '0' .. '9' | '-') as c -> Buffer.add_char buf c
       | _ -> Buffer.add_char buf '-')
    v;
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

(* BUG-025: Kubernetes object *names* (metadata.name) are RFC 1123 subdomains —
   lowercase alphanumerics, '-' and '.', up to 253 characters, and they must
   start and end alphanumerically. '_' is legal in a label *value* but NOT in a
   name, which is how "sol-deploy-state-ci_smoke" came to be rejected. This is
   the shared home for that transform; [Sol_cli_release] and
   [Sol_cli_deployment_state] both build object names from a workspace. *)
let sanitize_name (s : string) : string =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
       match c with
       | 'a' .. 'z' | '0' .. '9' | '-' | '.' -> Buffer.add_char buf c
       | 'A' .. 'Z' -> Buffer.add_char buf (Char.lowercase_ascii c)
       | _ -> Buffer.add_char buf '-')
    s;
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
