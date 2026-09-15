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

type t =
  { workspace : string
  ; release_id : Sol_cli_release_id.t
    (** FEAT-069: the content-addressed identity of the desired released state.
        Computed once in {!of_services_result} -- the first point at which every
        release-defining service input is resolved -- and never recomputed.
        Downstream rendering and recording consume this value. *)
  ; environment : env_config
  ; services : service_spec list
  ; topics : Sol_cli_plan_ids.Topic_name.t list
  ; migrations : Sol_cli_plan_ids.Migration_file.t list
  ; schema_subjects : Sol_cli_plan_ids.Schema_subject.t list
  ; consumer_groups : Sol_cli_plan_ids.Consumer_group.t list
  ; requested_scope : string
    (** What the user asked for, before discovery narrowed it (FEAT-065):
          ["workspace"], a domain, or ["domain/unit"]. The concrete resolved
          set is [services]; the pair is intent plus reproducibility, and
          DEC-018's release record needs both. *)
  }

type plan_error =
  | Toml_error of Sol_cli_toml.parse_error
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

let ( let* ) = Result.bind

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

(* Canonical inverse of [primitive_to_string] (FEAT-066): rollback reconstructs
   a recorded release's specs from the release record, which stores this value
   in its canonical string form. *)
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

(* FEAT-079: -fn's pre-FEAT-079 hardcoded behavior, now the explicit default
   when scheduled_concurrency/backoff_limit are unset in sol.toml. *)
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

(* BUG-026: the single projection from a resolved workload to its contribution
   to the release identity. It is exported so [Sol_cli_release]'s record builder
   calls it rather than hand-mirroring it — two mirrored projections drift, and
   the drift is exactly how a manifest-affecting field stops moving the id.
   Every input the renderer turns into manifest content must appear here. *)
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

(* The effective strategy, so [None] and [Some RollingUpdate] are one release.
   Canary steps are part of the identity: changing them changes the Rollout. *)
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
  ; replicas = spec.replicas
  ; cpu = Sol_cli_toml.cpu_quantity_to_string spec.cpu
  ; memory = Sol_cli_toml.memory_quantity_to_string spec.memory
  ; extra_labels = spec.extra_labels
  ; volumes =
      List.map
        (fun (v : Sol_cli_toml.volume) ->
           ( v.name
           , v.mount_path
           , v.size
           , Sol_cli_toml.volume_access_mode_to_string v.access_mode ))
        spec.volumes
  ; rollout = release_rollout_to_string spec
  ; ingress_host = Option.map Sol_cli_toml.hostname_to_string spec.ingress_host
  ; ingress_path = Option.map Sol_cli_toml.ingress_path_to_string spec.ingress_path
  ; cluster_issuer = spec.cluster_issuer
  ; calls =
      List.map
        (fun (c : service_call) ->
           ( c.env_var
           , c.target_domain
           , k8s_name_to_string c.target_name
           , namespace_to_string c.target_namespace ))
        spec.calls
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
            (List.map
               (fun (v : Sol_cli_toml.volume) ->
                  `Assoc
                    [ "name", `String v.Sol_cli_toml.name
                    ; "mount_path", `String v.Sol_cli_toml.mount_path
                    ; "size", `String v.Sol_cli_toml.size
                    ; ( "access_mode"
                      , `String
                          (Sol_cli_toml.volume_access_mode_to_string
                             v.Sol_cli_toml.access_mode) )
                    ])
               s.volumes) )
      ; "schedule", opt_string s.schedule
      ; "replicas", `Int s.replicas
      ; "cpu", `String (Sol_cli_toml.cpu_quantity_to_string s.cpu)
      ; "memory", `String (Sol_cli_toml.memory_quantity_to_string s.memory)
      ; "rollout_strategy", `String rollout_strategy
      ; "ingress", ingress_json s
      ; ( "calls"
        , `List
            (List.map
               (fun c ->
                  `Assoc
                    [ "env", `String c.env_var
                    ; "url", `String c.url
                    ; "target_domain", `String c.target_domain
                    ; "target_name", `String (k8s_name_to_string c.target_name)
                    ; "target_namespace", `String (namespace_to_string c.target_namespace)
                    ])
               s.calls) )
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
          (List.map
             (fun (s : service_spec) ->
                `Assoc [ "domain", `String s.domain; "name", `String s.source_name ])
             t.services) )
    ; "services", `List (List.map service_to_json t.services)
    ; ( "topics"
      , `List
          (List.map (fun s -> `String (Sol_cli_plan_ids.Topic_name.to_string s)) t.topics)
      )
    ; ( "migrations"
      , `List
          (List.map
             (fun s -> `String (Sol_cli_plan_ids.Migration_file.to_string s))
             t.migrations) )
    ; ( "schema_subjects"
      , `List
          (List.map
             (fun s -> `String (Sol_cli_plan_ids.Schema_subject.to_string s))
             t.schema_subjects) )
    ; ( "consumer_groups"
      , `List
          (List.map
             (fun s -> `String (Sol_cli_plan_ids.Consumer_group.to_string s))
             t.consumer_groups) )
    ]
;;

let pp_summary fmt t =
  let env = t.environment in
  Format.fprintf fmt "Deployment Plan (experimental)@\n";
  Format.fprintf fmt "workspace:   %s@\n" t.workspace;
  Format.fprintf fmt "environment: %s (%s)@\n" env.name (mode_to_string env.mode);
  Format.fprintf fmt "registry:    %s@\n" env.registry;
  Format.fprintf fmt "tag:         %s@\n" env.image_tag;
  Format.fprintf fmt "@\n";
  Format.fprintf fmt "services:@\n";
  List.iter
    (fun (s : service_spec) ->
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
         s.image)
    t.services;
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

let discover_schema_subjects = Sol_cli_workspace_scan.discover_schema_subjects
let discover_topics = Sol_cli_workspace_scan.discover_topics
let discover_migrations = Sol_cli_workspace_scan.discover_migrations

let derive_consumer_groups workspace services =
  List.filter_map
    (fun (s : service_spec) ->
       match s.primitive with
       | Worker -> Some (s.domain, s.source_name)
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

let namespace_of_exn ~workspace ~domain =
  match namespace_result ~workspace ~domain with
  | Ok namespace -> namespace
  | Error err ->
    failwith
      (match err with
       | Invalid_kubernetes_name { field; value; message } ->
         Printf.sprintf "invalid Kubernetes %s %S: %s" field value message
       | Invalid_service_call { service; ref; message } ->
         Printf.sprintf "service %S calls %S: %s" service ref message
       | Toml_error toml -> Sol_cli_toml.parse_error_to_string toml)
;;

let image_ref ~registry ~workspace ~k8s_name ~tag =
  Printf.sprintf "%s/%s/%s:%s" registry workspace (k8s_name_to_string k8s_name) tag
;;

let plan_error_to_string = function
  | Toml_error err -> Sol_cli_toml.parse_error_to_string err
  | Invalid_service_call { service; ref; message } ->
    Printf.sprintf "service %S calls %S: %s" service ref message
  | Invalid_kubernetes_name { field; value; message } ->
    Printf.sprintf "invalid Kubernetes %s %S: %s" field value message
;;

let primitive_of_manifest = function
  | Sol_cli_manifest.Svc -> Svc
  | Sol_cli_manifest.Worker -> Worker
  | Sol_cli_manifest.Fn -> Fn
;;

(* Delegates to the shared helper (FEAT-066): the naming rule has one
   definition, so the planner and rollback's decode of a recorded release
   cannot diverge. *)
let call_env_var = Sol_cli_kubernetes_name.call_env_var

(* Delegates to the shared helper (FEAT-066): the URL format has one definition,
   so the planner and rollback's decode of a recorded release cannot diverge. *)
let service_url ~workspace ~domain ~k8s_name =
  Sol_cli_kubernetes_name.service_url
    ~namespace:(namespace_of_exn ~workspace ~domain)
    ~k8s_name
;;

(* sol.yml scale (a min/max range) and sol.toml's replicas (a fixed count)
   aren't the same shape -- no HorizontalPodAutoscaler is emitted anywhere
   today, so scale_max (falling back to scale_min) stands in as the interim
   fixed count. See BUG-004. *)
let sol_yml_replicas_override ~resolved_config ~service_name =
  match resolved_config with
  | None -> None
  | Some cfg ->
    (match
       List.find_opt
         (fun (s : Sol_cli_config.service) -> s.Sol_cli_config.name = service_name)
         cfg.Sol_cli_config.services
     with
     | None -> None
     | Some { Sol_cli_config.scale_max = Some _ as scale_max; _ } -> scale_max
     | Some { Sol_cli_config.scale_min; _ } -> scale_min)
;;

let of_services_result
      ~workspace
      ~env
      ?(requested_scope = "workspace")
      ?resolved_config
      services
  =
  let loaded =
    List.map
      (fun svc ->
         (* DEC-024: [svc.dir] is workspace-root relative; join it to the
            resolved root so this read is correct even when the command was
            invoked from a descendant directory (and `sol deploy` keeps the
            invocation cwd for relative --emit-to paths). *)
         Sol_cli_toml.load_result
           (Sol_cli_workspace.at_root
              (Filename.concat svc.Sol_cli_manifest.dir "sol.toml"))
         |> Result.map_error (fun err -> Toml_error err)
         |> Result.map (fun toml -> svc, toml))
      services
  in
  let rec collect_loaded acc = function
    | [] -> Ok (List.rev acc)
    | result :: rest ->
      let* item = result in
      collect_loaded (item :: acc) rest
  in
  let* loaded = collect_loaded [] loaded in
  let lookup_call caller ref =
    match String.split_on_char '/' ref with
    | [ domain; source_name ] when domain <> "" && source_name <> "" ->
      (match
         List.find_opt
           (fun (svc, _) ->
              svc.Sol_cli_manifest.domain = domain
              && svc.Sol_cli_manifest.name = source_name
              && svc.Sol_cli_manifest.primitive = Sol_cli_manifest.Svc)
           loaded
       with
       | None ->
         Error
           (Invalid_service_call
              { service = caller; ref; message = "target service not found" })
       | Some (target, _) ->
         let* target_name = k8s_name_result target.Sol_cli_manifest.name in
         let* target_namespace =
           namespace_result ~workspace ~domain:target.Sol_cli_manifest.domain
         in
         Ok
           { env_var = call_env_var target.Sol_cli_manifest.name
           ; url =
               service_url
                 ~workspace
                 ~domain:target.Sol_cli_manifest.domain
                 ~k8s_name:target_name
           ; target_domain = target.Sol_cli_manifest.domain
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
      image_ref ~registry:env.registry ~workspace ~k8s_name ~tag:env.image_tag
    in
    let primitive = primitive_of_manifest svc.Sol_cli_manifest.primitive in
    let* calls =
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | ref :: rest ->
          let* call = lookup_call svc.Sol_cli_manifest.name ref in
          collect (call :: acc) rest
      in
      collect [] toml.Sol_cli_toml.calls
    in
    let* () =
      match
        List.find_opt
          (fun (key, _) -> List.exists (fun c -> c.env_var = key) calls)
          toml.Sol_cli_toml.env_config
      with
      | None -> Ok ()
      | Some (key, _) ->
        Error
          (Invalid_service_call
             { service = svc.Sol_cli_manifest.name
             ; ref = key
             ; message = "call URL env var conflicts with [infra.env] config"
             })
    in
    let schedule =
      match primitive with
      | Fn ->
        Some
          (Sol_cli_manifest.extract_schedule
             ~dir:(Sol_cli_workspace.at_root svc.Sol_cli_manifest.dir)
             ~name:svc.Sol_cli_manifest.name)
      | _ -> None
    in
    { domain = svc.Sol_cli_manifest.domain
    ; source_name = svc.Sol_cli_manifest.name
    ; k8s_name
    ; namespace
    ; primitive
    ; source_dir = svc.Sol_cli_manifest.dir
    ; image
    ; config = toml.Sol_cli_toml.env_config @ List.map (fun c -> c.env_var, c.url) calls
    ; secrets = List.map (fun key -> key, "") toml.Sol_cli_toml.secret_keys
    ; volumes = toml.Sol_cli_toml.volumes
    ; schedule
    ; scheduled_concurrency =
        Option.value
          toml.Sol_cli_toml.scheduled_concurrency
          ~default:default_scheduled_concurrency
    ; backoff_limit =
        Option.value toml.Sol_cli_toml.backoff_limit ~default:default_backoff_limit
    ; replicas =
        (match
           sol_yml_replicas_override
             ~resolved_config
             ~service_name:svc.Sol_cli_manifest.name
         with
         | Some replicas -> replicas
         | None -> Option.value toml.Sol_cli_toml.replicas ~default:1)
    ; cpu = Option.value toml.Sol_cli_toml.cpu ~default:default_cpu
    ; memory = Option.value toml.Sol_cli_toml.memory ~default:default_memory
    ; rollout_strategy = toml.Sol_cli_toml.rollout_strategy
    ; ingress_host = toml.Sol_cli_toml.ingress_host
    ; ingress_path = toml.Sol_cli_toml.ingress_path
    ; cluster_issuer = env.cluster_issuer
    ; calls
    ; called_by = []
    ; extra_labels = toml.Sol_cli_toml.extra_labels
    ; progressive_delivery = toml.Sol_cli_toml.progressive_delivery
    }
    |> Result.ok
  in
  let rec collect acc = function
    | [] -> Ok (List.rev acc)
    | svc :: rest ->
      let* spec = to_spec svc in
      collect (spec :: acc) rest
  in
  let* resolved_services = collect [] loaded in
  let resolved_services =
    List.map
      (fun (svc : service_spec) ->
         let called_by =
           List.filter_map
             (fun (caller : service_spec) ->
                if
                  List.exists
                    (fun c ->
                       namespace_to_string c.target_namespace
                       = namespace_to_string svc.namespace
                       && k8s_name_to_string c.target_name
                          = k8s_name_to_string svc.k8s_name)
                    caller.calls
                then
                  Some
                    { env_var = call_env_var caller.source_name
                    ; url =
                        service_url
                          ~workspace
                          ~domain:caller.domain
                          ~k8s_name:caller.k8s_name
                    ; target_domain = caller.domain
                    ; target_name = caller.k8s_name
                    ; target_namespace = caller.namespace
                    }
                else None)
             resolved_services
         in
         { svc with called_by })
      resolved_services
  in
  (* FEAT-069: release identity is computed here because this is the first point
     at which all release-defining service inputs have been resolved. It is
     derived once from the canonical projection (which deliberately excludes
     provenance: timestamps, commit, output directory) and stored on the plan;
     downstream code must consume [plan.release_id] rather than recompute it. *)
  let release_id =
    Sol_cli_release_id.of_content
      { workspace
      ; environment = env.env
      ; workloads = List.map release_workload_of_spec resolved_services
      }
  in
  Ok
    { workspace
    ; release_id
    ; environment = env
    ; services = resolved_services
    ; topics = discover_topics ()
    ; migrations = discover_migrations ()
    ; schema_subjects = discover_schema_subjects ()
    ; consumer_groups = derive_consumer_groups workspace resolved_services
    ; requested_scope
    }
;;

let of_services ~workspace ~env ?requested_scope ?resolved_config services =
  match of_services_result ~workspace ~env ?requested_scope ?resolved_config services with
  | Ok plan -> plan
  | Error err -> failwith (plan_error_to_string err)
;;
