let ( let* ) = Result.bind

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
  let spec =
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
    ; (* FEAT-079: not recorded on any release predating this field; a
         restored release always gets the same default a fresh deploy with
         no explicit config would. *)
      scheduled_concurrency = Sol_cli_toml.Allow
    ; backoff_limit = 3
    ; replicas =
        w.replicas
        (* FEAT-088: language is a plan-time declaration, deliberately not part of
         the release record (DEC-022 §7), so a reconstructed release carries
         none. *)
    ; language = None
    ; (* AUDIT-080: availability changes the rendered placement, disruption
         budget and probes, so it *is* recorded and a restored release keeps the
         claim it was rendered with. *)
      availability =
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

(* FEAT-066 / DEC-018: the migration boundary check. Unlike reconstruction,
   this step legitimately reads ambient state (today's migration files) --
   its whole job is comparing the target release's recorded migration set
   against what exists now, which by definition cannot be done from the
   release record alone. [current_migrations] and [migrations_dir] are taken
   as arguments rather than read internally so the check stays testable and
   the caller controls where "now" comes from. *)

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

(* DEC-018: refuse only on a *contracting* migration between the target release
   and now. An [Expand] migration never blocks a rollback -- expand/contract
   discipline is exactly what keeps old application code working against a
   newer schema. A migration this check cannot classify (missing or malformed
   disposition) blocks just as hard as a declared [Contract] -- there is no
   "assume expand" fallback, because that would silently accept the exact risk
   this check exists to catch. *)
let check_migration_boundary
      ~(release : Sol_cli_release.t)
      ~(migrations_dir : string)
      ~(current_migrations : string list)
  : (unit, migration_check_error) result
  =
  let new_migrations =
    List.filter
      (fun m -> not (List.mem m release.Sol_cli_release.migrations))
      current_migrations
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
           (Undeclared_disposition
              { release_id = release.Sol_cli_release.release_id; migration; reason })
       | Ok Sol_cli_migration_disposition.Contract ->
         Error
           (Contracting_migration
              { release_id = release.Sol_cli_release.release_id; migration })
       | Ok Sol_cli_migration_disposition.Expand -> go rest)
  in
  go new_migrations
;;

(* FEAT-066 finding: a GitOps-emitted release's resources are owned by a
   controller, not Sol. Direct-applying them and reading the labels back
   immediately would report a transition Sol does not actually control -- the
   controller can revert it right after the readback -- so Sol must refuse
   outright rather than produce that false success. A controller-mediated
   rollback is a separate, undesigned path. *)
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

(* FEAT-066: verification, the last step of the enforcement order. It reads
   live cluster state on purpose -- verification is exactly the step that
   checks whether the mutation just performed actually landed, which the
   release record alone cannot answer. The two failure modes are reported
   independently rather than collapsed into one "verification failed",
   because one passing and the other failing is operationally meaningful
   evidence: a workload mismatch with a correct pointer means the apply
   partly failed; a pointer mismatch with correct workloads means the apply
   worked but something raced the pointer move. *)

type live_kind =
  | Live_deployment
  | Live_rollout
  | Live_cronjob

(* Mirrors sol_cli_manifest_yaml.ml's render_taxonomy_labels call sites: the
   taxonomy labels -- `workspace`, and the `release` label -- always land in the
   pod template, never the object's own top-level metadata. This is the single
   source for that path, used both to build a jsonpath for one label and to walk
   a listed object's labels client-side, so a renderer change has one place to
   break instead of two. *)
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

(* Deliberately not rollback_target_of_service: that function's No_op for [Fn]
   encodes "no kubectl-rollout-undo history", which is irrelevant here -- a
   CronJob still carries a `release` label worth verifying. *)
let live_kind_of_service (s : Sol_cli_deployment_plan.service_spec) =
  match s.Sol_cli_deployment_plan.primitive with
  | Sol_cli_deployment_plan.Fn -> Live_cronjob
  | Sol_cli_deployment_plan.Svc | Sol_cli_deployment_plan.Worker ->
    (match s.progressive_delivery with
     | Some _ -> Live_rollout
     | None -> Live_deployment)
;;

let read_jsonpath ~ctx ~resource ~name ~namespace ~jsonpath =
  match
    Sol_cli_process.check
      (Sol_cli_kubectl.get
         ~ctx
         ~resource
         ~name
         ~namespace
         ~output:("jsonpath=" ^ jsonpath))
  with
  | Ok r -> String.trim r.Sol_cli_process.stdout
  | _ -> ""
;;

(* ── live workload set ─────────────────────────────────────────────────────
   Verification compares the *set* of live Sol-owned workloads against the
   restored release's set, not only the workloads the release happens to
   mention. A release that added or removed a workload would otherwise leave the
   extra object running while the pointer claimed the restored release and
   verification reported clean -- exactly the inconsistent state the ticket
   requires be detectable. "Sol-owned" means "carries this workspace's taxonomy
   `workspace` label in its pod template", which every Sol-rendered workload
   does. A mismatched or missing workload still refuses outright -- pruning
   never runs unless those are clean, since neither is fixable by deleting
   something (FEAT-074): only a purely-[unexpected] surplus is ever pruned,
   by [execute], between this verification and the pointer move. *)

type workload_identity =
  { kind : live_kind
  ; namespace : string
  ; name : string
  }

(* Kind is part of the identity, not decoration: a release that switched a
   service from Deployment to Rollout keeps the same namespace/name, and the old
   Deployment is not pruned -- so an identity of (namespace, name) alone would
   treat the stale object as "expected" and miss it. *)
let same_identity a b =
  a.kind = b.kind && String.equal a.namespace b.namespace && String.equal a.name b.name
;;

let identity_of_spec (spec : Sol_cli_deployment_plan.service_spec) : workload_identity =
  { kind = live_kind_of_service spec
  ; namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace
  ; name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name
  }
;;

let json_member key = function
  | `Assoc kvs ->
    (match List.assoc_opt key kvs with
     | Some v -> v
     | None -> `Null)
  | _ -> `Null
;;

let json_at path json = List.fold_left (fun acc key -> json_member key acc) json path

let string_at path json =
  match json_at path json with
  | `String s -> s
  | _ -> ""
;;

(* The pod template's labels for a listed object, as an assoc list; [] when the
   object has none (never a crash). *)
let pod_template_labels kind item =
  match json_at (snd (live_kind_path kind)) item with
  | `Assoc kvs ->
    List.filter_map
      (fun (k, v) ->
         match v with
         | `String s -> Some (k, s)
         | _ -> None)
      kvs
  | _ -> []
;;

(* A pure extraction of the (identity, release-label) pairs a
   [kubectl get <kind> -A -o json] payload contributes for [workspace] -- the
   wire-path half of {!live_workloads}, kept separate so it is testable without
   a cluster. [workspace] is the *raw* workspace name; the label the renderer
   writes goes through {!Sol_cli_kubernetes_name.sanitize_label_value}, so the
   match must apply the same transform or a mixed-case workspace would match
   nothing. *)
let workload_rows_of_payload ~kind ~workspace (payload : Yojson.Safe.t) =
  let wanted = Sol_cli_kubernetes_name.sanitize_label_value workspace in
  let items =
    match json_member "items" payload with
    | `List l -> l
    | _ -> []
  in
  List.filter_map
    (fun item ->
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
    items
;;

(* List the live (identity, release-label) pairs for every Sol-owned workload in
   [workspace], across the three kinds Sol renders. Fails closed: a kind that
   cannot be enumerated (other than an absent Rollouts CRD) is an [Error], never
   an assumed-empty set. *)
let live_workloads ~(ctx : Sol_cli_kube_destination.context) ~(workspace : string)
  : ((workload_identity * string) list, string) result
  =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | kind :: rest ->
      let resource, _ = live_kind_path kind in
      (match
         Sol_cli_process.check
           (Sol_cli_kubectl.get_raw ~ctx ~args:[ "get"; resource; "-A"; "-o"; "json" ])
       with
       | Ok r ->
         (match Yojson.Safe.from_string r.Sol_cli_process.stdout with
          | exception Yojson.Json_error msg ->
            Error
              (Printf.sprintf "could not parse kubectl get %s output: %s" resource msg)
          | payload ->
            let rows = workload_rows_of_payload ~kind ~workspace payload in
            go (List.rev_append rows acc) rest)
       (* A cluster without the Rollouts CRD has no Rollout objects -- an empty set,
          not a failure. Any other failure fails closed: quietly treating an
          uncountable kind as empty could hide a stale workload. *)
       | Error (Sol_cli_process.Non_zero r) ->
         let output = Sol_cli_process.failure_output ~stdout:r.stdout ~stderr:r.stderr in
         if kind = Live_rollout && Sol_cli_kubectl.resource_type_absent output
         then go acc rest
         else Error (Printf.sprintf "kubectl get %s failed: %s" resource output)
       | Error e -> Error (Sol_cli_process.error_to_string e))
  in
  go [] [ Live_deployment; Live_rollout; Live_cronjob ]
;;

(* ── verification reports ─────────────────────────────────────────────────── *)

type workload_mismatch =
  { kind : live_kind
  ; namespace : string
  ; name : string
  ; actual : string (** [""] when the label or object could not be read at all. *)
  }

type workload_report =
  { mismatched : workload_mismatch list
    (** Expected workloads that exist but carry the wrong `release` label. *)
  ; missing : workload_identity list (** Expected workloads with no live object at all. *)
  ; unexpected : (workload_identity * string) list
    (** Live Sol-owned workloads that are not part of the restored release. *)
  }

let workload_report_ok (r : workload_report) =
  r.mismatched = [] && r.missing = [] && r.unexpected = []
;;

(* FEAT-074: the pure surplus computation, factored out of [verify_workloads]
   so [sol deploy]/[sol up] can reuse the exact same diff to report drift --
   one shared primitive for "what's live that isn't desired", not two
   implementations that can disagree. *)
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
           if String.equal actual release.Sol_cli_release.release_id
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

(* FEAT-074: delete each surplus workload's live object. Ownership is already
   established by construction -- every entry came from [live_workloads],
   which only enumerates objects carrying this workspace's own taxonomy
   label -- so no further ownership check is needed here. Scope is
   deliberately narrow: only the primary Deployment/Rollout/CronJob object,
   the one kind [live_workloads]/[verify_workloads] track. A removed
   service's other rendered objects (ConfigMap, Secret, PVC, Service,
   Ingress, NetworkPolicy, ServiceAccount) are left alone -- deleting a PVC
   automatically risks real data loss, and safely cleaning up the rest needs
   its own ownership/ordering design this ticket does not attempt. Each
   deletion is independent (no object here owns another via
   ownerReferences), so there is no ordering hazard among them; every
   deletion is attempted even if one fails, so one failure does not leave
   unrelated surplus objects behind for no reason. *)
let prune_workloads ~(ctx : Sol_cli_kube_destination.context) surplus
  : (unit, string) result
  =
  let errors =
    List.filter_map
      (fun ((id : workload_identity), _actual) ->
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
      surplus
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
    List.map
      (fun (m : workload_mismatch) ->
         Printf.sprintf
           "workload state mismatch: %s %s/%s carries release %s, expected %s"
           (kind_resource m.kind)
           m.namespace
           m.name
           (display_actual m.actual)
           release.Sol_cli_release.release_id)
      r.mismatched
  in
  let missing_lines =
    List.map
      (fun (i : workload_identity) ->
         Printf.sprintf
           "workload missing: %s %s/%s is not present in the cluster"
           (kind_resource i.kind)
           i.namespace
           i.name)
      r.missing
  in
  let unexpected_lines =
    List.map
      (fun ((i : workload_identity), actual) ->
         Printf.sprintf
           "unexpected workload: %s %s/%s carries release %s but is not part of release \
            %s"
           (kind_resource i.kind)
           i.namespace
           i.name
           (display_actual actual)
           release.Sol_cli_release.release_id)
      r.unexpected
  in
  String.concat "\n" (mismatch_lines @ missing_lines @ unexpected_lines)
;;

type pointer_report =
  { pointer_actual : string
  ; pointer_ok : bool
  }

(* [verify_pointer] reads the current-release pointer ConfigMap's
   [data.release_id] and compares it to [release]. Never re-applies or "fixes" a
   mismatch -- only reports it. *)
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
  { pointer_actual
  ; pointer_ok = String.equal pointer_actual release.Sol_cli_release.release_id
  }
;;

let pointer_report_ok (r : pointer_report) = r.pointer_ok

let pointer_report_to_string ~(release : Sol_cli_release.t) (r : pointer_report) : string =
  Printf.sprintf
    "pointer mismatch: %s names %s, expected %s"
    (Sol_cli_release.current_configmap_name ~workspace:release.workspace)
    (display_actual r.pointer_actual)
    release.Sol_cli_release.release_id
;;

(* FEAT-075: FEAT-066's load-bearing rollback ordering, extracted from
   cmd_rollback.ml so its order is testable. [deps] carries every step that
   touches the cluster or mutates anything; [execute] owns the sequence and
   the refusal logic, so a caller cannot reorder a mutation ahead of a check
   by construction -- only by choosing not to call [execute]. Reconstruction
   ([service_specs_of_release]) and the two boundary checks stay direct calls
   rather than deps: they are already pure/tested and take no cluster state
   beyond what the caller passes in.

   [prune] (FEAT-074) is called in the gap between the workload-set
   verification below and [deps.move_pointer], and only when that
   verification's mismatched/missing modes are clean -- neither is fixable by
   deleting something, so pruning never runs while either is present. *)
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
             release.Sol_cli_release.release_id)
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

(* FEAT-073: `sol rollback --commit <sha>` resolves against FEAT-070's
   deployment-event record — the authoritative store of (commit, release_id)
   provenance — never against the Loki deploy marker, which is telemetry. *)

(* Case-insensitive, either direction: a full sha resolving a stored short
   sha, or a user-typed short prefix resolving a full one. Empty on either
   side never matches -- a record with no captured commit (deployed outside a
   git checkout) must not be treated as matching every query. *)
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
  | Commit_ambiguous of (string * string) list (* (release_id, requested_scope) *)
  | Commit_resolved of string (* release_id *)

(* Only [Applied] deployment events name a release that was actually recorded
   (FEAT-072: release records are written only on a successful apply) --
   an [Apply_failed] attempt's [release_id] never has a corresponding release
   record, so resolving to it would send [sol rollback] straight into a
   "release not found" it could have refused up front. *)
let resolve_matches ~commit ~target ~scope_string (events : Sol_cli_deployment.t list)
  : commit_resolution
  =
  let matches =
    List.filter
      (fun (e : Sol_cli_deployment.t) ->
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
      events
  in
  (* Dedup by release_id: retried/repeated deploys of the same commit to the
     same scope name one release id more than once. *)
  let by_release_id = Hashtbl.create 8 in
  List.iter
    (fun (e : Sol_cli_deployment.t) ->
       let release_id = Sol_cli_release_id.to_string e.release_id in
       if not (Hashtbl.mem by_release_id release_id)
       then Hashtbl.add by_release_id release_id e.requested_scope)
    matches;
  match Hashtbl.fold (fun k v acc -> (k, v) :: acc) by_release_id [] with
  | [] -> Commit_no_match
  | [ (release_id, _) ] -> Commit_resolved release_id
  | candidates ->
    Commit_ambiguous (List.sort (fun (a, _) (b, _) -> String.compare a b) candidates)
;;

let resolve_commit ~commit ?scope ~target (events : Sol_cli_deployment.t list)
  : commit_resolution
  =
  if String.trim commit = ""
  then Commit_invalid "--commit must not be empty"
  else (
    let parsed_scope =
      Option.map
        (fun s -> Sol_cli_deployment_scope.parse_request ~what:"--scope" (Some s))
        scope
    in
    match parsed_scope with
    | Some (Error msg) -> Commit_invalid msg
    | None -> resolve_matches ~commit ~target ~scope_string:None events
    | Some (Ok request) ->
      resolve_matches
        ~commit
        ~target
        ~scope_string:(Some (Sol_cli_deployment_scope.request_to_string request))
        events)
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
         (List.map
            (fun (release_id, requested_scope) ->
               Printf.sprintf "  %s  (requested scope: %s)" release_id requested_scope)
            candidates))
  | Commit_resolved release_id ->
    Printf.sprintf "resolved %s to release %s" where release_id
;;
