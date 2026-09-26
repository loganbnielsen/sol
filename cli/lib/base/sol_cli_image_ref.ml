(* Immutable workload artifact references (FEAT-050).

   A recorded production release and its rollback must refer to the same bytes.
   A tag can move, so a content digest is the only artifact reference that
   means that. This module is the single definition of what counts as a digest
   reference, so the command request, the plan and the profile preflight cannot
   disagree about it. *)

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

(* [repo@sha256:<64 lowercase hex>] with a non-empty repository. Deliberately
   strict about the lowercase hex: Docker/OCI digests are lower-case, and
   accepting uppercase would let two spellings of the same reference produce
   different release identities. *)
let is_digest s =
  match String.rindex_opt s '@' with
  | None -> false
  | Some at ->
    let repo = String.sub s 0 at in
    let suffix = String.sub s (at + 1) (String.length s - at - 1) in
    String.length repo > 0
    && String.length suffix = String.length digest_prefix + digest_hex_length
    && String.sub suffix 0 (String.length digest_prefix) = digest_prefix
    && is_lower_hex (String.sub suffix (String.length digest_prefix) digest_hex_length)
;;

(* A raw [--image-ref] value is either [<service>=<repo>@sha256:<digest>] or a
   bare [<repo>@sha256:<digest>]. Service and repository names never contain
   '=', so the first '=' is the separator. *)
let split_flag_value value =
  match String.index_opt value '=' with
  | Some eq when eq > 0 ->
    Some (String.sub value 0 eq), String.sub value (eq + 1) (String.length value - eq - 1)
  | _ -> None, value
;;

(* Resolve parsed [--image-ref] values against the services actually selected
   for this invocation. A named reference must name a selected service; a bare
   reference is unambiguous only when exactly one service is selected. Every
   named reference must be a digest — a mutable tag is never an acceptable
   [--image-ref]. *)
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

(* Every workload in the plan must deploy an immutable reference for the
   production profile's artifact guarantee to hold. A plan with no services is
   not admissible either: an empty plan proves nothing. *)
let plan_is_immutable (images : string list) =
  images <> [] && List.for_all is_digest images
;;
