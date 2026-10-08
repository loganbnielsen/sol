let digest_prefix = "sha256:"
let digest_hex_length = 64

let is_lower_hex s =
  String.length s = digest_hex_length
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       s
;;

let is_digest s =
  match String.rindex_opt s '@' with
  | None -> false
  | Some at ->
    let repo = String.sub s 0 at in
    let suffix = String.sub s (at + 1) (String.length s - at - 1) in
    String.length repo > 0
    && String.length suffix = String.length digest_prefix + digest_hex_length
    && String.starts_with ~prefix:digest_prefix suffix
    && is_lower_hex (String.sub suffix (String.length digest_prefix) digest_hex_length)
;;

let split_flag_value value =
  match String.index_opt value '=' with
  | Some eq when eq > 0 ->
    Some (String.sub value 0 eq), String.sub value (eq + 1) (String.length value - eq - 1)
  | _ -> None, value
;;

let resolve ~service_names refs =
  let validate (_, ref) =
    if is_digest ref
    then None
    else
      Some
        (Printf.sprintf
           "--image-ref %S is not an immutable reference; expected <repo>@sha256:<64 \
            hexadecimal digits>"
           ref)
  in
  match List.find_map validate refs with
  | Some msg -> Error msg
  | None ->
    let rec go seen acc = function
      | [] -> Ok (List.rev acc)
      | (name, ref) :: rest ->
        (match name with
         | Some service ->
           if List.mem service seen
           then
             Error (Printf.sprintf "--image-ref names service %S more than once" service)
           else if not (List.mem service service_names)
           then
             Error
               (Printf.sprintf
                  "--image-ref names service %S, which is not in the selected scope (%s)"
                  service
                  (if service_names = [] then "none" else String.concat ", " service_names))
           else go (service :: seen) ((service, ref) :: acc) rest
         | None ->
           (match service_names with
            | [ only ] -> go (only :: seen) ((only, ref) :: acc) rest
            | _ ->
              Error
                (Printf.sprintf
                   "--image-ref without a service name requires exactly one selected \
                    service; this scope selects %d (%s). Use --image-ref \
                    <service>=<ref>."
                   (List.length service_names)
                   (if service_names = []
                    then "none"
                    else String.concat ", " service_names))))
    in
    go [] [] refs
;;

let resolve_complete ~service_names refs =
  let open Result.Syntax in
  let* resolved = resolve ~service_names refs in
  let missing =
    List.filter (fun name -> not (List.mem_assoc name resolved)) service_names
  in
  if missing = []
  then Ok resolved
  else
    Error
      (Printf.sprintf
         "a target-wide plan requires an immutable --image-ref for every workload; \
          missing: %s"
         (String.concat ", " missing))
;;

let plan_is_immutable (images : string list) =
  images <> [] && List.for_all is_digest images
;;
