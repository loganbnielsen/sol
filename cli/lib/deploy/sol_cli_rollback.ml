open Result.Syntax

let reconstruct_error ~release_id ~workload ~fact =
  Printf.sprintf "cannot reconstruct release %s: workload %s %s" release_id workload fact
;;

let decode_call
      ~release_id
      ~workload_name
      (env_var, target_domain, target_name_s, target_namespace_s)
  =
  let fail fact = Error (reconstruct_error ~release_id ~workload:workload_name ~fact) in
  match Sol_cli_kubernetes_name.make_k8s_name target_name_s with
  | Error msg ->
    fail (Printf.sprintf "has an invalid call target name %S: %s" target_name_s msg)
  | Ok target_name ->
    (match Sol_cli_kubernetes_name.make_namespace target_namespace_s with
     | Error msg ->
       fail
         (Printf.sprintf
            "has an invalid call target namespace %S: %s"
            target_namespace_s
            msg)
     | Ok target_namespace ->
       Ok
         { Sol_cli_deployment_plan.env_var
         ; url =
             Sol_cli_kubernetes_name.service_url
               ~namespace:target_namespace
               ~k8s_name:target_name
         ; target_domain
         ; target_name
         ; target_namespace
         })
;;

let decode_calls ~release_id ~workload_name rows =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | row :: rest ->
      let* call = decode_call ~release_id ~workload_name row in
      go (call :: acc) rest
  in
  go [] rows
;;

let decode_volume ~release_id ~workload_name (name, mount_path, size, access_mode_s) =
  match Sol_cli_toml.volume_access_mode_of_string access_mode_s with
  | Error msg ->
    Error
      (reconstruct_error
         ~release_id
         ~workload:workload_name
         ~fact:
           (Printf.sprintf "has an invalid volume access mode %S: %s" access_mode_s msg))
  | Ok access_mode -> Ok { Sol_cli_toml.name; mount_path; size; access_mode }
;;

let decode_volumes ~release_id ~workload_name rows =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | row :: rest ->
      let* v = decode_volume ~release_id ~workload_name row in
      go (v :: acc) rest
  in
  go [] rows
;;

let decode_optional ~release_id ~workload_name ~fact_of decode = function
  | None -> Ok None
  | Some raw ->
    (match decode raw with
     | Ok v -> Ok (Some v)
     | Error msg ->
       Error
         (reconstruct_error ~release_id ~workload:workload_name ~fact:(fact_of raw msg)))
;;

let decode_workload ~release_id ~workspace (w : Sol_cli_release.workload) =
  let* primitive =
    Sol_cli_deployment_plan.primitive_of_string w.primitive
    |> Result.map_error (fun msg ->
      reconstruct_error ~release_id ~workload:w.name ~fact:msg)
  in
  let* k8s_name =
    Sol_cli_deployment_plan.k8s_name_result w.name
    |> Result.map_error (fun err ->
      reconstruct_error
        ~release_id
        ~workload:w.name
        ~fact:(Sol_cli_deployment_plan.plan_error_to_string err))
  in
  let* namespace =
    Sol_cli_deployment_plan.namespace_result ~workspace ~domain:w.domain
    |> Result.map_error (fun err ->
      reconstruct_error
        ~release_id
        ~workload:w.name
        ~fact:(Sol_cli_deployment_plan.plan_error_to_string err))
  in
  let* cpu =
    Sol_cli_toml.cpu_quantity_of_string w.cpu
    |> Result.map_error (fun msg -> Printf.sprintf "has an invalid cpu %S: %s" w.cpu msg)
    |> Result.map_error (fun fact -> reconstruct_error ~release_id ~workload:w.name ~fact)
  in
  let* memory =
    Sol_cli_toml.memory_quantity_of_string w.memory
    |> Result.map_error (fun msg ->
      Printf.sprintf "has an invalid memory %S: %s" w.memory msg)
    |> Result.map_error (fun fact -> reconstruct_error ~release_id ~workload:w.name ~fact)
  in
  let* rollout_strategy, progressive_delivery =
    Sol_cli_toml.effective_rollout_of_string w.rollout
    |> Result.map_error (fun msg ->
      Printf.sprintf "has an invalid progressive delivery %S: %s" w.rollout msg)
    |> Result.map_error (fun fact -> reconstruct_error ~release_id ~workload:w.name ~fact)
  in
  let* volumes = decode_volumes ~release_id ~workload_name:w.name w.volumes in
  let* scheduled_concurrency =
    Sol_cli_toml.scheduled_concurrency_of_string w.scheduled_concurrency
    |> Result.map_error (fun msg ->
      Printf.sprintf
        "has an invalid scheduled_concurrency %S: %s"
        w.scheduled_concurrency
        msg)
    |> Result.map_error (fun fact -> reconstruct_error ~release_id ~workload:w.name ~fact)
  in
  let* () =
    if w.backoff_limit < 0
    then
      Error
        (reconstruct_error
           ~release_id
           ~workload:w.name
           ~fact:(Printf.sprintf "has an invalid backoff_limit %d" w.backoff_limit))
    else Ok ()
  in
  let* ingress_host =
    decode_optional
      ~release_id
      ~workload_name:w.name
      ~fact_of:(fun raw msg ->
        Printf.sprintf "has an invalid ingress host %S: %s" raw msg)
      Sol_cli_toml.hostname_of_string
      w.ingress_host
  in
  let* ingress_path =
    decode_optional
      ~release_id
      ~workload_name:w.name
      ~fact_of:(fun raw msg ->
        Printf.sprintf "has an invalid ingress path %S: %s" raw msg)
      Sol_cli_toml.ingress_path_of_string
      w.ingress_path
  in
  let* calls = decode_calls ~release_id ~workload_name:w.name w.calls in
  let* availability =
    Sol_cli_availability.of_string w.availability
    |> Result.map_error (fun msg ->
      reconstruct_error
        ~release_id
        ~workload:w.name
        ~fact:(Printf.sprintf "has an invalid availability %S: %s" w.availability msg))
  in
  let spec =
    { Sol_cli_deployment_plan.domain = w.domain
    ; source_name = w.name
    ; k8s_name
    ; namespace
    ; primitive
    ; source_dir = ""
    ; image = w.image
    ; config = w.config
    ; secrets = w.secrets
    ; volumes
    ; schedule = w.schedule
    ; scheduled_concurrency
    ; backoff_limit = w.backoff_limit
    ; replicas = w.replicas
    ; language = None
    ; availability
    ; consumes_kafka = w.consumes_kafka
    ; cpu
    ; memory
    ; rollout_strategy
    ; ingress_host
    ; ingress_path
    ; cluster_issuer = w.cluster_issuer
    ; calls
    ; called_by = []
    ; extra_labels = w.extra_labels
    ; progressive_delivery
    }
  in
  let* () =
    Sol_cli_deployment_plan.validate_persistence spec
    |> Result.map_error (fun err ->
      reconstruct_error
        ~release_id
        ~workload:w.name
        ~fact:(Sol_cli_deployment_plan.plan_error_to_string err))
  in
  let* () =
    Sol_cli_deployment_plan.validate_availability spec
    |> Result.map_error (fun err ->
      reconstruct_error
        ~release_id
        ~workload:w.name
        ~fact:(Sol_cli_deployment_plan.plan_error_to_string err))
  in
  Ok spec
;;

let with_called_by (specs : Sol_cli_deployment_plan.service_spec list) =
  specs
  |> List.map (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    let called_by =
      specs
      |> List.filter_map (fun (caller : Sol_cli_deployment_plan.service_spec) ->
        if
          List.exists
            (fun (c : Sol_cli_deployment_plan.service_call) ->
               Sol_cli_kubernetes_name.namespace_to_string c.target_namespace
               = Sol_cli_kubernetes_name.namespace_to_string spec.namespace
               && Sol_cli_kubernetes_name.k8s_name_to_string c.target_name
                  = Sol_cli_kubernetes_name.k8s_name_to_string spec.k8s_name)
            caller.calls
        then
          Some
            { Sol_cli_deployment_plan.env_var =
                Sol_cli_kubernetes_name.call_env_var caller.source_name
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
    { spec with called_by })
;;

let service_specs_of_release (release : Sol_cli_release.t) =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | (w : Sol_cli_release.recorded_workload) :: rest ->
      let* spec =
        decode_workload
          ~release_id:w.Sol_cli_release_id.applied_by
          ~workspace:release.workspace
          w.spec
      in
      go ((spec, w.applied_by) :: acc) rest
  in
  let* applied = go [] release.workloads in
  let specs = with_called_by (List.map fst applied) in
  Ok (List.map2 (fun spec (_, applied_by) -> spec, applied_by) specs applied)
;;

type migration_check_error =
  | Contracting_migration of
      { release_id : string
      ; migration : string
      }
  | Undeclared_disposition of
      { release_id : string
      ; migration : string
      ; reason : string
      }
  | Applied_migration_absent of
      { release_id : string
      ; version : int
      }
  | Applied_state_unavailable of
      { release_id : string
      ; reason : string
      }

let migration_check_error_to_string = function
  | Contracting_migration { release_id; migration } ->
    Printf.sprintf
      "cannot roll back to release %s: %s is a contracting migration applied since that \
       release -- restoring %s could run its old application code against a schema it no \
       longer supports. No override: resolve the incompatibility forward instead."
      release_id
      migration
      release_id
  | Undeclared_disposition { release_id; migration; reason } ->
    Printf.sprintf
      "cannot roll back to release %s: migration %s %s -- declare a sol:disposition \
       before rolling back across it."
      release_id
      migration
      reason
  | Applied_migration_absent { release_id; version } ->
    Printf.sprintf
      "cannot roll back to release %s: the target has migration version %d applied, and \
       this checkout has no file for it, so its disposition cannot be checked. An absent \
       file is not evidence that the schema did not change -- run the rollback from the \
       checkout that contains it, or resolve the incompatibility forward."
      release_id
      version
  | Applied_state_unavailable { release_id; reason } ->
    Printf.sprintf
      "cannot roll back to release %s: the target's applied migration state could not be \
       compared (%s). Failing closed rather than assuming the schema is unchanged."
      release_id
      reason
;;

let release_migration_versions ~release =
  let open Result.Syntax in
  List.fold_left
    (fun acc migration ->
       let* versions = acc in
       match Sol_cli_migration.parse_version migration with
       | Some (version, _) -> Ok (version :: versions)
       | None ->
         Error
           (Applied_state_unavailable
              { release_id = release.Sol_cli_release.release_id
              ; reason =
                  Printf.sprintf
                    "its recorded migration %S cannot be interpreted, so the boundary \
                     between its schema and the target's cannot be established"
                    migration
              }))
    (Ok [])
    release.Sol_cli_release.migrations
;;

let check_migration_boundary
      ~(release : Sol_cli_release.t)
      ~(migrations_dir : string)
      ~(current_migrations : string list)
      ~(applied : unit -> (int list, string) result)
  : (unit, migration_check_error) result
  =
  let open Result.Syntax in
  let* release_versions = release_migration_versions ~release in
  let local =
    List.filter_map
      (fun file ->
         Option.map
           (fun (version, _) -> version, file)
           (Sol_cli_migration.parse_version file))
      current_migrations
  in
  let local_beyond =
    List.filter (fun (version, _) -> not (List.mem version release_versions)) local
  in
  let rec go = function
    | [] -> Ok ()
    | migration :: rest ->
      (match
         Sol_cli_migration_disposition.read_file
           ~path:(Filename.concat migrations_dir migration)
       with
       | Error reason ->
         Error
           (Undeclared_disposition { release_id = release.release_id; migration; reason })
       | Ok Sol_cli_migration_disposition.Contract ->
         Error (Contracting_migration { release_id = release.release_id; migration })
       | Ok Sol_cli_migration_disposition.Expand -> go rest)
  in
  let* () = go (local_beyond |> List.map snd |> List.sort String.compare) in
  let* applied =
    applied ()
    |> Result.map_error (fun reason ->
      Applied_state_unavailable { release_id = release.release_id; reason })
  in
  let applied_beyond =
    applied
    |> List.filter (fun version -> not (List.mem version release_versions))
    |> List.sort_uniq compare
  in
  match
    List.filter
      (fun version ->
         not
           (List.exists (fun (local_version, _) -> local_version = version) local_beyond))
      applied_beyond
  with
  | [] -> Ok ()
  | version :: _ ->
    Error (Applied_migration_absent { release_id = release.release_id; version })
;;

type apply_mode_check_error = Gitops_owned of { release_id : string }

let apply_mode_check_error_to_string = function
  | Gitops_owned { release_id } ->
    Printf.sprintf
      "cannot roll back to release %s: it was applied as a GitOps/controller-owned \
       release, so Sol does not own the target resources. A direct apply + immediate \
       readback would not establish a stable transition. Roll it back through the GitOps \
       pipeline instead."
      release_id
;;

let check_apply_mode ~(release : Sol_cli_release.t)
  : (unit, apply_mode_check_error) result
  =
  match release.apply_mode with
  | Sol_cli_release.Direct -> Ok ()
  | Sol_cli_release.Gitops -> Error (Gitops_owned { release_id = release.release_id })
;;

type live_kind =
  | Live_deployment
  | Live_rollout
  | Live_cronjob

let live_kind_path = function
  | Live_deployment -> "deployment", [ "spec"; "template"; "metadata"; "labels" ]
  | Live_rollout -> "rollout", [ "spec"; "template"; "metadata"; "labels" ]
  | Live_cronjob ->
    "cronjob", [ "spec"; "jobTemplate"; "spec"; "template"; "metadata"; "labels" ]
;;

let live_resource_and_jsonpath kind =
  let resource, path = live_kind_path kind in
  resource, "{." ^ String.concat "." path ^ ".release}"
;;

let live_kind_of_service (s : Sol_cli_deployment_plan.service_spec) =
  match s.primitive with
  | Sol_cli_deployment_plan.Fn -> Live_cronjob
  | Sol_cli_deployment_plan.Svc | Sol_cli_deployment_plan.Worker ->
    (match s.progressive_delivery with
     | Some _ -> Live_rollout
     | None -> Live_deployment)
;;

let read_jsonpath ~ctx ~resource ~name ~namespace ~jsonpath =
  match
    Sol_cli_kubectl.get ~ctx ~resource ~name ~namespace ~output:("jsonpath=" ^ jsonpath)
  with
  | Ok r -> Ok (String.trim r.stdout)
  | Error e -> Error (Sol_cli_process.error_to_string e)
;;

type workload_identity =
  { kind : live_kind
  ; namespace : string
  ; name : string
  }

let same_identity a b =
  a.kind = b.kind && String.equal a.namespace b.namespace && String.equal a.name b.name
;;

let identity_of_spec (spec : Sol_cli_deployment_plan.service_spec) : workload_identity =
  { kind = live_kind_of_service spec
  ; namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace
  ; name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name
  }
;;

let string_at path json =
  Sol_cli_json.field path json |> Sol_cli_json.string |> Option.value ~default:""
;;

let pod_template_labels kind item =
  match Sol_cli_json.field (snd (live_kind_path kind)) item with
  | `Assoc kvs ->
    kvs
    |> List.filter_map (fun (k, v) ->
      match v with
      | `String s -> Some (k, s)
      | _ -> None)
  | _ -> []
;;

let workload_rows_of_payload ~kind ~workspace (payload : Yojson.Safe.t) =
  let wanted = Sol_cli_kubernetes_name.sanitize_label_value workspace in
  Sol_cli_json.require ~what:"kubectl get output" [ "items" ] Sol_cli_json.list payload
  |> Result.map
     @@ List.filter_map (fun item ->
       let labels = pod_template_labels kind item in
       match List.assoc_opt "workspace" labels with
       | Some w when String.equal w wanted ->
         let identity =
           { kind
           ; namespace = string_at [ "metadata"; "namespace" ] item
           ; name = string_at [ "metadata"; "name" ] item
           }
         in
         Some (identity, Option.value (List.assoc_opt "release" labels) ~default:"")
       | _ -> None)
;;

let live_workloads ~(ctx : Sol_cli_kube_destination.context) ~(workspace : string)
  : ((workload_identity * string) list, string) result
  =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | kind :: rest ->
      let resource, _ = live_kind_path kind in
      (match
         Sol_cli_kubectl.get_raw ~ctx ~args:[ "get"; resource; "-A"; "-o"; "json" ]
       with
       | Ok r ->
         let open Result.Syntax in
         let* rows =
           Sol_cli_json.decode
             ~what:(Printf.sprintf "kubectl get %s output" resource)
             r.stdout
           |> Fun.flip Result.bind (workload_rows_of_payload ~kind ~workspace)
         in
         go (List.rev_append rows acc) rest
       | Error e when kind = Live_rollout && Sol_cli_kubectl.classify e = No_resource_type
         -> go acc rest
       | Error e ->
         Error
           (Printf.sprintf
              "kubectl get %s failed: %s"
              resource
              (Sol_cli_process.error_to_string e)))
  in
  go [] [ Live_deployment; Live_rollout; Live_cronjob ]
;;

type workload_mismatch =
  { kind : live_kind
  ; namespace : string
  ; name : string
  ; actual : string
  }

type workload_report =
  { mismatched : workload_mismatch list
  ; missing : workload_identity list
  ; unexpected : (workload_identity * string) list
  }

let workload_report_ok (r : workload_report) =
  r.mismatched = [] && r.missing = [] && r.unexpected = []
;;

let unexpected_workloads
      ~(expected : Sol_cli_deployment_plan.service_spec list)
      ~(live : (workload_identity * string) list)
  =
  let expected_ids = List.map identity_of_spec expected in
  List.filter (fun (id, _) -> not (List.exists (same_identity id) expected_ids)) live
;;

let verify_workloads
      ~(expected : (Sol_cli_deployment_plan.service_spec * string) list)
      ~(live : (workload_identity * string) list)
  : workload_report
  =
  let mismatched, missing =
    List.fold_left
      (fun (mismatched, missing) (spec, applied_by) ->
         let id = identity_of_spec spec in
         match List.find_opt (fun (i, _) -> same_identity i id) live with
         | None -> mismatched, id :: missing
         | Some (_, actual) ->
           if String.equal actual applied_by
           then mismatched, missing
           else
             ( { kind = id.kind; namespace = id.namespace; name = id.name; actual }
               :: mismatched
             , missing ))
      ([], [])
      expected
  in
  { mismatched = List.rev mismatched
  ; missing = List.rev missing
  ; unexpected = unexpected_workloads ~expected:(List.map fst expected) ~live
  }
;;

let display_actual actual = if String.equal actual "" then "<none>" else actual
let kind_resource kind = fst (live_kind_path kind)

let live_kind_volumes_path = function
  | Live_deployment | Live_rollout -> [ "spec"; "template"; "spec"; "volumes" ]
  | Live_cronjob -> [ "spec"; "jobTemplate"; "spec"; "template"; "spec"; "volumes" ]
;;

type prune_target =
  { resource : string
  ; namespace : string
  ; name : string
  }

type prune_report =
  { removed : prune_target list
  ; retained : prune_target list
  }

let named_target (id : workload_identity) resource name =
  { resource; namespace = id.namespace; name }
;;

let auxiliary_targets ~live_names (id : workload_identity) =
  let named resource name = named_target id resource name in
  let base =
    [ named "serviceaccount" id.name
    ; named "configmap" (id.name ^ "-env")
    ; named "networkpolicy" id.name
    ; named "service" id.name
    ; named "ingress" id.name
    ; named "poddisruptionbudget" id.name
    ]
  in
  let progressive =
    match id.kind with
    | Live_deployment | Live_cronjob -> []
    | Live_rollout ->
      let occupied suffix = List.exists (String.equal (id.name ^ suffix)) live_names in
      [ "-active", named "service" (id.name ^ "-active")
      ; "-preview", named "service" (id.name ^ "-preview")
      ; "-active", named "ingress" (id.name ^ "-active")
      ]
      |> List.filter_map (fun (suffix, target) ->
        if occupied suffix then None else Some target)
  in
  base @ progressive
;;

let plan_prune ~surplus ~live_names ~claims : prune_report =
  let removed =
    surplus
    |> List.concat_map (fun id ->
      named_target id (kind_resource id.kind) id.name :: auxiliary_targets ~live_names id)
  in
  let retained =
    surplus
    |> List.concat_map (fun id ->
      claims id |> List.map (named_target id "persistentvolumeclaim"))
  in
  { removed; retained }
;;

let claim_names_of_json kind json =
  match Sol_cli_json.field (live_kind_volumes_path kind) json with
  | `List volumes ->
    volumes
    |> List.filter_map (fun volume ->
      Sol_cli_json.field [ "persistentVolumeClaim"; "claimName" ] volume
      |> Sol_cli_json.string)
  | _ -> []
;;

let live_claim_names ~ctx (id : workload_identity) =
  match
    Sol_cli_kubectl.get
      ~ctx
      ~resource:(kind_resource id.kind)
      ~name:id.name
      ~namespace:id.namespace
      ~output:"json"
  with
  | Error e ->
    Sol_cli_report.warn
      "could not read %s %s/%s to enumerate the volumes it owned (%s); any \
       PersistentVolumeClaim it created is retained but cannot be listed."
      (kind_resource id.kind)
      id.namespace
      id.name
      (Sol_cli_process.error_to_string e);
    []
  | Ok output ->
    (match Sol_cli_json.decode ~what:"live workload" output.Sol_cli_process.stdout with
     | Error msg ->
       Sol_cli_report.warn
         "could not read %s %s/%s to enumerate the volumes it owned (%s); any \
          PersistentVolumeClaim it created is retained but cannot be listed."
         (kind_resource id.kind)
         id.namespace
         id.name
         msg;
       []
     | Ok json -> claim_names_of_json id.kind json)
;;

let delete_target ~ctx (t : prune_target) =
  match
    Sol_cli_kubectl.delete ~ctx ~resource:t.resource ~name:t.name ~namespace:t.namespace
  with
  | Ok () -> None
  | Error e ->
    Some
      (Printf.sprintf
         "%s %s/%s: %s"
         t.resource
         t.namespace
         t.name
         (Sol_cli_process.error_to_string e))
;;

let prune_workloads ~(ctx : Sol_cli_kube_destination.context) ~live ~surplus
  : (prune_report, string) result
  =
  let live_names = List.map (fun ((id : workload_identity), _) -> id.name) live in
  let report =
    plan_prune ~surplus:(List.map fst surplus) ~live_names ~claims:(live_claim_names ~ctx)
  in
  match List.filter_map (delete_target ~ctx) report.removed with
  | [] -> Ok report
  | errors ->
    Error
      (Printf.sprintf
         "could not prune %d surplus object(s):\n%s"
         (List.length errors)
         (String.concat "\n" errors))
;;

let retained_message ~(release : Sol_cli_release.t) retained =
  Printf.sprintf
    "rollback retained %d object(s) it does not delete:\n\
     %s\n\
     Storage lifetime is not rollback's decision (DEC-033). The workloads and the \
     pointer name release %s, but these objects were deliberately left in place."
    (List.length retained)
    (String.concat
       "\n"
       (List.map
          (fun (t : prune_target) ->
             Printf.sprintf "  %s %s/%s" t.resource t.namespace t.name)
          retained))
    release.release_id
;;

let workload_report_to_string ~(release : Sol_cli_release.t) (r : workload_report)
  : string
  =
  let mismatch_lines =
    r.mismatched
    |> List.map (fun (m : workload_mismatch) ->
      Printf.sprintf
        "workload state mismatch: %s %s/%s carries release %s, expected %s"
        (kind_resource m.kind)
        m.namespace
        m.name
        (display_actual m.actual)
        release.release_id)
  in
  let missing_lines =
    r.missing
    |> List.map (fun (i : workload_identity) ->
      Printf.sprintf
        "workload missing: %s %s/%s is not present in the cluster"
        (kind_resource i.kind)
        i.namespace
        i.name)
  in
  let unexpected_lines =
    r.unexpected
    |> List.map (fun ((i : workload_identity), actual) ->
      Printf.sprintf
        "unexpected workload: %s %s/%s carries release %s but is not part of release %s"
        (kind_resource i.kind)
        i.namespace
        i.name
        (display_actual actual)
        release.release_id)
  in
  String.concat "\n" (mismatch_lines @ missing_lines @ unexpected_lines)
;;

type pointer_report =
  | Pointer_confirmed
  | Pointer_names of string
  | Pointer_unreadable of string

let verify_pointer
      ~(ctx : Sol_cli_kube_destination.context)
      ~(release : Sol_cli_release.t)
  : pointer_report
  =
  match
    read_jsonpath
      ~ctx
      ~resource:"configmap"
      ~name:(Sol_cli_release.current_configmap_name ~workspace:release.workspace)
      ~namespace:"default"
      ~jsonpath:"{.data.release_id}"
  with
  | Error reason -> Pointer_unreadable reason
  | Ok actual ->
    if String.equal actual release.release_id
    then Pointer_confirmed
    else Pointer_names actual
;;

let pointer_report_ok = function
  | Pointer_confirmed -> true
  | Pointer_names _ | Pointer_unreadable _ -> false
;;

let pointer_report_to_string ~(release : Sol_cli_release.t) = function
  | Pointer_confirmed ->
    Printf.sprintf
      "pointer verified: %s names %s"
      (Sol_cli_release.current_configmap_name ~workspace:release.workspace)
      release.release_id
  | Pointer_names actual ->
    Printf.sprintf
      "pointer mismatch: %s names %s, expected %s"
      (Sol_cli_release.current_configmap_name ~workspace:release.workspace)
      (display_actual actual)
      release.release_id
  | Pointer_unreadable reason ->
    Printf.sprintf
      "pointer unreadable: %s could not be read, so the release it names is unknown \
       (%s); expected %s"
      (Sol_cli_release.current_configmap_name ~workspace:release.workspace)
      reason
      release.release_id
;;

type transaction_deps =
  { ensure_held : unit -> (unit, string) result
  ; applied_migrations : unit -> (int list, string) result
  ; apply : (Sol_cli_deployment_plan.service_spec * string) list -> (unit, string) result
  ; live_workloads : unit -> ((workload_identity * string) list, string) result
  ; prune :
      live:(workload_identity * string) list
      -> surplus:(workload_identity * string) list
      -> (prune_report, string) result
  ; move_pointer : unit -> (unit, string) result
  ; verify_pointer : unit -> pointer_report
  ; record_consumer_groups : string list -> (unit, string) result
  }

let consumer_groups_of_release (release : Sol_cli_release.t) =
  release.workloads
  |> List.filter_map (fun (recorded : Sol_cli_release_id.recorded_workload) ->
    let workload = recorded.spec in
    if String.equal workload.primitive "worker" && workload.consumes_kafka
    then Some (Printf.sprintf "%s.%s.%s" release.workspace workload.domain workload.name)
    else None)
  |> List.sort_uniq String.compare
;;

let execute
      ~(release : Sol_cli_release.t)
      ~migrations_dir
      ~current_migrations
      ~(deps : transaction_deps)
  : (unit, string) result
  =
  let* () =
    match check_apply_mode ~release with
    | Error e -> Error (apply_mode_check_error_to_string e)
    | Ok () -> Ok ()
  in
  let* () =
    match
      check_migration_boundary
        ~release
        ~migrations_dir
        ~current_migrations
        ~applied:deps.applied_migrations
    with
    | Error e -> Error (migration_check_error_to_string e)
    | Ok () -> Ok ()
  in
  let* specs = service_specs_of_release release in
  let* () = deps.ensure_held () in
  let* () =
    match deps.apply specs with
    | Ok () -> Ok ()
    | Error msg ->
      Error
        (Printf.sprintf
           "%s\n\
            rollback incomplete: not every workload could be applied, so the ones that \
            were may already carry release %s while the current-release pointer still \
            names the previous release. Re-run the rollback (or redeploy) to finish, and \
            verify cluster state before relying on it."
           msg
           release.release_id)
  in
  let* prune_report =
    match deps.live_workloads () with
    | Error msg -> Error (Printf.sprintf "cannot verify rollback: %s" msg)
    | Ok live ->
      let report = verify_workloads ~expected:specs ~live in
      if report.mismatched <> [] || report.missing <> []
      then
        Error
          (Printf.sprintf
             "%s\n\
              rollback incomplete: live workloads do not match release %s; the \
              current-release pointer was left unchanged"
             (workload_report_to_string ~release report)
             release.release_id)
      else (
        match deps.ensure_held () with
        | Error msg -> Error msg
        | Ok () ->
          (match deps.prune ~live ~surplus:report.unexpected with
           | Ok prune_report -> Ok prune_report
           | Error msg ->
             Error
               (Printf.sprintf
                  "%s\n\
                   rollback incomplete: could not prune surplus workloads; the \
                   current-release pointer was left unchanged"
                  msg)))
  in
  let* () = deps.ensure_held () in
  let* () = deps.move_pointer () in
  let pointer = deps.verify_pointer () in
  if not (pointer_report_ok pointer)
  then
    Error
      (Printf.sprintf
         "%s\n\
          rollback incomplete: the pointer was moved but could not be confirmed as the \
          restored release; verify cluster state before relying on this rollback."
         (pointer_report_to_string ~release pointer))
  else (
    let groups = consumer_groups_of_release release in
    match deps.record_consumer_groups groups with
    | Ok () ->
      if prune_report.retained <> []
      then Sol_cli_report.warn "%s" (retained_message ~release prune_report.retained);
      Ok ()
    | Error msg ->
      Error
        (Printf.sprintf
           "%s\n\
            rollback incomplete: the workloads and the pointer were restored, but the \
            workspace's consumer-group safety record could not be corrected, so the next \
            deploy's removal check will describe the release that was rolled back. Fix \
            access to the deploy-state ConfigMap and roll back again, or pass \
            --confirm-group-change to the next deploy."
           msg))
;;

let commit_matches ~commit stored =
  let commit = String.lowercase_ascii (String.trim commit) in
  let stored = String.lowercase_ascii (String.trim stored) in
  if commit = "" || stored = ""
  then false
  else
    String.starts_with ~prefix:commit stored || String.starts_with ~prefix:stored commit
;;

type commit_resolution =
  | Commit_invalid of string
  | Commit_no_match
  | Commit_ambiguous of (string * string) list
  | Commit_resolved of string

let resolve_matches ~commit ~target ~scope_string (events : Sol_cli_deployment.t list)
  : commit_resolution
  =
  let matches =
    events
    |> List.filter (fun (e : Sol_cli_deployment.t) ->
      (match e.outcome with
       | Applied -> true
       | Apply_failed -> false)
      && commit_matches ~commit e.git_commit
      && (match e.target with
          | Some t -> String.equal t target
          | None -> false)
      &&
      match scope_string with
      | None -> true
      | Some wanted -> String.equal e.requested_scope wanted)
  in
  let by_release_id = Hashtbl.create 8 in
  matches
  |> List.iter (fun (e : Sol_cli_deployment.t) ->
    let release_id = Sol_cli_release_id.to_string e.release_id in
    if not (Hashtbl.mem by_release_id release_id)
    then Hashtbl.add by_release_id release_id e.requested_scope);
  match Hashtbl.fold (fun k v acc -> (k, v) :: acc) by_release_id [] with
  | [] -> Commit_no_match
  | [ (release_id, _) ] -> Commit_resolved release_id
  | candidates ->
    Commit_ambiguous (List.sort (fun (a, _) (b, _) -> String.compare a b) candidates)
;;

let resolve_commit ~commit ?scope ~target (events : Sol_cli_deployment.t list)
  : commit_resolution
  =
  let parsed_scope =
    scope
    |> Option.map (fun s ->
      Sol_cli_deployment_scope.parse_request ~what:"--scope" (Some s))
  in
  match parsed_scope with
  | Some (Error msg) -> Commit_invalid msg
  | None -> resolve_matches ~commit ~target ~scope_string:None events
  | Some (Ok request) ->
    resolve_matches
      ~commit
      ~target
      ~scope_string:(Some (Sol_cli_deployment_scope.request_to_string request))
      events
;;

let commit_resolution_to_string ~commit ~target ?scope resolution =
  let where =
    Printf.sprintf
      "commit %s on target %s%s"
      commit
      target
      (match scope with
       | None -> ""
       | Some s -> Printf.sprintf " (scope %s)" s)
  in
  match resolution with
  | Commit_invalid msg -> msg
  | Commit_no_match -> Printf.sprintf "no successful deploy found for %s" where
  | Commit_ambiguous candidates ->
    Printf.sprintf
      "%s matches more than one release -- pass one explicitly:\n%s"
      where
      (String.concat
         "\n"
         (candidates
          |> List.map (fun (release_id, requested_scope) ->
            Printf.sprintf "  %s  (requested scope: %s)" release_id requested_scope)))
  | Commit_resolved release_id ->
    Printf.sprintf "resolved %s to release %s" where release_id
;;
