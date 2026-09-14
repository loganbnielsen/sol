let ( let* ) = Result.bind

type rollback_target =
  | Standard_deployment of
      { namespace : string
      ; name : string
      }
  | Argo_rollout of
      { namespace : string
      ; name : string
      }
  | No_op of string

type error =
  | Kubectl_error of Sol_cli_process.error
  | Plugin_missing of
      { namespace : string
      ; name : string
      }
  | Non_zero of
      { command : string
      ; exit_code : int
      }

let rollback_target_of_service (s : Sol_cli_deployment_plan.service_spec) =
  let ns = Sol_cli_deployment_plan.namespace_to_string s.namespace in
  let name = Sol_cli_deployment_plan.k8s_name_to_string s.k8s_name in
  match s.primitive with
  | Sol_cli_deployment_plan.Fn ->
    No_op "function workloads are managed by CronJob — no rollout history"
  | Sol_cli_deployment_plan.Svc | Sol_cli_deployment_plan.Worker ->
    (match s.progressive_delivery with
     | Some _ -> Argo_rollout { namespace = ns; name }
     | None -> Standard_deployment { namespace = ns; name })
;;

(* FEAT-063: even the plugin probe is scoped, so a rollback never has to be told
   which cluster twice — the same destination reaches the probe and the undo. *)
let argo_plugin_available ~ctx () =
  (match
     Sol_cli_process.run (Sol_cli_process.cmd [ "kubectl-argo-rollouts"; "version" ])
   with
   | Ok r -> r.Sol_cli_process.exit_code = 0
   | Error _ -> false)
  || Sol_cli_kubectl.probe ~ctx ~args:[ "argo"; "rollouts"; "version" ]
;;

let execute_rollback ~ctx target =
  match target with
  | No_op _ -> Ok ()
  | Standard_deployment { namespace; name } ->
    let kind_name = "deployment/" ^ name in
    (match Sol_cli_kubectl.rollout_undo ~ctx ~kind_name ~namespace with
     | Error e -> Error (Kubectl_error e)
     | Ok r when r.Sol_cli_process.exit_code <> 0 ->
       Error
         (Non_zero
            { command = "kubectl rollout undo"; exit_code = r.Sol_cli_process.exit_code })
     | Ok _ ->
       (match Sol_cli_kubectl.rollout_status ~ctx ~kind_name ~namespace with
        | Error e -> Error (Kubectl_error e)
        | Ok r when r.Sol_cli_process.exit_code <> 0 ->
          Error
            (Non_zero
               { command = "kubectl rollout status"
               ; exit_code = r.Sol_cli_process.exit_code
               })
        | Ok _ -> Ok ()))
  | Argo_rollout { namespace; name } ->
    if not (argo_plugin_available ~ctx ())
    then Error (Plugin_missing { namespace; name })
    else (
      match Sol_cli_kubectl.argo_rollout_undo ~ctx ~namespace ~name with
      | Error e -> Error (Kubectl_error e)
      | Ok r when r.Sol_cli_process.exit_code <> 0 ->
        Error
          (Non_zero
             { command = "kubectl argo rollouts undo"
             ; exit_code = r.Sol_cli_process.exit_code
             })
      | Ok _ ->
        (match Sol_cli_kubectl.argo_rollout_status ~ctx ~namespace ~name with
         | Error e -> Error (Kubectl_error e)
         | Ok r when r.Sol_cli_process.exit_code <> 0 ->
           Error
             (Non_zero
                { command = "kubectl argo rollouts status"
                ; exit_code = r.Sol_cli_process.exit_code
                })
         | Ok _ -> Ok ()))
;;

let error_to_string = function
  | Kubectl_error e -> "kubectl error: " ^ Sol_cli_process.error_to_string e
  | Plugin_missing { namespace; name } ->
    Printf.sprintf
      "service %s/%s uses Argo Rollouts — install the Argo Rollouts kubectl plugin to \
       roll back.\n\
      \    Install: https://argoproj.github.io/argo-rollouts/installation/#kubectl-plugin\n\
      \    Manual:  kubectl argo rollouts undo %s -n %s"
      namespace
      name
      name
      namespace
  | Non_zero { command; exit_code } ->
    Printf.sprintf "%s exited with code %d" command exit_code
;;

(* FEAT-066: reconstruction is a historical decode, not a planner (the red
   line). [service_specs_of_release] must depend exclusively on data reachable
   from the release record plus pure deterministic helpers -- never the
   workspace, [sol.toml]/[sol.yml], the environment, discovery, or current
   cluster state. If a decode ever seems to need an extra ambient argument,
   that is evidence the boundary is wrong, not a reason to widen this
   signature. *)

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

(* First pass: decode every recorded fact into a [service_spec], with
   [called_by] left empty -- it is not a recorded fact but a derivation of the
   whole record's call graph, computed in a second pass below. *)
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
  Ok
    { Sol_cli_deployment_plan.domain = w.domain
    ; source_name = w.name
    ; k8s_name
    ; namespace
    ; primitive
    ; source_dir = "" (* not manifest-affecting; not part of the record *)
    ; image = w.image
    ; config = w.config
    ; secrets = w.secrets
    ; volumes
    ; schedule = w.schedule
    ; replicas = w.replicas
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
;;

(* Second pass: [called_by] describes the CALLER, so it cannot be decoded from
   a workload's own record in isolation -- it is derived by scanning every
   other reconstructed workload's [calls] for an edge that targets this one,
   mirroring the planner's own second pass over [resolved_services]. The
   env var is recomputed with the shared [call_env_var] helper from the
   caller's name; reusing the stored forward-edge env var here would preserve
   most of the call graph while silently changing NetworkPolicy output
   (FEAT-066 finding). *)
let with_called_by (specs : Sol_cli_deployment_plan.service_spec list) =
  List.map
    (fun (spec : Sol_cli_deployment_plan.service_spec) ->
       let called_by =
         List.filter_map
           (fun (caller : Sol_cli_deployment_plan.service_spec) ->
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
           specs
       in
       { spec with called_by })
    specs
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
