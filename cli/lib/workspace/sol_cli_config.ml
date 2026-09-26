type target =
  { name : string
  ; env : string
  ; provider : Sol_cli_provider.t
  ; region : string
  ; registry : string option
  ; base_domain : string option
  ; cluster_issuer : string option
  ; letsencrypt_email : string option
  ; cluster_name : string option
  ; kube_context : string option
  ; kubeconfig : string option
  ; terraform_var_file : string option
  ; observability_backend : string option
    (* DEC-033: what `sol cloud destroy` deliberately keeps. Absent means the
     production default (retain the final snapshot); a disposable qualification
     target sets `destroy_retention: none`, so its postcondition is Absent with
     nothing billable left behind. *)
  ; destroy_retention : string option
    (* The identity allowed to enter this target's install window, by impersonating
       the platform provisioner. GCP requires that grant explicitly -- creating the
       identity does not let anyone use it (Attempt 2) -- and AWS's equivalent is the
       provisioner role's trust policy, so this is routed to the GCP root only.

       Declared rather than inferred, deliberately: "no caller named" must mean "no
       impersonation grant", not "grant whoever is running Sol". Inferring it is the
       ambient-authority escape hatch this field exists to close. *)
  ; alert_receiver_type : string option
  ; alert_receiver_url : string option
  ; alert_owner : string option
  ; alert_runbook_url : string option
  ; state_bucket : string option
  ; cluster_endpoint_cidr : string option
  ; node_failure_headroom_nodes : int option
  ; profile : Sol_cli_profile.t option
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
  ; language : Sol_cli_compat.language option
    (** FEAT-088: the framework language implementing this workload, declared in
          [sol.yml]. The production profile qualifies only OCaml; this is an
          explicit input, never inferred from build metadata. *)
  ; omit : bool
  }

(* What one file contributes: sol.yml, an environment, or a target (REFAC-109).
   Its target is optional because a layer need not say anything about one. *)
type layer =
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
  ; letsencrypt_email = None
  ; cluster_name = None
  ; kube_context = None
  ; kubeconfig = None
  ; terraform_var_file = None
  ; observability_backend = None
  ; destroy_retention = None
  ; alert_receiver_type = None
  ; alert_receiver_url = None
  ; alert_owner = None
  ; alert_runbook_url = None
  ; state_bucket = None
  ; cluster_endpoint_cidr = None
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; provider_fields = []
  }
;;

let empty = { project = None; target = None; resources = []; services = [] }

type error =
  { path : string
  ; line : int
  ; message : string
  }

let error_to_string e =
  if e.line > 0
  then Printf.sprintf "%s:%d: %s" e.path e.line e.message
  else Printf.sprintf "%s: %s" e.path e.message
;;

let ( let* ) = Result.bind
let trim = String.trim

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
  ; language = None
  ; omit = false
  }
;;

type target_key =
  | Target_registry
  | Target_base_domain
  | Target_cluster_issuer
  | Target_letsencrypt_email
  | Target_cluster_name
  | Target_kube_context
  | Target_kubeconfig
  | Target_terraform_var_file
  | Target_observability_backend
  | Target_destroy_retention
  | Target_alert_receiver_type
  | Target_alert_receiver_url
  | Target_alert_owner
  | Target_alert_runbook_url
  | Target_state_bucket
  | Target_cluster_endpoint_cidr
  | Target_node_failure_headroom_nodes
  | Target_profile
  | Target_provider_box of Sol_cli_provider.t
  | Target_provider_owned of string * Sol_cli_provider.t
  (** A key a provider owns (REFAC-098): [(key, provider)]. The provider is a constructor,
      not a spelling: the knowledge is a data list in the provider tier
      ([Sol_cli_provider.owned_legacy_keys]), where the boundary guard can see it
      (AUDIT-POST-003). *)
  | Target_unknown of string

let target_key_of_string s =
  match s with
  | "registry" -> Target_registry
  | "base_domain" -> Target_base_domain
  | "cluster_issuer" -> Target_cluster_issuer
  | "letsencrypt_email" -> Target_letsencrypt_email
  | "cluster_name" -> Target_cluster_name
  | "kube_context" -> Target_kube_context
  | "kubeconfig" -> Target_kubeconfig
  | "terraform_var_file" -> Target_terraform_var_file
  | "observability_backend" -> Target_observability_backend
  | "destroy_retention" -> Target_destroy_retention
  | "alert_receiver_type" -> Target_alert_receiver_type
  | "alert_receiver_url" -> Target_alert_receiver_url
  | "alert_owner" -> Target_alert_owner
  | "alert_runbook_url" -> Target_alert_runbook_url
  | "state_bucket" -> Target_state_bucket
  | "cluster_endpoint_cidr" -> Target_cluster_endpoint_cidr
  | "node_failure_headroom_nodes" -> Target_node_failure_headroom_nodes
  | "profile" -> Target_profile
  (* REFAC-098: provider-native identity lives in the provider's own block, so a
     target on one provider can never carry another's. Which keys those are is the
     provider tier's to say (AUDIT-POST-003). *)
  | _ ->
    (match Sol_cli_provider.owned_legacy_key s with
     | Some provider -> Target_provider_owned (s, provider)
     | None ->
       (match Sol_cli_provider.of_string s with
        | Some provider -> Target_provider_box provider
        | None -> Target_unknown s))
;;

let target_key_name = function
  | Target_registry -> "registry"
  | Target_base_domain -> "base_domain"
  | Target_cluster_issuer -> "cluster_issuer"
  | Target_letsencrypt_email -> "letsencrypt_email"
  | Target_cluster_name -> "cluster_name"
  | Target_kube_context -> "kube_context"
  | Target_kubeconfig -> "kubeconfig"
  | Target_terraform_var_file -> "terraform_var_file"
  | Target_observability_backend -> "observability_backend"
  | Target_destroy_retention -> "destroy_retention"
  | Target_alert_receiver_type -> "alert_receiver_type"
  | Target_alert_receiver_url -> "alert_receiver_url"
  | Target_alert_owner -> "alert_owner"
  | Target_alert_runbook_url -> "alert_runbook_url"
  | Target_state_bucket -> "state_bucket"
  | Target_cluster_endpoint_cidr -> "cluster_endpoint_cidr"
  | Target_node_failure_headroom_nodes -> "node_failure_headroom_nodes"
  | Target_profile -> "profile"
  | Target_provider_box provider -> Sol_cli_provider.to_string provider
  | Target_provider_owned (s, _) -> s
  | Target_unknown s -> s
;;

(* REFAC-106: sol.yml and target files are YAML, parsed by libyaml (the `yaml`
   package) and decoded here against the key table above. The decoder walks
   [Yaml.yaml] rather than [Yaml.value] because a scalar there keeps the exact text
   the user wrote: `1.10`, `012` and an account id stay strings, where the value API
   would have made numbers of them. Errors name the key path, and a YAML syntax
   error names its line. *)

let fail_at ~path message = Error { path; line = 0; message }

(* libyaml's own error message carries no usable position, so the line comes from
   the event stream: the last event parsed before the failure. *)
let syntax_error_line text =
  match Yaml.Stream.parser text with
  | Error _ -> 0
  | Ok parser ->
    let rec go last =
      match Yaml.Stream.do_parse parser with
      | Error _ -> last
      | Ok (Yaml.Stream.Event.Stream_end, _) -> last
      | Ok (_, (pos : Yaml.Stream.Event.pos)) -> go (pos.end_mark.line + 1)
    in
    go 1
;;

let yaml_problem message =
  (* "error calling parser: <problem> character 0 position 0 returned: 0" *)
  let prefix = "error calling parser: " in
  let m =
    if
      String.length message >= String.length prefix
      && String.sub message 0 (String.length prefix) = prefix
    then
      String.sub
        message
        (String.length prefix)
        (String.length message - String.length prefix)
    else message
  in
  match String.index_opt m '\n' with
  | Some i -> String.sub m 0 i
  | None ->
    let marker = " character " in
    let rec find i =
      if i + String.length marker > String.length m
      then m
      else if String.sub m i (String.length marker) = marker
      then String.sub m 0 i
      else find (i + 1)
    in
    find 0
;;

let parse_yaml ~path text =
  match Yaml.yaml_of_string text with
  | Ok doc -> Ok doc
  | Error (`Msg message) ->
    Error
      { path
      ; line = syntax_error_line text
      ; message = "invalid YAML: " ^ yaml_problem message
      }
;;

(* The text of a scalar; [None] for an empty/null one, which every key treats as a
   missing value. *)
let scalar_text : Yaml.yaml -> string option = function
  | `Scalar { Yaml.value; style; _ } ->
    let quoted =
      match style with
      | `Single_quoted | `Double_quoted -> true
      | _ -> false
    in
    if (not quoted) && (value = "" || value = "~" || value = "null")
    then None
    else Some value
  | _ -> None
;;

let is_null : Yaml.yaml -> bool = function
  | `Scalar _ as y -> scalar_text y = None
  | _ -> false
;;

(* A mapping's members as (key, value), rejecting a non-scalar key, an alias and a
   duplicate key: YAML leaves duplicates to the application, and a second value
   silently winning is exactly the ambiguity a config file must not have. *)
let members
      ~path
      ~where
      ?(duplicate = fun k -> Printf.sprintf "duplicate key %S%s" k where)
  = function
  | `O { Yaml.m_members; _ } ->
    let rec go seen acc = function
      | [] -> Ok (List.rev acc)
      | (`Scalar { Yaml.value = k; _ }, v) :: rest ->
        if List.mem k seen
        then fail_at ~path (duplicate k)
        else (
          match v with
          | `Alias _ ->
            fail_at ~path (Printf.sprintf "YAML aliases are not supported (%S%s)" k where)
          | _ -> go (k :: seen) ((k, v) :: acc) rest)
      | _ :: _ -> fail_at ~path (Printf.sprintf "expected text keys%s" where)
    in
    go [] [] m_members
  | y when is_null y -> Ok []
  | _ -> fail_at ~path (Printf.sprintf "expected a mapping%s" where)
;;

(* One layer's keys. [~top_level:true] is sol.yml's shape (project, target,
   resources, services). Otherwise it is an environment or a target body in
   sol/environments.yml (FEAT-100): target keys sit directly in the body, next to
   resources and services, and errors name the [context] they came from. *)
let decode_layer ~path ~context ~top_level (fields : (string * Yaml.yaml) list) =
  let fail message =
    fail_at ~path (if context = "" then message else context ^ ": " ^ message)
  in
  let value name v =
    match v with
    | `Scalar _ ->
      (match scalar_text v with
       | Some s -> Ok s
       | None -> fail (Printf.sprintf "missing value for %s" name))
    | _ -> fail (Printf.sprintf "expected a single value for %s" name)
  in
  let int_value name v =
    let* s = value name v in
    match parse_int s with
    | Ok n -> Ok n
    | Error msg -> fail (msg ^ " for " ^ name)
  in
  let bool_value name v =
    let* s = value name v in
    match parse_bool s with
    | Ok b -> Ok b
    | Error msg -> fail (msg ^ " for " ^ name)
  in
  let rec fold f acc = function
    | [] -> Ok acc
    | x :: rest ->
      let* acc = f acc x in
      fold f acc rest
  in
  let decode_provider provider v =
    let where = Printf.sprintf " in the %s target block" provider in
    let* fields =
      members
        ~path
        ~where
        ~duplicate:(Printf.sprintf "duplicate %s target field %S" provider)
        v
    in
    (* A nested value under a provider field is ignored, as it always was. *)
    Ok (List.filter_map (fun (k, v) -> Option.map (fun t -> k, t) (scalar_text v)) fields)
  in
  let decode_target_fields fields =
    fold
      (fun (current : target) (k, v) ->
         match target_key_of_string k with
         | Target_provider_box provider ->
           let provider = Sol_cli_provider.to_string provider in
           let* fields = decode_provider provider v in
           Ok
             { current with
               provider_fields = current.provider_fields @ [ provider, fields ]
             }
         | Target_unknown k ->
           (match v with
            | `O _ -> fail (Printf.sprintf "unsupported provider %S" k)
            | _ when is_null v -> fail (Printf.sprintf "unsupported provider %S" k)
            | _ -> fail (Printf.sprintf "unknown target key %S" k))
         | Target_provider_owned (k, provider) ->
           let provider = Sol_cli_provider.to_string provider in
           fail
             (Printf.sprintf
                "target key %S belongs to the %s provider: declare it as `%s.%s` inside \
                 the target block (REFAC-098)"
                k
                provider
                provider
                k)
         | key ->
           let name = target_key_name key in
           let* s = value name v in
           (match key with
            | Target_registry -> Ok { current with registry = Some s }
            | Target_base_domain -> Ok { current with base_domain = Some s }
            | Target_cluster_issuer -> Ok { current with cluster_issuer = Some s }
            | Target_letsencrypt_email -> Ok { current with letsencrypt_email = Some s }
            | Target_cluster_name -> Ok { current with cluster_name = Some s }
            | Target_kube_context -> Ok { current with kube_context = Some s }
            | Target_kubeconfig -> Ok { current with kubeconfig = Some s }
            | Target_terraform_var_file -> Ok { current with terraform_var_file = Some s }
            | Target_observability_backend ->
              Ok { current with observability_backend = Some s }
            | Target_destroy_retention -> Ok { current with destroy_retention = Some s }
            | Target_alert_receiver_type ->
              Ok { current with alert_receiver_type = Some s }
            | Target_alert_receiver_url -> Ok { current with alert_receiver_url = Some s }
            | Target_alert_owner -> Ok { current with alert_owner = Some s }
            | Target_alert_runbook_url -> Ok { current with alert_runbook_url = Some s }
            | Target_state_bucket -> Ok { current with state_bucket = Some s }
            | Target_cluster_endpoint_cidr ->
              Ok { current with cluster_endpoint_cidr = Some s }
            | Target_node_failure_headroom_nodes ->
              (match parse_int s with
               | Ok n -> Ok { current with node_failure_headroom_nodes = n }
               | Error _ -> fail "expected integer for node_failure_headroom_nodes")
            | Target_profile ->
              (match Sol_cli_profile.of_selection s with
               | Ok profile -> Ok { current with profile = Some profile }
               | Error msg -> fail msg)
            | Target_provider_box _ | Target_provider_owned _ | Target_unknown _ ->
              assert false))
      target_empty
      fields
  in
  let decode_target v =
    let* fields =
      members
        ~path
        ~where:" in target"
        ~duplicate:(fun k ->
          match Sol_cli_provider.of_string k with
          | Some _ -> Printf.sprintf "duplicate target provider box %S" k
          | None -> Printf.sprintf "duplicate target key %S" k)
        v
    in
    decode_target_fields fields
  in
  let decode_index (name, v) =
    let where = Printf.sprintf " in index %S" name in
    let* fields = members ~path ~where v in
    fold
      (fun (i : index) (k, v) ->
         match k with
         | "partition_key" ->
           let* s = value k v in
           Ok { i with partition_key = Some s }
         | "sort_key" ->
           let* s = value k v in
           Ok { i with sort_key = Some s }
         | _ -> fail (Printf.sprintf "unknown key %S" k))
      (index_empty name)
      fields
  in
  let decode_resource (name, v) =
    let* fields = members ~path ~where:(Printf.sprintf " in resource %S" name) v in
    fold
      (fun (r : resource) (k, v) ->
         match k with
         | "type" ->
           let* s = value k v in
           Ok { r with typ = Some s }
         | "partition_key" ->
           let* s = value k v in
           Ok { r with partition_key = Some s }
         | "sort_key" ->
           let* s = value k v in
           Ok { r with sort_key = Some s }
         | "size" ->
           let* s = value k v in
           Ok { r with size = Some s }
         | "omit" ->
           let* omit = bool_value k v in
           Ok { r with omit }
         | "indexes" ->
           let* indexes =
             members
               ~path
               ~where:(Printf.sprintf " in resource %S" name)
               ~duplicate:(Printf.sprintf "duplicate index %S")
               v
           in
           let* indexes =
             fold
               (fun acc i ->
                  let* i = decode_index i in
                  Ok (acc @ [ i ]))
               []
               indexes
           in
           Ok { r with indexes }
         | _ -> fail (Printf.sprintf "unknown resource key %S" k))
      (resource_empty name)
      fields
  in
  let decode_uses v =
    match v with
    | `A { Yaml.s_members; _ } ->
      fold
        (fun acc item ->
           match scalar_text item with
           | Some s -> Ok (acc @ [ s ])
           | None -> fail "expected a list of names for uses")
        []
        s_members
    | _ when is_null v -> Ok []
    | `Scalar _ -> Ok (Option.to_list (scalar_text v))
    | _ -> fail "expected a list of names for uses"
  in
  let decode_service (name, v) =
    let* fields = members ~path ~where:(Printf.sprintf " in service %S" name) v in
    fold
      (fun (sv : service) (k, v) ->
         match k with
         | "type" ->
           let* s = value k v in
           Ok { sv with typ = Some s }
         | "path" ->
           let* s = value k v in
           Ok { sv with path = Some s }
         | "uses" ->
           let* uses = decode_uses v in
           Ok { sv with uses }
         | "language" ->
           let* s = value k v in
           (match Sol_cli_compat.of_string s with
            | Ok language -> Ok { sv with language = Some language }
            | Error msg -> fail (msg ^ " for language"))
         | "omit" ->
           let* omit = bool_value k v in
           Ok { sv with omit }
         | "scale" ->
           let* scale =
             members ~path ~where:(Printf.sprintf " in service %S scale" name) v
           in
           fold
             (fun (sv : service) (k, v) ->
                match k with
                | "min" ->
                  let* n = int_value k v in
                  Ok { sv with scale_min = n }
                | "max" ->
                  let* n = int_value k v in
                  Ok { sv with scale_max = n }
                | _ -> fail (Printf.sprintf "unknown scale key %S" k))
             sv
             scale
         | _ -> fail (Printf.sprintf "unknown service key %S" k))
      (service_empty name)
      fields
  in
  let section cfg (k, v) =
    match k with
    | "project" when not top_level ->
      fail "project belongs in sol.yml, not in an environment or target"
    | "target" when not top_level ->
      fail "put target keys directly here, not in a target: block"
    | "project" ->
      let* p = value "project" v in
      Ok { cfg with project = Some p }
    | "target" ->
      let* t = decode_target v in
      Ok { cfg with target = Some t }
    | "resources" ->
      let* named =
        members
          ~path
          ~where:" in resources"
          ~duplicate:(Printf.sprintf "duplicate resource %S")
          v
      in
      let* resources =
        fold
          (fun acc r ->
             let* r = decode_resource r in
             Ok (acc @ [ r ]))
          []
          named
      in
      Ok { cfg with resources }
    | "services" ->
      let* named =
        members
          ~path
          ~where:" in services"
          ~duplicate:(Printf.sprintf "duplicate service %S")
          v
      in
      let* services =
        fold
          (fun acc x ->
             let* x = decode_service x in
             Ok (acc @ [ x ]))
          []
          named
      in
      Ok { cfg with services }
    | _ -> fail (Printf.sprintf "unknown top-level key %S" k)
  in
  if top_level
  then fold section empty fields
  else (
    let is_section (k, _) = List.mem k [ "project"; "target"; "resources"; "services" ] in
    let sections, target_keys = List.partition is_section fields in
    let* cfg = fold section empty sections in
    if target_keys = []
    then Ok cfg
    else
      let* t = decode_target_fields target_keys in
      Ok { cfg with target = Some t })
;;

let load_string ~path text =
  let* doc = parse_yaml ~path text in
  let* top =
    members
      ~path
      ~where:""
      ~duplicate:(Printf.sprintf "duplicate top-level section %S")
      doc
  in
  decode_layer ~path ~context:"" ~top_level:true top
;;

let load path =
  if not (Sys.file_exists path)
  then Ok empty
  else load_string ~path (In_channel.with_open_bin path In_channel.input_all)
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

(* REFAC-098: a value from the target's own provider block. Provider-native
   configuration (role ARNs, the state lock table, the GCP impersonator) lives
   there, read by that provider's code, so a target on one provider has no field
   for another's. *)
let provider_field (target : target) key =
  List.assoc_opt (Sol_cli_provider.to_string target.provider) target.provider_fields
  |> Option.value ~default:[]
  |> List.assoc_opt key
;;

let merge_target a b =
  { a with
    registry = prefer a.registry b.registry
  ; base_domain = prefer a.base_domain b.base_domain
  ; cluster_issuer = prefer a.cluster_issuer b.cluster_issuer
  ; letsencrypt_email = prefer a.letsencrypt_email b.letsencrypt_email
  ; cluster_name = prefer a.cluster_name b.cluster_name
  ; kube_context = prefer a.kube_context b.kube_context
  ; kubeconfig = prefer a.kubeconfig b.kubeconfig
  ; terraform_var_file = prefer a.terraform_var_file b.terraform_var_file
  ; observability_backend =
      prefer a.observability_backend b.observability_backend
      (* DEC-033 added the field but not this line, so the setting was dropped on the
     only path a real target is resolved through: `{ a with ... }` keeps the
     *base*'s value and discards the target file's, which meant a disposable
     target's `destroy_retention: none` was silently ignored and every destroy took
     the production default. DEC-033's own tests construct [target_empty] directly
     and so never crossed the merge, which is the shape of gap that a test has to
     cross on purpose rather than by accident. *)
  ; destroy_retention = prefer a.destroy_retention b.destroy_retention
  ; alert_receiver_type = prefer a.alert_receiver_type b.alert_receiver_type
  ; alert_receiver_url = prefer a.alert_receiver_url b.alert_receiver_url
  ; alert_owner = prefer a.alert_owner b.alert_owner
  ; alert_runbook_url = prefer a.alert_runbook_url b.alert_runbook_url
  ; state_bucket = prefer a.state_bucket b.state_bucket
  ; cluster_endpoint_cidr = prefer a.cluster_endpoint_cidr b.cluster_endpoint_cidr
  ; node_failure_headroom_nodes =
      prefer a.node_failure_headroom_nodes b.node_failure_headroom_nodes
  ; profile = prefer a.profile b.profile
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
  ; language = prefer a.language b.language
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
               local infra up` brings up — not an environment. Name this target for the \
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
          ; letsencrypt_email = None
          ; cluster_name = None
          ; kube_context = None
          ; kubeconfig = None
          ; terraform_var_file = None
          ; observability_backend = None
          ; destroy_retention = None
          ; alert_receiver_type = None
          ; alert_receiver_url = None
          ; alert_owner = None
          ; alert_runbook_url = None
          ; state_bucket = None
          ; cluster_endpoint_cidr = None
          ; node_failure_headroom_nodes = None
          ; profile = None
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

(* Config and target paths resolve relative to the resolved workspace root, not
   the invocation cwd, so `sol plan`/`sol deploy` work from any descendant
   directory (DEC-024 clause 4). [find_root] is cheap and marker-free; when
   there is no workspace the command has already failed closed in
   [load_for_target], so target-name-only formatting falls back to a
   root-relative path. *)
let workspace_root () =
  match Sol_cli_workspace.find_root ~dir:(Sys.getcwd ()) with
  | Some root -> root
  | None -> "."
;;

let rooted path = Filename.concat (workspace_root ()) path

(* FEAT-100 / DEC-047: deployment config is sol.yml -> environment -> target.
   Environments and their targets live in sol/environments.yml; an optional,
   gitignored sol/environments.local.yml supplies account-specific values the
   tracked file leaves unset, and may add whole environments or targets (the
   2026-09-26 amendment). A key comes from exactly one of the two files. *)
let environments_file = "sol/environments.yml"
let environments_local_file = "sol/environments.local.yml"

type environment =
  { env_name : string
  ; layer : layer
  ; targets : (string * layer) list (** keyed ["<provider>/<region>"] *)
  }

let rec fold_result f acc = function
  | [] -> Ok acc
  | x :: rest ->
    let* acc = f acc x in
    fold_result f acc rest
;;

let target_key_ok key =
  match String.split_on_char '/' key with
  | [ provider; region ] when provider <> "" && region <> "" && region <> ".." ->
    (match Sol_cli_provider.of_string provider with
     | Some _ -> Ok ()
     | None -> Error (Printf.sprintf "unsupported provider %S" provider))
  | _ -> Error "a target must look like <provider>/<region>"
;;

(* DEC-047's placement table: keys that identify one cluster or region. *)
let target_only_keys (t : target) =
  List.filter_map
    (fun (name, set) -> if set then Some name else None)
    [ "cluster_name", t.cluster_name <> None
    ; "kube_context", t.kube_context <> None
    ; "kubeconfig", t.kubeconfig <> None
    ; "cluster_endpoint_cidr", t.cluster_endpoint_cidr <> None
    ; "registry", t.registry <> None
    ]
;;

(* ... and keys that describe the application's shape, which only sol.yml may set:
   an environment or target adjusts size, scale and omit, nothing else. *)
let app_shape_keys (l : layer) =
  List.concat_map
    (fun (r : resource) ->
       List.filter_map
         (fun (name, set) ->
            if set then Some (Printf.sprintf "resources.%s.%s" r.name name) else None)
         [ "type", r.typ <> None
         ; "partition_key", r.partition_key <> None
         ; "sort_key", r.sort_key <> None
         ; "indexes", r.indexes <> []
         ])
    l.resources
  @ List.concat_map
      (fun (sv : service) ->
         List.filter_map
           (fun (name, set) ->
              if set then Some (Printf.sprintf "services.%s.%s" sv.name name) else None)
           [ "type", sv.typ <> None
           ; "path", sv.path <> None
           ; "language", sv.language <> None
           ; "uses", sv.uses <> []
           ])
      l.services
;;

let check_placement ~path (e : environment) =
  let fail context message =
    Error { path; line = 0; message = context ^ ": " ^ message }
  in
  let app_shape context layer =
    match app_shape_keys layer with
    | [] -> Ok ()
    | key :: _ ->
      fail
        context
        (Printf.sprintf
           "%s belongs in sol.yml: an environment or target may only adjust size, scale \
            and omit (DEC-047)"
           key)
  in
  let* () =
    match Option.map target_only_keys e.layer.target with
    | Some (key :: _) ->
      fail
        e.env_name
        (Printf.sprintf
           "%s is target-only: set it under %s.targets.<provider>/<region> (DEC-047)"
           key
           e.env_name)
    | _ -> Ok ()
  in
  let* () = app_shape e.env_name e.layer in
  fold_result
    (fun () (key, layer) -> app_shape (e.env_name ^ ".targets." ^ key) layer)
    ()
    e.targets
;;

let decode_environments ~path doc =
  let* envs =
    members ~path ~where:"" ~duplicate:(Printf.sprintf "duplicate environment %S") doc
  in
  fold_result
    (fun acc (env_name, v) ->
       let* fields =
         members ~path ~where:(Printf.sprintf " in environment %S" env_name) v
       in
       let targets_field, body = List.partition (fun (k, _) -> k = "targets") fields in
       let* layer = decode_layer ~path ~context:env_name ~top_level:false body in
       let* targets =
         match targets_field with
         | [] -> Ok []
         | (_, tv) :: _ ->
           let* named =
             members
               ~path
               ~where:(Printf.sprintf " in %s.targets" env_name)
               ~duplicate:(Printf.sprintf "duplicate target %S")
               tv
           in
           fold_result
             (fun acc (key, bv) ->
                let context = env_name ^ ".targets." ^ key in
                let* () =
                  match target_key_ok key with
                  | Ok () -> Ok ()
                  | Error m -> Error { path; line = 0; message = context ^ ": " ^ m }
                in
                let* fields = members ~path ~where:(" in " ^ context) bv in
                let* body = decode_layer ~path ~context ~top_level:false fields in
                Ok (acc @ [ key, body ]))
             []
             named
       in
       let e = { env_name; layer; targets } in
       let* () = check_placement ~path e in
       Ok (acc @ [ e ]))
    []
    envs
;;

let load_environments_file path =
  if not (Sys.file_exists path)
  then Ok []
  else (
    let text = In_channel.with_open_bin path In_channel.input_all in
    let* doc = parse_yaml ~path text in
    decode_environments ~path doc)
;;

(* Every key a layer sets, as a path, for the disjoint rule. *)
let layer_keys (l : layer) =
  let opt name o = if o = None then [] else [ name ] in
  let target_keys =
    match l.target with
    | None -> []
    | Some t ->
      List.concat
        [ opt "registry" t.registry
        ; opt "base_domain" t.base_domain
        ; opt "cluster_issuer" t.cluster_issuer
        ; opt "letsencrypt_email" t.letsencrypt_email
        ; opt "cluster_name" t.cluster_name
        ; opt "kube_context" t.kube_context
        ; opt "kubeconfig" t.kubeconfig
        ; opt "terraform_var_file" t.terraform_var_file
        ; opt "observability_backend" t.observability_backend
        ; opt "destroy_retention" t.destroy_retention
        ; opt "alert_receiver_type" t.alert_receiver_type
        ; opt "alert_receiver_url" t.alert_receiver_url
        ; opt "alert_owner" t.alert_owner
        ; opt "alert_runbook_url" t.alert_runbook_url
        ; opt "state_bucket" t.state_bucket
        ; opt "cluster_endpoint_cidr" t.cluster_endpoint_cidr
        ; opt "node_failure_headroom_nodes" t.node_failure_headroom_nodes
        ; opt "profile" t.profile
        ]
      @ List.concat_map
          (fun (provider, fields) -> List.map (fun (k, _) -> provider ^ "." ^ k) fields)
          t.provider_fields
  in
  target_keys
  @ List.concat_map
      (fun (r : resource) ->
         let p = "resources." ^ r.name ^ "." in
         opt (p ^ "size") r.size @ if r.omit then [ p ^ "omit" ] else [])
      l.resources
  @ List.concat_map
      (fun (sv : service) ->
         let p = "services." ^ sv.name ^ "." in
         opt (p ^ "scale.min") sv.scale_min
         @ opt (p ^ "scale.max") sv.scale_max
         @ if sv.omit then [ p ^ "omit" ] else [])
      l.services
;;

let disjoint ~path ~context tracked local =
  match List.filter (fun k -> List.mem k (layer_keys tracked)) (layer_keys local) with
  | [] -> Ok ()
  | key :: _ ->
    Error
      { path
      ; line = 0
      ; message =
          Printf.sprintf
            "%s: %s is already set in %s; the local file may only add keys the tracked \
             file leaves unset (DEC-047)"
            context
            key
            environments_file
      }
;;

(* The union of the tracked and local files: whole environments and targets the
   local file adds are appended; keys it adds to a tracked one must be disjoint. *)
let union_environments ~local_path ~tracked ~local =
  fold_result
    (fun acc (l : environment) ->
       match List.find_opt (fun e -> e.env_name = l.env_name) acc with
       | None -> Ok (acc @ [ l ])
       | Some e ->
         let* () = disjoint ~path:local_path ~context:l.env_name e.layer l.layer in
         let* targets =
           fold_result
             (fun targets (key, lt) ->
                match List.assoc_opt key targets with
                | None -> Ok (targets @ [ key, lt ])
                | Some tt ->
                  let context = l.env_name ^ ".targets." ^ key in
                  let* () = disjoint ~path:local_path ~context tt lt in
                  Ok
                    (List.map
                       (fun (k, v) -> if k = key then k, merge tt lt else k, v)
                       targets))
             e.targets
             l.targets
         in
         let merged = { e with layer = merge e.layer l.layer; targets } in
         Ok (List.map (fun x -> if x.env_name = l.env_name then merged else x) acc))
    tracked
    local
;;

(* FEAT-100 is a clean break (pre-alpha, no compat shim): the old per-target
   layout is refused rather than silently ignored, naming where each file goes. *)
let refuse_per_target_files ~root =
  let sol_dir = Filename.concat root "sol" in
  let names select path =
    match select path with
    | Ok names -> names
    | Error _ -> []
  in
  let old =
    names Sol_cli_fs_walk.dirs sol_dir
    |> List.concat_map (fun env ->
      names Sol_cli_fs_walk.dirs (Filename.concat sol_dir env)
      |> List.concat_map (fun provider ->
        names
          Sol_cli_fs_walk.files
          (Filename.concat (Filename.concat sol_dir env) provider)
        |> List.filter_map (fun file ->
          if Filename.check_suffix file ".yml"
          then Some (env, provider, Filename.chop_suffix file ".yml")
          else None)))
  in
  match old with
  | [] -> Ok ()
  | (env, provider, region) :: _ ->
    Error
      { path = Printf.sprintf "sol/%s/%s/%s.yml" env provider region
      ; line = 0
      ; message =
          Printf.sprintf
            "per-target files are no longer read (FEAT-100): move this file into %s as \
             %s.targets.%s/%s, with its target: keys directly under it"
            environments_file
            env
            provider
            region
      }
;;

let load_environments ~root =
  let* () = refuse_per_target_files ~root in
  let local_path = Filename.concat root environments_local_file in
  let* tracked = load_environments_file (Filename.concat root environments_file) in
  let* local = load_environments_file local_path in
  union_environments ~local_path ~tracked ~local
;;

let active_resources cfg = List.filter (fun (r : resource) -> not r.omit) cfg.resources
let active_services cfg = List.filter (fun (s : service) -> not s.omit) cfg.services

let target_address (target : target) =
  Sol_cli_provider.to_string target.provider ^ "/" ^ target.region
;;

let find_target envs (target : target) =
  match List.find_opt (fun e -> e.env_name = target.env) envs with
  | None -> None, None
  | Some e -> Some e.layer, List.assoc_opt (target_address target) e.targets
;;

let target_declared (target : target) =
  match load_environments ~root:(workspace_root ()) with
  | Error _ -> false
  | Ok envs -> snd (find_target envs target) <> None
;;

let target_source (target : target) =
  Printf.sprintf
    "%s (%s.targets.%s)"
    (rooted environments_file)
    target.env
    (target_address target)
;;

let discover_targets envs =
  List.concat_map
    (fun e -> List.map (fun (key, _) -> e.env_name ^ "/" ^ key) e.targets)
    envs
  |> List.sort String.compare
;;

let discover_target_paths () =
  let* envs = load_environments ~root:(workspace_root ()) in
  Ok (discover_targets envs)
;;

(* Matches the only providers sol.yml's target-provider boxes recognize — no
   third value invented here that nothing else in the codebase
   (platform/cloud/) can actually provision against. *)
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

(* A profile is a claim one target makes about itself (DEC-026). sol.yml's
   target section is inherited by every target, so a profile there would opt
   every environment in without any target file saying so. *)
let reject_shared_profile ~path (base : layer) =
  match base.target with
  | Some { profile = Some _; _ } ->
    Error
      { path
      ; line = 0
      ; message =
          "profile must be selected in an environment or target (sol/environments.yml), \
           not in sol.yml, whose target section every target inherits"
      }
  | _ -> Ok ()
;;

(* sol.yml -> environment -> target, through [merge], which implements DEC-047's
   key table (lowest layer wins; scale and provider blocks deep-merge; lists
   replace; omit is sticky). An environment or target may only adjust services
   and resources sol.yml declares. *)
let resolve ~base ~envs (target : target) =
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
  let env_layer, target_layer = find_target envs target in
  let undeclared context (layer : layer) =
    let unknown_resource =
      List.find_opt
        (fun (r : resource) ->
           not (List.exists (fun (b : resource) -> b.name = r.name) base.resources))
        layer.resources
    in
    let unknown_service =
      List.find_opt
        (fun (sv : service) ->
           not (List.exists (fun (b : service) -> b.name = sv.name) base.services))
        layer.services
    in
    let fail kind name =
      Error
        { path = environments_file
        ; line = 0
        ; message =
            Printf.sprintf
              "%s: %s %S is not declared in sol.yml; an environment or target may only \
               adjust what sol.yml declares (DEC-047)"
              context
              kind
              name
        }
    in
    match unknown_resource, unknown_service with
    | Some r, _ -> fail "resource" r.name
    | None, Some sv -> fail "service" sv.name
    | None, None -> Ok ()
  in
  let apply context cfg = function
    | None -> Ok cfg
    | Some layer ->
      let* () = undeclared context layer in
      Ok (merge cfg layer)
  in
  let* cfg = apply target.env { base with target = Some base_target } env_layer in
  let* cfg = apply (target.env ^ ".targets." ^ target_address target) cfg target_layer in
  Ok cfg
;;

let resolved_target ~base ~envs target_path =
  let* target = target_of_path target_path in
  let* cfg = resolve ~base ~envs target in
  match cfg.target with
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
    Sol_cli_kube_destination.of_context
      ?kubeconfig:target.kubeconfig
      (Option.value target.kube_context ~default:"")
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

let validate_no_same_cluster ~base ~envs (selected : target) =
  let paths = discover_targets envs in
  let rec loop = function
    | [] -> Ok ()
    | path :: rest ->
      if path = selected.name
      then loop rest
      else (
        (* A target that cannot be read or resolved is an environment whose
           cluster we cannot check. Failing here is the point: an unverified
           environment must not pass as a verified one. *)
        match resolved_target ~base ~envs path with
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

(* REFAC-109: a resolved configuration always has its target -- [load_for_target]
   builds one from sol.yml, the environment and the target -- so its type says so,
   and callers read [cfg.target] instead of unwrapping an option that is never
   [None]. *)
type t =
  { project : string option
  ; target : target
  ; resources : resource list
  ; services : service list
  }

let load_for_target ~target =
  let* target = target_of_path target in
  (* DEC-024: the workspace is the nearest ancestor with a sol.yml, and sol.yml and
     the environments files resolve relative to that root -- not the invocation
     cwd. Absence fails closed and names the fix. *)
  let* root =
    match Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ()) with
    | Ok root -> Ok root
    | Error e ->
      Error
        { path = "sol.yml"
        ; line = 0
        ; message = Sol_cli_workspace.workspace_error_to_string e
        }
  in
  let sol_yml = Filename.concat root "sol.yml" in
  let* base = load sol_yml in
  let* () = reject_shared_profile ~path:sol_yml base in
  let* envs = load_environments ~root in
  let* cfg = resolve ~base ~envs target in
  let* cfg = validate_uses cfg in
  (* [resolve] starts from a Some target and [merge] keeps it, so the default is
     never taken; it keeps this total without an assertion. *)
  let target = Option.value cfg.target ~default:target in
  let* () = validate_no_same_cluster ~base ~envs target in
  Ok { project = cfg.project; target; resources = cfg.resources; services = cfg.services }
;;

let resources (cfg : t) = List.filter (fun (r : resource) -> not r.omit) cfg.resources
let services (cfg : t) = List.filter (fun (s : service) -> not s.omit) cfg.services

(* Reads the raw declarations, not [active_services]: the caller is asking about a
   unit it reached by another route, to decide whether this target omits it. *)
let is_omitted_service (cfg : t) ~name =
  List.exists (fun (s : service) -> s.omit && String.equal s.name name) cfg.services
;;

(* Every service in the workspace gets an ECR repository, regardless of
   which target is currently being planned/applied -- a service omitted
   from one target may still be deployed to another and needs its own
   repository either way.

   discover_services resolves the workspace boundary and exits the process
   when there is none -- appropriate for the top-level CLI commands it was
   written for, but terraform_vars must stay callable (e.g. from tests, or any
   future caller) without a workspace in cwd, so this uses the result-returning
   form and degrades to "no auto-detected repositories" instead of inheriting
   that exit. *)
let ecr_repositories_var () =
  (* INFRA-074: a discovery failure is an error, never "no repositories". The
     list drives [for_each] over repositories with [force_delete], so an empty
     list is an instruction to delete every image the target holds. *)
  match Sol_cli_manifest.discover_services_result () with
  (* The workspace resolved and has no [app/]: an infra-first workspace with no
     workloads yet, so no repositories. The plan guard in [cloud apply] still
     refuses a plan that would delete existing ones. *)
  | Error Sol_cli_manifest.Missing_app_dir -> Ok "[]"
  | Error e ->
    Error
      ("cannot determine the workspace's ECR repositories: "
       ^ Sol_cli_manifest.discover_error_to_string e)
  | Ok services ->
    Ok
      (services
       |> List.filter_map (fun (s : Sol_cli_manifest.service) ->
         match Sol_cli_kubernetes_name.k8s_name_of_source s.Sol_cli_manifest.name with
         | Ok name -> Some (Sol_cli_kubernetes_name.k8s_name_to_string name)
         | Error _ -> None)
       |> List.map (Printf.sprintf "%S")
       |> String.concat ","
       |> Printf.sprintf "[%s]")
;;

let vars_with_profile_precedence ~has_profile ~cli_vars ~config_vars =
  if has_profile then cli_vars @ config_vars else config_vars @ cli_vars
;;

(* REFAC-107: which local infrastructure `sol local infra up` starts, decided from
   what sol.yml declares rather than inferred from build files. Kafka and Postgres
   follow the declared resources; the observability stack is always on, because
   every platform install has it ("dev mirrors prod"). *)
let local_infra ~root =
  let* cfg = load (Filename.concat root "sol.yml") in
  let declares typ =
    List.exists (fun (r : resource) -> r.typ = Some typ) (active_resources cfg)
  in
  Ok
    { Sol_cli_workspace.kafka = declares "kafka"
    ; postgres = declares "postgres"
    ; loki = true
    ; prometheus = true
    ; tempo = true
    }
;;

(* REFAC-109: the bare target a <env>/<provider>/<region> address names, with no
   settings; for callers that build a resolved configuration directly. *)
let parse_target = target_of_path
