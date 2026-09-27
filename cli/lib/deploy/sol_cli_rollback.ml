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
    ; scheduled_concurrency = Sol_cli_toml.Allow
    ; backoff_limit = 3
    ; replicas = w.replicas
    ; language = None
    ; availability =
        (match Sol_cli_availability.of_string w.availability with
         | Ok a -> a
         | Error _ -> Sol_cli_availability.Single)
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
  let release_id = release.release_id in
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | w :: rest ->
      let* spec = decode_workload ~release_id ~workspace:release.workspace w in
      go (spec :: acc) rest
  in
  let* specs = go [] release.workloads in
  Ok (with_called_by specs)
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
;;

let check_migration_boundary
      ~(release : Sol_cli_release.t)
      ~(migrations_dir : string)
      ~(current_migrations : string list)
  : (unit, migration_check_error) result
  =
  let new_migrations =
    List.filter (fun m -> not (List.mem m release.migrations)) current_migrations
    |> List.sort String.compare
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
  go new_migrations
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
  | Ok r -> String.trim r.stdout
  | _ -> ""
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
         (match
            Sol_cli_json.decode
              ~what:(Printf.sprintf "kubectl get %s output" resource)
              r.stdout
            |> Fun.flip Result.bind (workload_rows_of_payload ~kind ~workspace)
          with
          | Error msg -> Error msg
          | Ok rows -> go (List.rev_append rows acc) rest)
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
      ~(release : Sol_cli_release.t)
      ~(expected : Sol_cli_deployment_plan.service_spec list)
      ~(live : (workload_identity * string) list)
  : workload_report
  =
  let expected_ids = List.map identity_of_spec expected in
  let mismatched, missing =
    List.fold_left
      (fun (mismatched, missing) id ->
         match List.find_opt (fun (i, _) -> same_identity i id) live with
         | None -> mismatched, id :: missing
         | Some (_, actual) ->
           if String.equal actual release.release_id
           then mismatched, missing
           else
             ( { kind = id.kind; namespace = id.namespace; name = id.name; actual }
               :: mismatched
             , missing ))
      ([], [])
      expected_ids
  in
  { mismatched = List.rev mismatched
  ; missing = List.rev missing
  ; unexpected = unexpected_workloads ~expected ~live
  }
;;

let display_actual actual = if String.equal actual "" then "<none>" else actual
let kind_resource kind = fst (live_kind_path kind)

let prune_workloads ~(ctx : Sol_cli_kube_destination.context) surplus
  : (unit, string) result
  =
  let errors =
    surplus
    |> List.filter_map (fun ((id : workload_identity), _actual) ->
      match
        Sol_cli_kubectl.delete
          ~ctx
          ~resource:(kind_resource id.kind)
          ~name:id.name
          ~namespace:id.namespace
      with
      | Ok () -> None
      | Error e ->
        Some
          (Printf.sprintf
             "%s %s/%s: %s"
             (kind_resource id.kind)
             id.namespace
             id.name
             (Sol_cli_process.error_to_string e)))
  in
  match errors with
  | [] -> Ok ()
  | _ ->
    Error
      (Printf.sprintf
         "could not prune %d surplus workload(s):\n%s"
         (List.length errors)
         (String.concat "\n" errors))
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
  { pointer_actual : string
  ; pointer_ok : bool
  }

let verify_pointer
      ~(ctx : Sol_cli_kube_destination.context)
      ~(release : Sol_cli_release.t)
  : pointer_report
  =
  let pointer_actual =
    read_jsonpath
      ~ctx
      ~resource:"configmap"
      ~name:(Sol_cli_release.current_configmap_name ~workspace:release.workspace)
      ~namespace:"default"
      ~jsonpath:"{.data.release_id}"
  in
  { pointer_actual; pointer_ok = String.equal pointer_actual release.release_id }
;;

let pointer_report_ok (r : pointer_report) = r.pointer_ok

let pointer_report_to_string ~(release : Sol_cli_release.t) (r : pointer_report) : string =
  Printf.sprintf
    "pointer mismatch: %s names %s, expected %s"
    (Sol_cli_release.current_configmap_name ~workspace:release.workspace)
    (display_actual r.pointer_actual)
    release.release_id
;;

type transaction_deps =
  { apply : Sol_cli_deployment_plan.service_spec list -> (unit, string) result
  ; live_workloads : unit -> ((workload_identity * string) list, string) result
  ; prune : (workload_identity * string) list -> (unit, string) result
  ; move_pointer : unit -> (unit, string) result
  ; verify_pointer : unit -> pointer_report
  }

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
    match check_migration_boundary ~release ~migrations_dir ~current_migrations with
    | Error e -> Error (migration_check_error_to_string e)
    | Ok () -> Ok ()
  in
  let* specs = service_specs_of_release release in
  let* () = deps.apply specs in
  let* () =
    match deps.live_workloads () with
    | Error msg -> Error (Printf.sprintf "cannot verify rollback: %s" msg)
    | Ok live ->
      let report = verify_workloads ~release ~expected:specs ~live in
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
        match deps.prune report.unexpected with
        | Ok () -> Ok ()
        | Error msg ->
          Error
            (Printf.sprintf
               "%s\n\
                rollback incomplete: could not prune surplus workloads; the \
                current-release pointer was left unchanged"
               msg))
  in
  let* () = deps.move_pointer () in
  let pointer = deps.verify_pointer () in
  if pointer_report_ok pointer
  then Ok ()
  else
    Error
      (Printf.sprintf
         "%s\n\
          rollback incomplete: the pointer was moved but does not read back as the \
          restored release; verify cluster state before relying on this rollback."
         (pointer_report_to_string ~release pointer))
;;

let commit_matches ~commit stored =
  let commit = String.lowercase_ascii (String.trim commit) in
  let stored = String.lowercase_ascii (String.trim stored) in
  if commit = "" || stored = ""
  then false
  else (
    let is_prefix ~prefix s =
      String.length prefix <= String.length s
      && String.sub s 0 (String.length prefix) = prefix
    in
    is_prefix ~prefix:commit stored || is_prefix ~prefix:stored commit)
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
