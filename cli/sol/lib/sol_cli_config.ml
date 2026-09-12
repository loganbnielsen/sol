type target =
  { name : string
  ; env : string
  ; provider : Sol_cli_provider.t
  ; region : string
  ; registry : string option
  ; base_domain : string option
  ; cluster_issuer : string option
  ; cluster_name : string option
  ; kube_context : string option
  ; terraform_var_file : string option
  ; observability_backend : string option
  ; provider_fields : (string * (string * string) list) list
  }

type index =
  { index_name : string
  ; partition_key : string option
  ; sort_key : string option
  }

type resource =
  { name : string
  ; typ : string option
  ; partition_key : string option
  ; sort_key : string option
  ; indexes : index list
  ; size : string option
  ; omit : bool
  }

type service =
  { name : string
  ; typ : string option
  ; path : string option
  ; uses : string list
  ; scale_min : int option
  ; scale_max : int option
  ; omit : bool
  }

type t =
  { project : string option
  ; target : target option
  ; resources : resource list
  ; services : service list
  }

let target_empty =
  { name = ""
  ; env = ""
  ; provider = Sol_cli_provider.Aws
  ; region = ""
  ; registry = None
  ; base_domain = None
  ; cluster_issuer = None
  ; cluster_name = None
  ; kube_context = None
  ; terraform_var_file = None
  ; observability_backend = None
  ; provider_fields = []
  }
;;

let empty = { project = None; target = None; resources = []; services = [] }

type error =
  { path : string
  ; line : int
  ; message : string
  }

let error_to_string e = Printf.sprintf "%s:%d: %s" e.path e.line e.message
let ( let* ) = Result.bind
let trim = String.trim

let strip_comment s =
  let rec loop quote i =
    if i >= String.length s
    then s
    else (
      match s.[i] with
      | '"' when quote = None -> loop (Some '"') (i + 1)
      | '\'' when quote = None -> loop (Some '\'') (i + 1)
      | c when quote = Some c -> loop None (i + 1)
      | '#' when quote = None -> String.sub s 0 i
      | _ -> loop quote (i + 1))
  in
  loop None 0
;;

let indent s =
  let rec loop i = if i < String.length s && s.[i] = ' ' then loop (i + 1) else i in
  loop 0
;;

let ends_with ~suffix s =
  let slen = String.length suffix in
  let len = String.length s in
  len >= slen && String.sub s (len - slen) slen = suffix
;;

let drop_suffix ~suffix s = String.sub s 0 (String.length s - String.length suffix)

let parse_scalar s =
  let s = trim s in
  let len = String.length s in
  if len = 0
  then Ok s
  else if s.[0] = '"' || s.[0] = '\''
  then
    if len >= 2 && s.[len - 1] = s.[0]
    then Ok (String.sub s 1 (len - 2))
    else Error "malformed quoted value"
  else if s.[len - 1] = '"' || s.[len - 1] = '\''
  then Error "malformed quoted value"
  else Ok s
;;

let split_key_value s =
  match String.index_opt s ':' with
  | None -> None
  | Some i ->
    Some (trim (String.sub s 0 i), trim (String.sub s (i + 1) (String.length s - i - 1)))
;;

let parse_list s =
  let parse_items s =
    String.split_on_char ',' s
    |> List.map trim
    |> List.filter (( <> ) "")
    |> List.fold_left
         (fun acc v ->
            let* xs = acc in
            let* v = parse_scalar v in
            Ok (xs @ [ v ]))
         (Ok [])
  in
  let s = trim s in
  let len = String.length s in
  if len >= 2 && s.[0] = '[' && s.[len - 1] = ']'
  then parse_items (String.sub s 1 (len - 2))
  else if len > 0 && (s.[0] = '[' || s.[len - 1] = ']')
  then Error "malformed list"
  else if s = ""
  then Ok []
  else
    let* v = parse_scalar s in
    Ok [ v ]
;;

let parse_int s =
  match int_of_string_opt (trim s) with
  | Some i -> Ok (Some i)
  | None -> Error "expected integer"
;;

let parse_bool s =
  match trim s with
  | "true" -> Ok true
  | "false" -> Ok false
  | _ -> Error "expected true or false"
;;

let index_empty index_name = { index_name; partition_key = None; sort_key = None }

let upsert_by_name name key update xs =
  let rec loop acc = function
    | [] -> List.rev (update None :: acc)
    | x :: rest when name x = key -> List.rev_append acc (update (Some x) :: rest)
    | x :: rest -> loop (x :: acc) rest
  in
  loop [] xs
;;

let resource_empty name =
  { name
  ; typ = None
  ; partition_key = None
  ; sort_key = None
  ; indexes = []
  ; size = None
  ; omit = false
  }
;;

let service_empty name =
  { name
  ; typ = None
  ; path = None
  ; uses = []
  ; scale_min = None
  ; scale_max = None
  ; omit = false
  }
;;

type target_key =
  | Target_registry
  | Target_base_domain
  | Target_cluster_issuer
  | Target_cluster_name
  | Target_kube_context
  | Target_terraform_var_file
  | Target_observability_backend
  | Target_provider_box of Sol_cli_provider.t
  | Target_unknown of string

let target_key_of_string s =
  match s with
  | "registry" -> Target_registry
  | "base_domain" -> Target_base_domain
  | "cluster_issuer" -> Target_cluster_issuer
  | "cluster_name" -> Target_cluster_name
  | "kube_context" -> Target_kube_context
  | "terraform_var_file" -> Target_terraform_var_file
  | "observability_backend" -> Target_observability_backend
  | _ ->
    (match Sol_cli_provider.of_string s with
     | Some provider -> Target_provider_box provider
     | None -> Target_unknown s)
;;

let target_key_name = function
  | Target_registry -> "registry"
  | Target_base_domain -> "base_domain"
  | Target_cluster_issuer -> "cluster_issuer"
  | Target_cluster_name -> "cluster_name"
  | Target_kube_context -> "kube_context"
  | Target_terraform_var_file -> "terraform_var_file"
  | Target_observability_backend -> "observability_backend"
  | Target_provider_box provider -> Sol_cli_provider.to_string provider
  | Target_unknown s -> s
;;

type section =
  | None_section
  | Target
  | Resources
  | Resource of string
  | Resource_indexes of string
  | Resource_index of string * string
  | Target_provider of string
  | Services
  | Service of string
  | Service_scale of string

type root_section =
  | No_root
  | Resources_root
  | Services_root

let load path =
  if not (Sys.file_exists path)
  then Ok empty
  else (
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let cfg = ref empty in
         let section = ref None_section in
         let root = ref No_root in
         let seen_target = ref false in
         let seen_resources = ref false in
         let seen_services = ref false in
         let seen_provider_boxes = ref [] in
         let line_no = ref 0 in
         let fail message = Error { path; line = !line_no; message } in
         let require_value k v =
           if v = "" then fail (Printf.sprintf "missing value for %s" k) else Ok ()
         in
         let scalar k v =
           match parse_scalar v with
           | Ok v -> Ok v
           | Error msg -> fail (msg ^ " for " ^ k)
         in
         let update_resource name f =
           let rec loop acc = function
             | [] -> fail (Printf.sprintf "resource %S is missing" name)
             | (r : resource) :: rest when r.name = name ->
               let* r = f r in
               Ok (List.rev_append acc (r :: rest))
             | r :: rest -> loop (r :: acc) rest
           in
           let* resources = loop [] !cfg.resources in
           cfg := { !cfg with resources };
           Ok ()
         in
         let update_service name f =
           let rec loop acc = function
             | [] -> fail (Printf.sprintf "service %S is missing" name)
             | (s : service) :: rest when s.name = name ->
               let* s = f s in
               Ok (List.rev_append acc (s :: rest))
             | s :: rest -> loop (s :: acc) rest
           in
           let* services = loop [] !cfg.services in
           cfg := { !cfg with services };
           Ok ()
         in
         let update_provider provider f =
           let target = Option.value !cfg.target ~default:target_empty in
           let fields =
             List.assoc_opt provider target.provider_fields |> Option.value ~default:[]
           in
           let* fields = f fields in
           let provider_fields =
             (provider, fields)
             :: List.filter (fun (p, _) -> p <> provider) target.provider_fields
           in
           cfg := { !cfg with target = Some { target with provider_fields } };
           Ok ()
         in
         let add_resource name =
           if List.exists (fun (r : resource) -> r.name = name) !cfg.resources
           then fail (Printf.sprintf "duplicate resource %S" name)
           else (
             cfg := { !cfg with resources = !cfg.resources @ [ resource_empty name ] };
             Ok ())
         in
         let add_service name =
           if List.exists (fun (s : service) -> s.name = name) !cfg.services
           then fail (Printf.sprintf "duplicate service %S" name)
           else (
             cfg := { !cfg with services = !cfg.services @ [ service_empty name ] };
             Ok ())
         in
         let rec loop () =
           match input_line ic with
           | exception End_of_file -> Ok !cfg
           | raw ->
             incr line_no;
             let text = strip_comment raw in
             if trim text = ""
             then loop ()
             else (
               let ind = indent text in
               let body = trim text in
               match ind, body, split_key_value body with
               | _, _, _
                 when ind >= 6
                      &&
                      match !section with
                      | Target_provider _ -> true
                      | _ -> false -> loop ()
               | 0, "target:", _ ->
                 if !seen_target
                 then fail "duplicate top-level section \"target\""
                 else if !root <> No_root
                 then fail "target must appear before resources or services"
                 else (
                   seen_target := true;
                   root := No_root;
                   section := Target;
                   loop ())
               | 0, "resources:", _ ->
                 if !seen_resources
                 then fail "duplicate top-level section \"resources\""
                 else (
                   seen_resources := true;
                   root := Resources_root;
                   section := Resources;
                   loop ())
               | 0, "services:", _ ->
                 if !seen_services
                 then fail "duplicate top-level section \"services\""
                 else (
                   seen_services := true;
                   root := Services_root;
                   section := Services;
                   loop ())
               | 0, _, Some ("project", v) ->
                 let* () = require_value "project" v in
                 let* project = scalar "project" v in
                 cfg := { !cfg with project = Some project };
                 loop ()
               | 0, _, Some (k, _) -> fail (Printf.sprintf "unknown top-level key %S" k)
               | 2, _, _ when ends_with ~suffix:":" body ->
                 let name = drop_suffix ~suffix:":" body |> trim in
                 (match !root with
                  | Resources_root ->
                    section := Resource name;
                    let* () = add_resource name in
                    loop ()
                  | Services_root ->
                    section := Service name;
                    let* () = add_service name in
                    loop ()
                  | No_root ->
                    (match !section, split_key_value body with
                     | (Target | Target_provider _), Some (k, "") ->
                       (match target_key_of_string k with
                        | Target_provider_box provider ->
                          let provider = Sol_cli_provider.to_string provider in
                          if List.mem provider !seen_provider_boxes
                          then
                            fail
                              (Printf.sprintf "duplicate target provider box %S" provider)
                          else (
                            seen_provider_boxes := provider :: !seen_provider_boxes;
                            section := Target_provider provider;
                            loop ())
                        | Target_unknown k ->
                          fail (Printf.sprintf "unsupported provider %S" k)
                        | key ->
                          fail
                            (Printf.sprintf "missing value for %s" (target_key_name key)))
                     | _ -> fail "unsupported sol.yml syntax"))
               | 2, _, Some (k, v) ->
                 let* () =
                   match !section with
                   | Target | Target_provider _ ->
                     let key = target_key_of_string k in
                     (match key, v with
                      | Target_provider_box provider, "" ->
                        let provider = Sol_cli_provider.to_string provider in
                        if List.mem provider !seen_provider_boxes
                        then
                          fail
                            (Printf.sprintf "duplicate target provider box %S" provider)
                        else (
                          seen_provider_boxes := provider :: !seen_provider_boxes;
                          section := Target_provider provider;
                          Ok ())
                      | Target_unknown k, "" ->
                        fail (Printf.sprintf "unsupported provider %S" k)
                      | Target_unknown k, _ ->
                        fail (Printf.sprintf "unknown target key %S" k)
                      | Target_provider_box _, _ ->
                        fail (Printf.sprintf "unknown target key %S" k)
                      | key, "" ->
                        fail (Printf.sprintf "missing value for %s" (target_key_name key))
                      | _ ->
                        let current = Option.value !cfg.target ~default:target_empty in
                        let* target =
                          match key with
                          | Target_registry ->
                            let* v = scalar k v in
                            Ok { current with registry = Some v }
                          | Target_base_domain ->
                            let* v = scalar k v in
                            Ok { current with base_domain = Some v }
                          | Target_cluster_issuer ->
                            let* v = scalar k v in
                            Ok { current with cluster_issuer = Some v }
                          | Target_cluster_name ->
                            let* v = scalar k v in
                            Ok { current with cluster_name = Some v }
                          | Target_kube_context ->
                            let* v = scalar k v in
                            Ok { current with kube_context = Some v }
                          | Target_terraform_var_file ->
                            let* v = scalar k v in
                            Ok { current with terraform_var_file = Some v }
                          | Target_observability_backend ->
                            let* v = scalar k v in
                            Ok { current with observability_backend = Some v }
                          | Target_provider_box _ | Target_unknown _ -> assert false
                        in
                        section := Target;
                        cfg := { !cfg with target = Some target };
                        Ok ())
                   | _ -> fail "unsupported sol.yml syntax"
                 in
                 loop ()
               | 4, _, Some (k, v) ->
                 let* () =
                   match !section with
                   | Resource name | Resource_indexes name | Resource_index (name, _) ->
                     if k = "indexes" && v = ""
                     then (
                       section := Resource_indexes name;
                       Ok ())
                     else
                       let* () = require_value k v in
                       let* () =
                         update_resource name (fun r ->
                           match k with
                           | "type" ->
                             let* v = scalar k v in
                             Ok { r with typ = Some v }
                           | "partition_key" ->
                             let* v = scalar k v in
                             Ok { r with partition_key = Some v }
                           | "sort_key" ->
                             let* v = scalar k v in
                             Ok { r with sort_key = Some v }
                           | "size" ->
                             let* v = scalar k v in
                             Ok { r with size = Some v }
                           | "omit" ->
                             (match parse_bool v with
                              | Ok omit -> Ok { r with omit }
                              | Error msg -> fail (msg ^ " for omit"))
                           | _ -> fail (Printf.sprintf "unknown resource key %S" k))
                       in
                       Ok ()
                   | Service name | Service_scale name ->
                     if k = "scale" && v = ""
                     then (
                       section := Service_scale name;
                       Ok ())
                     else
                       let* () = require_value k v in
                       let* () =
                         update_service name (fun s ->
                           match k with
                           | "type" ->
                             let* v = scalar k v in
                             Ok { s with typ = Some v }
                           | "path" ->
                             let* v = scalar k v in
                             Ok { s with path = Some v }
                           | "uses" ->
                             (match parse_list v with
                              | Ok uses -> Ok { s with uses }
                              | Error msg -> fail (msg ^ " for uses"))
                           | "omit" ->
                             (match parse_bool v with
                              | Ok omit -> Ok { s with omit }
                              | Error msg -> fail (msg ^ " for omit"))
                           | _ -> fail (Printf.sprintf "unknown service key %S" k))
                       in
                       Ok ()
                   | Target_provider provider ->
                     if v = ""
                     then Ok ()
                     else
                       let* v = scalar k v in
                       update_provider provider (fun fields ->
                         if List.mem_assoc k fields
                         then
                           fail (Printf.sprintf "duplicate %s target field %S" provider k)
                         else Ok (fields @ [ k, v ]))
                   | _ -> fail "unsupported sol.yml syntax"
                 in
                 loop ()
               | 6, _, _ when ends_with ~suffix:":" body ->
                 let* () =
                   match !section with
                   | Resource_indexes resource_name | Resource_index (resource_name, _) ->
                     let index_name = drop_suffix ~suffix:":" body |> trim in
                     update_resource resource_name (fun r ->
                       if List.exists (fun i -> i.index_name = index_name) r.indexes
                       then fail (Printf.sprintf "duplicate index %S" index_name)
                       else (
                         section := Resource_index (resource_name, index_name);
                         Ok { r with indexes = r.indexes @ [ index_empty index_name ] }))
                   | _ -> fail "unsupported sol.yml syntax"
                 in
                 loop ()
               | 6, _, Some (k, v) ->
                 let* () =
                   match !section with
                   | Service_scale name ->
                     let* () = require_value k v in
                     let* () =
                       update_service name (fun s ->
                         match k with
                         | "min" ->
                           (match parse_int v with
                            | Ok scale_min -> Ok { s with scale_min }
                            | Error msg -> fail (msg ^ " for min"))
                         | "max" ->
                           (match parse_int v with
                            | Ok scale_max -> Ok { s with scale_max }
                            | Error msg -> fail (msg ^ " for max"))
                         | _ -> fail (Printf.sprintf "unknown scale key %S" k))
                     in
                     Ok ()
                   | _ -> fail "unsupported sol.yml syntax"
                 in
                 loop ()
               | 8, _, Some (k, v) ->
                 (match !section with
                  | Resource_index (resource_name, index_name)
                    when k = "partition_key" || k = "sort_key" ->
                    let* () = require_value k v in
                    let* v = scalar k v in
                    let update_index i =
                      if i.index_name <> index_name
                      then i
                      else (
                        match k with
                        | "partition_key" -> { i with partition_key = Some v }
                        | "sort_key" -> { i with sort_key = Some v }
                        | _ -> i)
                    in
                    let* () =
                      update_resource resource_name (fun r ->
                        Ok { r with indexes = List.map update_index r.indexes })
                    in
                    loop ()
                  | Resource_indexes _ when k = "partition_key" || k = "sort_key" ->
                    fail "index key must appear under an index name"
                  | _ -> fail (Printf.sprintf "unknown key %S" k))
               | _ -> fail "unsupported sol.yml syntax")
         in
         loop ()))
;;

let prefer a b =
  match b with
  | Some _ -> b
  | None -> a
;;

let prefer_list a b = if b = [] then a else b

let merge_fields a b =
  List.fold_left
    (fun acc (k, v) ->
       upsert_by_name
         fst
         k
         (function
           | None -> k, v
           | Some _ -> k, v)
         acc)
    a
    b
;;

let merge_provider_fields a b =
  List.fold_left
    (fun acc (provider, fields) ->
       upsert_by_name
         fst
         provider
         (function
           | None -> provider, fields
           | Some (_, old_fields) -> provider, merge_fields old_fields fields)
         acc)
    a
    b
;;

let merge_target a b =
  { a with
    registry = prefer a.registry b.registry
  ; base_domain = prefer a.base_domain b.base_domain
  ; cluster_issuer = prefer a.cluster_issuer b.cluster_issuer
  ; cluster_name = prefer a.cluster_name b.cluster_name
  ; kube_context = prefer a.kube_context b.kube_context
  ; terraform_var_file = prefer a.terraform_var_file b.terraform_var_file
  ; observability_backend = prefer a.observability_backend b.observability_backend
  ; provider_fields = merge_provider_fields a.provider_fields b.provider_fields
  }
;;

let merge_resource (a : resource) (b : resource) =
  { name = a.name
  ; typ = prefer a.typ b.typ
  ; partition_key = prefer a.partition_key b.partition_key
  ; sort_key = prefer a.sort_key b.sort_key
  ; indexes = prefer_list a.indexes b.indexes
  ; size = prefer a.size b.size
  ; omit = b.omit || a.omit
  }
;;

let merge_service (a : service) (b : service) =
  { name = a.name
  ; typ = prefer a.typ b.typ
  ; path = prefer a.path b.path
  ; uses = prefer_list a.uses b.uses
  ; scale_min = prefer a.scale_min b.scale_min
  ; scale_max = prefer a.scale_max b.scale_max
  ; omit = b.omit || a.omit
  }
;;

let merge_by name merge xs ys =
  List.fold_left
    (fun acc y ->
       upsert_by_name
         name
         (name y)
         (function
           | None -> y
           | Some x -> merge x y)
         acc)
    xs
    ys
;;

let merge base overlay =
  { project = prefer base.project overlay.project
  ; target =
      (match base.target, overlay.target with
       | None, t | t, None -> t
       | Some a, Some b -> Some (merge_target a b))
  ; resources =
      merge_by
        (fun (r : resource) -> r.name)
        merge_resource
        base.resources
        overlay.resources
  ; services =
      merge_by (fun (s : service) -> s.name) merge_service base.services overlay.services
  }
;;

(* `local` names Sol's own ephemeral substrate, not an environment — it is the
   absence of a target, which is why `SOL_ENV` is deliberately unset there
   (DEC-016). Reserving the word keeps it from also meaning an environment the
   user can select, and keeps one word for one thing (REFAC-083). *)
let reserved_env_name = "local"

let target_of_path s =
  match String.split_on_char '/' s with
  | [ env; provider; region ]
    when env <> ""
         && provider <> ""
         && region <> ""
         && env <> ".."
         && provider <> ".."
         && region <> ".." ->
    if env = reserved_env_name
    then
      Error
        { path = s
        ; line = 0
        ; message =
            Printf.sprintf
              "%S is reserved: it names Sol's own ephemeral cluster — the substrate `sol \
               local up` brings up — not an environment. Name this target for the \
               cluster it points at (`dev`, `staging`, …), even when that cluster is \
               small and yours."
              env
        }
    else (
      match Sol_cli_provider.of_string provider with
      | Some provider ->
        Ok
          { name = s
          ; env
          ; provider
          ; region
          ; registry = None
          ; base_domain = None
          ; cluster_issuer = None
          ; cluster_name = None
          ; kube_context = None
          ; terraform_var_file = None
          ; observability_backend = None
          ; provider_fields = []
          }
      | None ->
        Error
          { path = s
          ; line = 0
          ; message = Printf.sprintf "unsupported provider %S" provider
          })
  | parts when List.exists (( = ) "..") parts ->
    Error { path = s; line = 0; message = "target path must not contain '..'" }
  | _ ->
    Error
      { path = s; line = 0; message = "target must look like <env>/<provider>/<region>" }
;;

let target_file target =
  Filename.concat
    "sol"
    (Filename.concat
       target.env
       (Filename.concat
          (Sol_cli_provider.to_string target.provider)
          (target.region ^ ".yml")))
;;

let active_resources cfg = List.filter (fun (r : resource) -> not r.omit) cfg.resources
let active_services cfg = List.filter (fun (s : service) -> not s.omit) cfg.services

(* The target layout — [sol/<env>/<provider>/<region>.yml] — is known here and
   nowhere else. Every level is traversed through [Sol_cli_fs_walk], so a path
   that exists but cannot be read is reported instead of contributing nothing:
   the same-cluster check must never read "unverified" as "fine". An absent
   [sol/] directory stays a real fact — a workspace with no targets. *)
let discover_target_paths () =
  let failure = ref None in
  let read path select =
    match select path with
    | Ok names -> names
    | Error (Sol_cli_fs_walk.Absent _) -> []
    | Error e ->
      if !failure = None then failure := Some e;
      []
  in
  let paths =
    read "sol" Sol_cli_fs_walk.dirs
    |> List.concat_map (fun env ->
      let env_dir = Filename.concat "sol" env in
      read env_dir Sol_cli_fs_walk.dirs
      |> List.concat_map (fun provider ->
        let provider_dir = Filename.concat env_dir provider in
        read provider_dir Sol_cli_fs_walk.files
        |> List.filter_map (fun file ->
          if Filename.check_suffix file ".yml"
          then
            Some (String.concat "/" [ env; provider; Filename.chop_suffix file ".yml" ])
          else None)))
  in
  match !failure with
  | Some e -> Error { path = "sol"; line = 0; message = Sol_cli_fs_walk.to_string e }
  | None -> Ok (List.sort String.compare paths)
;;

(* Matches the only providers sol.yml's target-provider boxes recognize — no
   third value invented here that nothing else in the codebase
   (cli/platform/infra/) can actually provision against. *)
let known_provider = Sol_cli_provider.is_known

let format_use_ref ref =
  if ref <> "" && ref.[0] = '/' then ref ^ " (cross-region)" else ref
;;

let validate_use_ref ~(target : target) ~resources service_name ref =
  if ref = ""
  then Error { path = target.name; line = 0; message = "empty uses ref" }
  else if ref.[0] <> '/'
  then
    if List.mem ref resources
    then Ok ()
    else
      Error
        { path = target.name
        ; line = 0
        ; message =
            Printf.sprintf "service %S uses undeclared resource %S" service_name ref
        }
  else (
    (* Every branch below requires every segment non-empty, so a ref with
       a blank segment (e.g. "/foo//bar") falls through to the generic
       parse-error case instead of being misclassified as cross-env. *)
    match String.split_on_char '/' ref with
    | [ ""; seg1; seg2 ] when seg1 <> "" && seg2 <> "" ->
      if known_provider seg1
      then
        Error
          { path = target.name
          ; line = 0
          ; message = "cross-provider uses refs are not supported in v1"
          }
      else Ok ()
    | [ ""; seg1; seg2; seg3 ] when seg1 <> "" && seg2 <> "" && seg3 <> "" ->
      if known_provider seg1
      then
        Error
          { path = target.name
          ; line = 0
          ; message = "cross-provider uses refs are not supported in v1"
          }
      else
        Error
          { path = target.name
          ; line = 0
          ; message = "cross-env uses refs are not supported in v1"
          }
    | "" :: (_ :: _ :: _ :: _ :: _ as segs) when List.for_all (( <> ) "") segs ->
      Error
        { path = target.name
        ; line = 0
        ; message = "cross-env uses refs are not supported in v1"
        }
    | _ ->
      Error
        { path = target.name
        ; line = 0
        ; message = "absolute uses ref must look like /<region>/<resource>"
        })
;;

let validate_uses cfg =
  match cfg.target with
  | None -> Ok cfg
  | Some target ->
    let resource_names =
      active_resources cfg |> List.map (fun (r : resource) -> r.name)
    in
    let rec validate_services = function
      | [] -> Ok cfg
      | service :: rest ->
        let rec validate_refs = function
          | [] -> validate_services rest
          | ref :: refs ->
            let* () =
              validate_use_ref ~target ~resources:resource_names service.name ref
            in
            validate_refs refs
        in
        validate_refs service.uses
    in
    validate_services (active_services cfg)
;;

let resolved_target base target_path =
  let* target = target_of_path target_path in
  let* overlay = load (target_file target) in
  let base_target =
    match base.target with
    | None -> target
    | Some t ->
      { t with
        name = target.name
      ; env = target.env
      ; provider = target.provider
      ; region = target.region
      }
  in
  match (merge { base with target = Some base_target } overlay).target with
  | Some target -> Ok target
  | None -> assert false
;;

(** Where this target deploys. Fails closed when it names no context, and when it
    names Sol's own cluster.

    REFAC-086: the reservation of the *name* [reserved_env_name] stops a target
    being called "local"; this stops one being pointed at the same cluster, which
    would hand target semantics — credentials, [SOL_ENV], target identity, release
    history — to Sol's ephemeral substrate and recreate a synthetic local target
    through the back door.

    Compared through the destination abstraction rather than a repeated literal, so
    changing the local context cannot silently disarm the check. Structural
    equality is deliberate: a field added to the destination type keeps this
    correct, where a hand-written [equal] could drift.

    Deliberately not folded into [validate_no_same_cluster]: that one is about
    relationships among configured environments, this is about a reserved
    execution mode. *)
let destination_of_target (target : target) =
  let* destination =
    Sol_cli_kube_destination.of_context (Option.value target.kube_context ~default:"")
  in
  let reserved = Sol_cli_kube_destination.local in
  if destination = reserved
  then
    Error
      (Printf.sprintf
         "this target resolves to %s, Sol's own cluster, which is a reserved execution \
          mode rather than a target: use `sol local <command>` for it, and point this \
          target at a cluster you own"
         (Sol_cli_kube_destination.to_string reserved))
  else Ok destination
;;

(* The same-cluster lint compares the destination Sol will actually use, not the
   descriptive [cluster_name]. Two fields describing the same property would be
   two sources of truth for exactly what this check protects — the lint could
   verify one field while the deploy landed via the other. Contexts are compared
   together with the kubeconfig they came from, because the same context name in
   two different kubeconfigs can be two different clusters.

   [None] means the destination cannot be resolved, so there is nothing to
   compare; such a target fails closed at deploy time instead. *)
let destination_identity target =
  match destination_of_target target with
  | Error _ -> None
  | Ok destination -> Some (destination.kubeconfig, destination.context)
;;

let validate_no_same_cluster base (selected : target) =
  let* paths = discover_target_paths () in
  let rec loop = function
    | [] -> Ok ()
    | path :: rest ->
      if path = selected.name
      then loop rest
      else (
        (* A target that cannot be read or resolved is an environment whose
           cluster we cannot check. Failing here is the point: an unverified
           environment must not pass as a verified one. *)
        match resolved_target base path with
        | Error error -> Error error
        | Ok (other : target) ->
          (match destination_identity selected, destination_identity other with
           | Some (kubeconfig, context), Some other_destination
             when selected.env <> other.env && (kubeconfig, context) = other_destination
             ->
             Error
               { path = selected.name
               ; line = 0
               ; message =
                   Printf.sprintf
                     "environments %S and %S both deploy to Kubernetes context %S, so \
                      they would share namespaces, service names and injected URLs — \
                      which are deliberately identical in every environment (DEC-016). \
                      Point one of them at a different target."
                     selected.env
                     other.env
                     context
               }
           | _ -> loop rest))
  in
  loop paths
;;

let load_for_target ~target =
  let* target = target_of_path target in
  let file = target_file target in
  let* () =
    if Sys.file_exists "sol.yml" || Sys.file_exists file
    then Ok ()
    else
      Error
        { path = target.name
        ; line = 0
        ; message =
            Printf.sprintf
              "target %S resolves to neither a sol.yml nor a \
               sol/<env>/<provider>/<region>.yml in this directory — at least one must \
               exist for a target to be real, not just shaped like \
               <env>/<provider>/<region>"
              target.name
        }
  in
  let* base = load "sol.yml" in
  let* overlay = load file in
  let base_target =
    match base.target with
    | None -> target
    | Some t ->
      { t with
        name = target.name
      ; env = target.env
      ; provider = target.provider
      ; region = target.region
      }
  in
  let cfg = merge { base with target = Some base_target } overlay in
  let* cfg = validate_uses cfg in
  match cfg.target with
  | None -> Ok cfg
  | Some target ->
    let* () = validate_no_same_cluster base target in
    Ok cfg
;;

let target cfg = cfg.target
let resources cfg = active_resources cfg
let services cfg = active_services cfg

(* Every service in the workspace gets an ECR repository, regardless of
   which target is currently being planned/applied -- a service omitted
   from one target may still be deployed to another and needs its own
   repository either way.

   discover_services requires an app/ directory and exits the process if
   one isn't found -- appropriate for the top-level CLI commands it was
   written for, but terraform_vars must stay callable (e.g. from tests, or
   any future caller) without an app/ directory in cwd, so this degrades to
   "no auto-detected repositories" instead of inheriting that exit. *)
let ecr_repositories_var () =
  let services =
    if Sys.file_exists "app" && Sys.is_directory "app"
    then Sol_cli_manifest.discover_services ()
    else []
  in
  services
  |> List.filter_map (fun (s : Sol_cli_manifest.service) ->
    match Sol_cli_kubernetes_name.k8s_name_of_source s.Sol_cli_manifest.name with
    | Ok name -> Some (Sol_cli_kubernetes_name.k8s_name_to_string name)
    | Error _ -> None)
  |> List.map (Printf.sprintf "%S")
  |> String.concat ","
  |> Printf.sprintf "[%s]"
;;

let terraform_vars ~workspace cfg =
  match cfg.target with
  | None -> Error "target missing"
  | Some target ->
    let add_opt k = function
      | None -> Fun.id
      | Some v -> fun xs -> (k, v) :: xs
    in
    let vars =
      []
      |> add_opt "region" (Some target.region)
      |> add_opt "cluster_name" target.cluster_name
      |> add_opt "base_domain" target.base_domain
      |> add_opt "cluster_issuer" target.cluster_issuer
      |> add_opt "workspace_name" (Some workspace)
    in
    let vars =
      List.assoc_opt (Sol_cli_provider.to_string target.provider) target.provider_fields
      |> Option.value ~default:[]
      |> List.rev_append vars
    in
    let has_postgres =
      resources cfg |> List.exists (fun (r : resource) -> r.typ = Some "postgres")
    in
    Ok
      (("create_rds", string_of_bool has_postgres)
       :: ("ecr_repositories", ecr_repositories_var ())
       :: vars)
;;
