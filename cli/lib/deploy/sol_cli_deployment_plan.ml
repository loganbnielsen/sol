type deployment_mode =
  | Local
  | Customer_cloud
  | Sol_hosted

type env_config =
  { name : string
  ; mode : deployment_mode
  ; registry : string
  ; image_tag : string
  ; env : string option
  ; region : string option
  ; base_domain : string option
  ; cluster_issuer : string
  ; secret_backend : Sol_cli_manifest.secret_backend
  }

type primitive =
  | Svc
  | Worker
  | Fn

type effective_rollout_strategy =
  | Effective_canary
  | Effective_blue_green
  | Effective_recreate
  | Effective_rolling_update

type k8s_name = Sol_cli_kubernetes_name.k8s_name
type namespace = Sol_cli_kubernetes_name.namespace

type service_call =
  { env_var : string
  ; url : string
  ; target_domain : string
  ; target_name : k8s_name
  ; target_namespace : namespace
  }

type service_spec =
  { domain : string
  ; source_name : string
  ; k8s_name : k8s_name
  ; namespace : namespace
  ; primitive : primitive
  ; source_dir : string
  ; image : string
  ; config : (string * string) list
  ; secrets : (string * string) list
  ; volumes : Sol_cli_toml.volume list
  ; schedule : string option
  ; scheduled_concurrency : Sol_cli_toml.scheduled_concurrency
  ; backoff_limit : int
  ; replicas : int
  ; availability : Sol_cli_availability.t
  ; consumes_kafka : bool
  ; language : Sol_cli_compat.language option
  ; cpu : Sol_cli_toml.cpu_quantity
  ; memory : Sol_cli_toml.memory_quantity
  ; rollout_strategy : Sol_cli_toml.rollout_strategy option
  ; ingress_host : Sol_cli_toml.hostname option
  ; ingress_path : Sol_cli_toml.ingress_path option
  ; cluster_issuer : string
  ; calls : service_call list
  ; called_by : service_call list
  ; extra_labels : (string * string) list
  ; progressive_delivery : Sol_cli_toml.progressive_delivery option
  }

type profile_claim =
  { profile : Sol_cli_profile.t
  ; requirements : Sol_cli_profile.capability list
  ; application_findings : (Sol_cli_profile.capability * string) list
  }

type t =
  { workspace : string
  ; release_id : Sol_cli_release_id.t
  ; environment : env_config
  ; services : service_spec list
  ; topics : Sol_cli_plan_ids.Topic_name.t list
  ; migrations : Sol_cli_plan_ids.Migration_file.t list
  ; schema_subjects : Sol_cli_plan_ids.Schema_subject.t list
  ; consumer_groups : Sol_cli_plan_ids.Consumer_group.t list
  ; requested_scope : string
  ; profile : profile_claim option
  }

type plan_error =
  | Toml_error of Sol_cli_toml.parse_error
  | Invalid_persistence of
      { workload : string
      ; message : string
      }
  | Unsupported_availability of
      { workload : string
      ; message : string
      }
  | Invalid_service_call of
      { service : string
      ; ref : string
      ; message : string
      }
  | Invalid_kubernetes_name of
      { field : string
      ; value : string
      ; message : string
      }

open Result.Syntax

let mode_to_string = function
  | Local -> "local"
  | Customer_cloud -> "customer_cloud"
  | Sol_hosted -> "sol_hosted"
;;

let primitive_to_string = function
  | Svc -> "svc"
  | Worker -> "worker"
  | Fn -> "fn"
;;

let primitive_of_string = function
  | "svc" -> Ok Svc
  | "worker" -> Ok Worker
  | "fn" -> Ok Fn
  | s -> Error (Printf.sprintf "%S is not a primitive (expected svc, worker or fn)" s)
;;

let secret_backend_to_json backend =
  `String (Sol_cli_manifest.secret_backend_to_string backend)
;;

let default_cpu =
  match Sol_cli_toml.cpu_quantity_of_string "100m" with
  | Ok cpu -> cpu
  | Error message -> invalid_arg message
;;

let default_memory =
  match Sol_cli_toml.memory_quantity_of_string "128Mi" with
  | Ok memory -> memory
  | Error message -> invalid_arg message
;;

let default_scheduled_concurrency = Sol_cli_toml.Allow
let default_backoff_limit = 3

let effective_rollout_strategy s =
  match s.progressive_delivery with
  | Some (Sol_cli_toml.Canary _) -> Effective_canary
  | Some Sol_cli_toml.Blue_green -> Effective_blue_green
  | None ->
    (match s.rollout_strategy with
     | Some Sol_cli_toml.Recreate -> Effective_recreate
     | Some Sol_cli_toml.RollingUpdate | None -> Effective_rolling_update)
;;

let effective_rollout_strategy_to_string = function
  | Effective_canary -> "canary"
  | Effective_blue_green -> "blue_green"
  | Effective_recreate -> "recreate"
  | Effective_rolling_update -> "rolling_update"
;;

let k8s_name_to_string = Sol_cli_kubernetes_name.k8s_name_to_string
let namespace_to_string = Sol_cli_kubernetes_name.namespace_to_string

let progressive_steps_to_string steps =
  String.concat
    ","
    (List.map
       (function
         | Sol_cli_toml.Weight n -> Printf.sprintf "w%d" n
         | Sol_cli_toml.Pause None -> "p"
         | Sol_cli_toml.Pause (Some s) -> Printf.sprintf "p%d" s)
       steps)
;;

let release_rollout_to_string (spec : service_spec) =
  match spec.progressive_delivery with
  | Some (Sol_cli_toml.Canary { steps }) -> "canary:" ^ progressive_steps_to_string steps
  | Some Sol_cli_toml.Blue_green -> "blue_green"
  | None ->
    (match spec.rollout_strategy with
     | Some Sol_cli_toml.Recreate -> "recreate"
     | Some Sol_cli_toml.RollingUpdate | None -> "rolling_update")
;;

let release_workload_of_spec (spec : service_spec) : Sol_cli_release_id.workload =
  { Sol_cli_release_id.domain = spec.domain
  ; name = spec.source_name
  ; primitive =
      (match spec.primitive with
       | Svc -> "svc"
       | Worker -> "worker"
       | Fn -> "fn")
  ; image = spec.image
  ; config = spec.config
  ; secrets = spec.secrets
  ; schedule = spec.schedule
  ; scheduled_concurrency =
      Sol_cli_toml.scheduled_concurrency_to_string spec.scheduled_concurrency
  ; backoff_limit = spec.backoff_limit
  ; replicas = spec.replicas
  ; availability = Sol_cli_availability.to_string spec.availability
  ; consumes_kafka = spec.consumes_kafka
  ; cpu = Sol_cli_toml.cpu_quantity_to_string spec.cpu
  ; memory = Sol_cli_toml.memory_quantity_to_string spec.memory
  ; extra_labels = spec.extra_labels
  ; volumes =
      spec.volumes
      |> List.map (fun (v : Sol_cli_toml.volume) ->
        ( v.name
        , v.mount_path
        , v.size
        , Sol_cli_toml.volume_access_mode_to_string v.access_mode ))
  ; rollout = release_rollout_to_string spec
  ; ingress_host = Option.map Sol_cli_toml.hostname_to_string spec.ingress_host
  ; ingress_path = Option.map Sol_cli_toml.ingress_path_to_string spec.ingress_path
  ; cluster_issuer = spec.cluster_issuer
  ; calls =
      spec.calls
      |> List.map (fun (c : service_call) ->
        ( c.env_var
        , c.target_domain
        , k8s_name_to_string c.target_name
        , namespace_to_string c.target_namespace ))
  }
;;

let canary_step_to_json = function
  | Sol_cli_toml.Weight n -> `Assoc [ "setWeight", `Int n ]
  | Sol_cli_toml.Pause None -> `Assoc [ "pause", `Assoc [] ]
  | Sol_cli_toml.Pause (Some seconds) ->
    `Assoc [ "pause", `Assoc [ "durationSeconds", `Int seconds ] ]
;;

let progressive_delivery_to_json = function
  | None -> `Null
  | Some (Sol_cli_toml.Canary { steps }) ->
    `Assoc
      [ "strategy", `String "canary"
      ; "steps", `List (List.map canary_step_to_json steps)
      ]
  | Some Sol_cli_toml.Blue_green -> `Assoc [ "strategy", `String "blue_green" ]
;;

let to_json t =
  let opt_string = function
    | None -> `Null
    | Some s -> `String s
  in
  let ingress_json s =
    match s.ingress_host with
    | None -> `Null
    | Some host ->
      let host = Sol_cli_toml.hostname_to_string host in
      let path =
        match s.ingress_path with
        | Some path -> Sol_cli_toml.ingress_path_to_string path
        | None -> "/"
      in
      `Assoc
        [ "host", `String host
        ; "path", `String path
        ; ( "tls"
          , `Assoc
              [ "hosts", `List [ `String host ]
              ; ( "secretName"
                , `String (s.k8s_name |> k8s_name_to_string |> fun name -> name ^ "-tls")
                )
              ] )
        ; "cluster_issuer", `String s.cluster_issuer
        ; ( "annotations"
          , `Assoc
              [ "cert-manager.io/cluster-issuer", `String s.cluster_issuer
              ; "nginx.ingress.kubernetes.io/ssl-redirect", `String "true"
              ] )
        ]
  in
  let service_to_json (s : service_spec) =
    let rollout_strategy =
      s |> effective_rollout_strategy |> effective_rollout_strategy_to_string
    in
    `Assoc
      [ "k8s_name", `String (k8s_name_to_string s.k8s_name)
      ; "domain", `String s.domain
      ; "source_name", `String s.source_name
      ; "namespace", `String (namespace_to_string s.namespace)
      ; "primitive", `String (primitive_to_string s.primitive)
      ; "image", `String s.image
      ; "config", `Assoc (List.map (fun (k, v) -> k, `String v) s.config)
      ; "secret_keys", `List (List.map (fun (k, _) -> `String k) s.secrets)
      ; ( "volumes"
        , `List
            (s.volumes
             |> List.map (fun (v : Sol_cli_toml.volume) ->
               `Assoc
                 [ "name", `String v.Sol_cli_toml.name
                 ; "mount_path", `String v.Sol_cli_toml.mount_path
                 ; "size", `String v.Sol_cli_toml.size
                 ; ( "access_mode"
                   , `String
                       (Sol_cli_toml.volume_access_mode_to_string
                          v.Sol_cli_toml.access_mode) )
                 ])) )
      ; "schedule", opt_string s.schedule
      ; "replicas", `Int s.replicas
      ; "cpu", `String (Sol_cli_toml.cpu_quantity_to_string s.cpu)
      ; "memory", `String (Sol_cli_toml.memory_quantity_to_string s.memory)
      ; "rollout_strategy", `String rollout_strategy
      ; "ingress", ingress_json s
      ; ( "calls"
        , `List
            (s.calls
             |> List.map (fun c ->
               `Assoc
                 [ "env", `String c.env_var
                 ; "url", `String c.url
                 ; "target_domain", `String c.target_domain
                 ; "target_name", `String (k8s_name_to_string c.target_name)
                 ; "target_namespace", `String (namespace_to_string c.target_namespace)
                 ])) )
      ; "progressive_delivery", progressive_delivery_to_json s.progressive_delivery
      ]
  in
  let env = t.environment in
  `Assoc
    [ "_note", `String "experimental — schema not frozen"
    ; "workspace", `String t.workspace
    ; ( "environment"
      , `Assoc
          [ "name", `String env.name
          ; "mode", `String (mode_to_string env.mode)
          ; "registry", `String env.registry
          ; "image_tag", `String env.image_tag
          ; "env", opt_string env.env
          ; "region", opt_string env.region
          ; "base_domain", opt_string env.base_domain
          ; "cluster_issuer", `String env.cluster_issuer
          ; "secret_backend", secret_backend_to_json env.secret_backend
          ] )
    ; "release_id", `String (Sol_cli_release_id.to_string t.release_id)
    ; "requested_scope", `String t.requested_scope
    ; ( "resolved_workloads"
      , `List
          (t.services
           |> List.map (fun (s : service_spec) ->
             `Assoc [ "domain", `String s.domain; "name", `String s.source_name ])) )
    ; "services", `List (List.map service_to_json t.services)
    ; ( "topics"
      , `List
          (List.map (fun s -> `String (Sol_cli_plan_ids.Topic_name.to_string s)) t.topics)
      )
    ; ( "migrations"
      , `List
          (t.migrations
           |> List.map (fun s -> `String (Sol_cli_plan_ids.Migration_file.to_string s))) )
    ; ( "schema_subjects"
      , `List
          (t.schema_subjects
           |> List.map (fun s -> `String (Sol_cli_plan_ids.Schema_subject.to_string s))) )
    ; ( "consumer_groups"
      , `List
          (t.consumer_groups
           |> List.map (fun s -> `String (Sol_cli_plan_ids.Consumer_group.to_string s))) )
    ; ( "profile"
      , match t.profile with
        | None -> `Null
        | Some (claim : profile_claim) ->
          `Assoc
            [ "id", `String (Sol_cli_profile.to_string claim.profile)
            ; ( "evidence_requirements"
              , `List
                  (claim.requirements
                   |> List.map (fun c -> `String (Sol_cli_profile.capability_to_string c))
                  ) )
            ] )
    ]
;;

let pp_summary fmt t =
  let env = t.environment in
  Format.fprintf fmt "Deployment Plan (experimental)@\n";
  Format.fprintf fmt "workspace:   %s@\n" t.workspace;
  Format.fprintf fmt "environment: %s (%s)@\n" env.name (mode_to_string env.mode);
  Format.fprintf fmt "registry:    %s@\n" env.registry;
  Format.fprintf fmt "tag:         %s@\n" env.image_tag;
  t.profile
  |> Option.iter (fun (claim : profile_claim) ->
    Format.fprintf fmt "profile:     %s@\n" (Sol_cli_profile.to_string claim.profile));
  Format.fprintf fmt "@\n";
  Format.fprintf fmt "services:@\n";
  t.services
  |> List.iter (fun (s : service_spec) ->
    let rollout_strategy =
      s |> effective_rollout_strategy |> effective_rollout_strategy_to_string
    in
    Format.fprintf
      fmt
      "  [%s] %s/%s    rollout=%s -> %s@\n"
      (primitive_to_string s.primitive)
      s.domain
      s.source_name
      rollout_strategy
      s.image);
  (match t.topics with
   | [] -> ()
   | topics ->
     Format.fprintf fmt "@\n";
     Format.fprintf
       fmt
       "topics:   %s@\n"
       (String.concat ", " (List.map Sol_cli_plan_ids.Topic_name.to_string topics)));
  (match t.migrations with
   | [] -> ()
   | ms ->
     Format.fprintf fmt "@\n";
     Format.fprintf
       fmt
       "migrations:   %s@\n"
       (String.concat ", " (List.map Sol_cli_plan_ids.Migration_file.to_string ms)));
  (match t.schema_subjects with
   | [] -> ()
   | ss ->
     Format.fprintf fmt "@\n";
     Format.fprintf
       fmt
       "schema subjects:  %s@\n"
       (String.concat ", " (List.map Sol_cli_plan_ids.Schema_subject.to_string ss)));
  match t.consumer_groups with
  | [] -> ()
  | cgs ->
    Format.fprintf fmt "@\n";
    Format.fprintf
      fmt
      "consumer groups:  %s@\n"
      (String.concat ", " (List.map Sol_cli_plan_ids.Consumer_group.to_string cgs))
;;

let resource_name_of_ref ref =
  match String.split_on_char '/' ref |> List.filter (( <> ) "") |> List.rev with
  | name :: _ -> Some name
  | [] -> None
;;

let service_uses_resource_type declared service_name typ =
  match declared with
  | None -> false
  | Some cfg ->
    let resources = cfg.Sol_cli_config.resources in
    (match
       cfg.Sol_cli_config.services
       |> List.find_opt (fun (service : Sol_cli_config.service) ->
         service.name = service_name)
     with
     | None -> false
     | Some service ->
       service.uses
       |> List.exists (fun ref ->
         match resource_name_of_ref ref with
         | None -> false
         | Some name ->
           resources
           |> List.exists (fun (resource : Sol_cli_config.resource) ->
             resource.name = name && resource.typ = Some typ)))
;;

let derive_consumer_groups ?declared workspace services =
  List.filter_map
    (fun s ->
       match s.primitive, service_uses_resource_type declared s.source_name "kafka" with
       | Worker, true -> Some (s.domain, s.source_name)
       | _ -> None)
    services
  |> Sol_cli_workspace_scan.derive_consumer_groups workspace
;;

let invalid_kubernetes_name ~field ~value message =
  Invalid_kubernetes_name { field; value; message }
;;

let k8s_name_result name =
  Sol_cli_kubernetes_name.k8s_name_of_source name
  |> Result.map_error (invalid_kubernetes_name ~field:"k8s_name" ~value:name)
;;

let namespace_result ~workspace ~domain =
  let value =
    Printf.sprintf
      "%s-%s"
      (Sol_cli_kubernetes_name.normalize workspace)
      (Sol_cli_kubernetes_name.normalize domain)
  in
  Sol_cli_kubernetes_name.make_namespace value
  |> Result.map_error (invalid_kubernetes_name ~field:"namespace" ~value)
;;

let image_ref ~registry ~workspace ~k8s_name ~tag =
  Printf.sprintf "%s/%s/%s:%s" registry workspace (k8s_name_to_string k8s_name) tag
;;

let plan_error_to_string = function
  | Toml_error err -> Sol_cli_toml.parse_error_to_string err
  | Invalid_persistence { workload; message } ->
    Printf.sprintf "workload %S has invalid persistence: %s" workload message
  | Unsupported_availability { workload; message } ->
    Printf.sprintf "workload %S has unsupported availability: %s" workload message
  | Invalid_service_call { service; ref; message } ->
    Printf.sprintf "service %S calls %S: %s" service ref message
  | Invalid_kubernetes_name { field; value; message } ->
    Printf.sprintf "invalid Kubernetes %s %S: %s" field value message
;;

let namespace_name ~workspace ~domain =
  namespace_result ~workspace ~domain
  |> Result.map namespace_to_string
  |> Result.map_error plan_error_to_string
;;

let k8s_name name =
  k8s_name_result name
  |> Result.map k8s_name_to_string
  |> Result.map_error plan_error_to_string
;;

let validate_persistence (spec : service_spec) =
  match spec.primitive, spec.volumes with
  | _, [] -> Ok ()
  | Fn, _ ->
    Error
      (Invalid_persistence
         { workload = spec.source_name
         ; message = "function volumes are unsupported; use managed storage"
         })
  | (Svc | Worker), _ when spec.replicas <> 1 ->
    Error
      (Invalid_persistence
         { workload = spec.source_name
         ; message =
             "volumes belong to one interchangeable workload instance; set replicas = 1, \
              or use managed storage shared outside the workload"
         })
  | (Svc | Worker), _ -> Ok ()
;;

let validate_availability (spec : service_spec) =
  if not (Sol_cli_availability.is_node_failure_tolerant spec.availability)
  then Ok ()
  else (
    match spec.primitive, spec.volumes, spec.replicas with
    | Fn, _, _ ->
      Error
        (Unsupported_availability
           { workload = spec.source_name
           ; message =
               "functions are scheduled jobs; availability is not applicable — remove \
                `availability` or declare `availability = \"single\"`"
           })
    | (Svc | Worker), _ :: _, _ ->
      Error
        (Unsupported_availability
           { workload = spec.source_name
           ; message =
               "a persistent volume pins one writable attachment, so a volume-backed \
                workload cannot be node-failure-tolerant; declare `availability = \
                \"single\"` or use managed storage"
           })
    | (Svc | Worker), [], replicas when replicas < 2 ->
      Error
        (Unsupported_availability
           { workload = spec.source_name
           ; message =
               "node-failure-tolerant requires at least two replicas on distinct nodes; \
                set `[infra.scale] replicas = 2` (or more) or declare `availability = \
                \"single\"`"
           })
    | (Svc | Worker), [], _ -> Ok ())
;;

let primitive_of_manifest = function
  | Sol_cli_manifest.Svc -> Svc
  | Sol_cli_manifest.Worker -> Worker
  | Sol_cli_manifest.Fn -> Fn
;;

let call_env_var = Sol_cli_kubernetes_name.call_env_var

let sol_yml_replicas_override ~declared ~service_name =
  match declared with
  | None -> None
  | Some cfg ->
    (match
       cfg.Sol_cli_config.services
       |> List.find_opt (fun s -> s.Sol_cli_config.name = service_name)
     with
     | None -> None
     | Some { Sol_cli_config.scale_max = Some _ as scale_max; _ } -> scale_max
     | Some { Sol_cli_config.scale_min; _ } -> scale_min)
;;

let sol_yml_language ~declared ~service_name =
  match declared with
  | None -> None
  | Some cfg ->
    (match
       cfg.Sol_cli_config.services
       |> List.find_opt (fun s -> s.Sol_cli_config.name = service_name)
     with
     | None -> None
     | Some s -> s.language)
;;

let workload_capabilities ~declared ~services ~topics ~migrations =
  let declares typ =
    match declared with
    | None -> false
    | Some cfg ->
      cfg.Sol_cli_config.resources
      |> List.exists (fun (r : Sol_cli_config.resource) -> r.typ = Some typ)
  in
  let long_running =
    services
    |> List.exists (fun s ->
      match s.primitive with
      | Svc | Worker -> true
      | Fn -> false)
  in
  List.filter_map
    (fun (used, capability) -> if used then Some capability else None)
    [ long_running, Sol_cli_profile.Long_running
    ; migrations <> [] || declares "postgres", Sol_cli_profile.Postgres
    ; topics <> [] || declares "kafka", Sol_cli_profile.Kafka
    ]
;;

let is_whole_workspace (t : t) = String.equal t.requested_scope "workspace"

let profile_claim ~declared ~services ~topics ~migrations ~whole_workspace =
  match declared with
  | None -> None
  | Some cfg ->
    cfg.Sol_cli_config.profile
    |> Option.map (fun profile ->
      let requirements =
        Sol_cli_profile.requirements
          profile
          (workload_capabilities ~declared ~services ~topics ~migrations)
      in
      let declares typ =
        match declared with
        | None -> false
        | Some cfg ->
          cfg.Sol_cli_config.resources
          |> List.exists (fun (resource : Sol_cli_config.resource) ->
            resource.typ = Some typ)
      in
      let service_uses typ =
        services
        |> List.exists (fun service ->
          service_uses_resource_type declared service.source_name typ)
      in
      { profile
      ; requirements
      ; application_findings =
          List.filter_map
            (fun (missing, capability, reason) ->
               if missing && List.mem capability requirements
               then Some (capability, reason)
               else None)
            [ ( not (declares "postgres")
              , Sol_cli_profile.Postgres_durability
              , "declare a postgres resource for database migrations" )
            ; ( whole_workspace && topics <> [] && not (service_uses "kafka")
              , Sol_cli_profile.Kafka_durability
              , "this workspace declares Kafka topics, so the Service that handles them \
                 must declare uses: [<kafka resource>]" )
            ]
      })
;;

let of_services_result
      ~workspace
      ~env
      ~facts
      ?(requested_scope = "workspace")
      ?declared
      ?(image_refs = [])
      ?inventory
      services
  =
  let resolution_units =
    match inventory with
    | None -> services
    | Some units ->
      let seen = Hashtbl.create 16 in
      List.filter
        (fun svc ->
           let key = svc.Sol_cli_manifest.domain ^ "/" ^ svc.Sol_cli_manifest.name in
           if Hashtbl.mem seen key
           then false
           else (
             Hashtbl.add seen key ();
             true))
        (services @ units)
  in
  let loaded =
    resolution_units
    |> List.map (fun svc ->
      let config =
        match
          List.find_opt
            (fun (w : Sol_cli_workspace_model.workload) ->
               String.equal w.service.Sol_cli_manifest.domain svc.Sol_cli_manifest.domain
               && String.equal w.service.Sol_cli_manifest.name svc.Sol_cli_manifest.name)
            facts.Sol_cli_workspace_model.workloads
        with
        | Some w -> w.config
        | None ->
          Sol_cli_toml.load_result
            (Sol_cli_workspace.at_root
               (Filename.concat svc.Sol_cli_manifest.dir "sol.toml"))
      in
      config
      |> Result.map_error (fun err -> Toml_error err)
      |> Result.map (fun toml -> svc, toml))
  in
  let rec collect_loaded acc = function
    | [] -> Ok (List.rev acc)
    | result :: rest ->
      let* item = result in
      collect_loaded (item :: acc) rest
  in
  let* loaded = collect_loaded [] loaded in
  let known_units () =
    loaded
    |> List.map (fun (svc, _) ->
      Printf.sprintf "%s/%s" svc.Sol_cli_manifest.domain svc.Sol_cli_manifest.name)
    |> List.sort_uniq String.compare
  in
  let lookup_call caller ref =
    match String.split_on_char '/' ref with
    | [ domain; source_name ] when domain <> "" && source_name <> "" ->
      (match
         loaded
         |> List.find_opt (fun (svc, _) ->
           svc.Sol_cli_manifest.domain = domain
           && svc.Sol_cli_manifest.name = source_name
           && svc.primitive = Sol_cli_manifest.Svc)
       with
       | None ->
         Error
           (Invalid_service_call
              { service = caller
              ; ref
              ; message =
                  Printf.sprintf
                    "target service not found: this workspace has no service %S in \
                     domain %S; workspace units: %s"
                    source_name
                    domain
                    (match known_units () with
                     | [] -> "(none)"
                     | units -> String.concat ", " units)
              })
       | Some (target, _) ->
         let* target_name = k8s_name_result target.name in
         let* target_namespace = namespace_result ~workspace ~domain:target.domain in
         Ok
           { env_var = call_env_var target.name
           ; url =
               Sol_cli_kubernetes_name.service_url
                 ~namespace:target_namespace
                 ~k8s_name:target_name
           ; target_domain = target.domain
           ; target_name
           ; target_namespace
           })
    | _ ->
      Error
        (Invalid_service_call
           { service = caller; ref; message = "expected domain/service_name" })
  in
  let to_spec (svc, toml) =
    let* k8s_name = k8s_name_result svc.Sol_cli_manifest.name in
    let* namespace = namespace_result ~workspace ~domain:svc.Sol_cli_manifest.domain in
    let image =
      match List.assoc_opt svc.name image_refs with
      | Some ref -> ref
      | None -> image_ref ~registry:env.registry ~workspace ~k8s_name ~tag:env.image_tag
    in
    let primitive = primitive_of_manifest svc.primitive in
    let* calls =
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | ref :: rest ->
          let* call = lookup_call svc.name ref in
          collect (call :: acc) rest
      in
      collect [] toml.Sol_cli_toml.calls
    in
    let* () =
      match
        toml.env_config
        |> List.find_opt (fun (key, _) -> List.exists (fun c -> c.env_var = key) calls)
      with
      | None -> Ok ()
      | Some (key, _) ->
        Error
          (Invalid_service_call
             { service = svc.name
             ; ref = key
             ; message = "call URL env var conflicts with [infra.env] config"
             })
    in
    let* schedule =
      match primitive with
      | Fn ->
        (match toml.schedule with
         | Some schedule -> Ok (Some schedule)
         | None ->
           Error
             (Toml_error
                (Sol_cli_toml.Validation
                   { path = Sol_cli_workspace.at_root (Filename.concat svc.dir "sol.toml")
                   ; message =
                       Printf.sprintf
                         "sol.toml: [service] schedule is required for the -fn %S (e.g. \
                          schedule = \"0 3 * * *\")"
                         svc.name
                   })))
      | _ -> Ok None
    in
    let replicas =
      match sol_yml_replicas_override ~declared ~service_name:svc.name with
      | Some replicas -> replicas
      | None -> Option.value toml.replicas ~default:1
    in
    let kafka_durability_config =
      match declared with
      | Some cfg
        when cfg.Sol_cli_config.profile = Some Sol_cli_profile.Production_single_region
             && service_uses_resource_type declared svc.name "kafka" ->
        [ "SOL_KAFKA_DURABILITY", "single-broker-loss" ]
      | _ -> []
    in
    let service_config = List.remove_assoc "SOL_KAFKA_DURABILITY" toml.env_config in
    let language = sol_yml_language ~declared ~service_name:svc.name in
    let consumes_kafka =
      toml.topics <> [] || service_uses_resource_type declared svc.name "kafka"
    in
    let spec =
      { domain = svc.domain
      ; source_name = svc.name
      ; k8s_name
      ; namespace
      ; primitive
      ; source_dir = svc.dir
      ; image
      ; config =
          kafka_durability_config
          @ service_config
          @ List.map (fun c -> c.env_var, c.url) calls
      ; secrets = List.map (fun key -> key, "") toml.secret_keys
      ; volumes = toml.volumes
      ; schedule
      ; scheduled_concurrency =
          Option.value toml.scheduled_concurrency ~default:default_scheduled_concurrency
      ; backoff_limit = Option.value toml.backoff_limit ~default:default_backoff_limit
      ; replicas
      ; availability = Option.value toml.availability ~default:Sol_cli_availability.Single
      ; consumes_kafka
      ; language
      ; cpu = Option.value toml.cpu ~default:default_cpu
      ; memory = Option.value toml.memory ~default:default_memory
      ; rollout_strategy = toml.rollout_strategy
      ; ingress_host = toml.ingress_host
      ; ingress_path = toml.ingress_path
      ; cluster_issuer = env.cluster_issuer
      ; calls
      ; called_by = []
      ; extra_labels = toml.extra_labels
      ; progressive_delivery = toml.progressive_delivery
      }
    in
    let* () = validate_persistence spec in
    let* () = validate_availability spec in
    Ok spec
  in
  let rec collect acc = function
    | [] -> Ok (List.rev acc)
    | svc :: rest ->
      let* spec = to_spec svc in
      collect (spec :: acc) rest
  in
  let selection_key (svc : Sol_cli_manifest.service) = svc.domain ^ "/" ^ svc.name in
  let selection_keys = List.map selection_key services in
  let deployable =
    List.filter (fun (svc, _) -> List.mem (selection_key svc) selection_keys) loaded
  in
  let* resolved_services = collect [] deployable in
  let* workspace_services = collect [] loaded in
  let resolved_services =
    resolved_services
    |> List.map (fun svc ->
      let called_by =
        resolved_services
        |> List.filter_map (fun caller ->
          if
            List.exists
              (fun c ->
                 namespace_to_string c.target_namespace
                 = namespace_to_string svc.namespace
                 && k8s_name_to_string c.target_name = k8s_name_to_string svc.k8s_name)
              caller.calls
          then
            Some
              { env_var = call_env_var caller.source_name
              ; url =
                  Sol_cli_kubernetes_name.service_url
                    ~namespace:caller.namespace
                    ~k8s_name:caller.k8s_name
              ; target_domain = caller.domain
              ; target_name = caller.k8s_name
              ; target_namespace = caller.namespace
              }
          else None)
      in
      { svc with called_by })
  in
  let release_id =
    Sol_cli_release_id.of_content
      { workspace
      ; environment = env.env
      ; workloads = List.map release_workload_of_spec resolved_services
      }
  in
  let topics = facts.Sol_cli_workspace_model.topics in
  let migrations = Sol_cli_workspace_model.migration_files facts in
  let schema_subjects = facts.schema_subjects in
  Ok
    { workspace
    ; release_id
    ; environment = env
    ; services = resolved_services
    ; topics
    ; migrations
    ; schema_subjects
    ; consumer_groups = derive_consumer_groups ?declared workspace workspace_services
    ; requested_scope
    ; profile =
        profile_claim
          ~declared
          ~services:resolved_services
          ~topics
          ~migrations
          ~whole_workspace:(String.equal requested_scope "workspace")
    }
;;
