(* Deployment executors — plan-in, side-effect-out.
   Each executor renders a service_spec to YAML and dispatches to the
   appropriate Sol_cli_manifest primitive.

   FEAT-063: applying is a Kubernetes operation, so the destination-side context
   is threaded through. [Emit_to] writes files and touches no cluster, but it
   takes the same parameter so the dispatch shape stays uniform. *)

type result =
  { namespace : string
  ; name : string
  ; image : string
  }

type mode =
  | Dry_run
  | Emit_to of string
  | Apply

(* ── helpers ─────────────────────────────────────────────────────────────── *)

let make_result (spec : Sol_cli_deployment_plan.service_spec) =
  { namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace
  ; name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name
  ; image = spec.image
  }
;;

let dispatch_rendered ~ctx ~mode spec yaml =
  let dispatched =
    match mode with
    | Dry_run -> Sol_cli_manifest.apply ~ctx yaml ~dry_run:true
    | Apply -> Sol_cli_manifest.apply ~ctx yaml ~dry_run:false
    | Emit_to dir ->
      let ns =
        Sol_cli_deployment_plan.namespace_to_string spec.Sol_cli_deployment_plan.namespace
      in
      let name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
      Sol_cli_manifest.emit_to_dir dir yaml ~ns ~name |> Result.map ignore
  in
  Result.map (fun () -> make_result spec) dispatched
;;

(* ── executors ───────────────────────────────────────────────────────────── *)

(* SEC-006: the local cluster is the one place a service may run
   [Unverified_dev_only] JWT auth, so only this executor renders the opt-in that
   [Service.Make.run] requires for it. [sol deploy] and GitOps emission never do. *)
let local_development_spec (spec : Sol_cli_deployment_plan.service_spec) =
  let key = "SOL_ALLOW_UNVERIFIED_JWT" in
  { spec with config = (key, "1") :: List.remove_assoc key spec.config }
;;

let local ~ctx ~workspace ~release_id ~dry_run spec =
  let spec = local_development_spec spec in
  Sol_cli_deployment_render.render_spec ~workspace ~release_id spec
  |> Fun.flip Result.bind (fun yaml ->
    dispatch_rendered ~ctx ~mode:(if dry_run then Dry_run else Apply) spec yaml)
;;

let gitops
      ~ctx
      ~workspace
      ~release_id
      ~dir
      ?(secret_backend = Sol_cli_manifest.Kubernetes_placeholder)
      spec
  =
  Sol_cli_deployment_render.render_spec ~workspace ~release_id ~secret_backend spec
  |> Fun.flip Result.bind (dispatch_rendered ~ctx ~mode:(Emit_to dir) spec)
;;

(* FEAT-069: the emitted bundle carries the release artifact — the immutable
   [sol-release-<id>] record and the current-release pointer — so the record
   travels with the manifests it describes instead of being a CLI side effect.
   [bundle_files] is pure in the plan's release identity, so re-emitting
   identical content is an empty diff. *)
let write_release_bundle ~dir ~(apply_mode : Sol_cli_release.apply_mode) plan =
  let open Result.Syntax in
  let* () = Sol_cli_fs.mkdir_p dir in
  Sol_cli_release.bundle_files (Sol_cli_release.of_plan ~apply_mode plan)
  |> Sol_cli_result.map_list (fun (name, contents) ->
    Sol_cli_fs.write_atomic (Filename.concat dir name) contents)
  |> Result.map ignore
;;

(* ── plan-level executor ─────────────────────────────────────────────────── *)

(* REFAC-089/FEAT-069: [run_plan] takes the *plan*, not a bare service list. Once
   the plan carries release identity -- which materially affects rendering -- the
   services alone are no longer the complete executable payload. Consuming the
   plan also means the executor reads decisions rather than re-deriving them: it
   must never reconstruct [release_id] from the plan. *)
let run_plan
      (execution : Sol_cli_execution.context)
      ~mode
      ?(secret_backend = Sol_cli_manifest.Kubernetes_placeholder)
      ?before_apply
      plan
  =
  let workspace = execution.workspace in
  let env = execution.env in
  let services = plan.Sol_cli_deployment_plan.services in
  let backend =
    match mode with
    | Emit_to _ -> Sol_cli_manifest.Kubernetes_placeholder
    | Dry_run | Apply -> secret_backend
  in
  let open Result.Syntax in
  (* Render all specs upfront; surface the first error before any side effect. *)
  let render spec =
    Sol_cli_deployment_render.render_spec
      ~workspace
      ?env
      ~release_id:plan.release_id
      ~secret_backend:backend
      spec
    |> Result.map (fun yaml -> spec, yaml)
  in
  let* pairs =
    services
    |> List.fold_left
         (fun acc spec ->
            let* rendered = acc in
            let* pair = render spec in
            Ok (pair :: rendered))
         (Ok [])
    |> Result.map List.rev
  in
  (* FEAT-072: [before_apply] runs between rendered workloads so a caller can
       refresh or lose a coordination lease before the next mutation; its error
       stops the run before that service is applied. *)
  let before_apply_result (spec : Sol_cli_deployment_plan.service_spec) =
    match mode with
    | Dry_run | Emit_to _ -> Ok ()
    | Apply ->
      (match before_apply with
       | None -> Ok ()
       | Some f -> f spec)
  in
  let rec execute acc = function
    | [] -> Ok (List.rev acc)
    | ((spec : Sol_cli_deployment_plan.service_spec), yaml) :: rest ->
      let* () = before_apply_result spec in
      let* result = dispatch_rendered ~ctx:execution.cluster ~mode spec yaml in
      execute (result :: acc) rest
  in
  let* results = execute [] pairs in
  let* () =
    match mode with
    | Emit_to dir -> write_release_bundle ~dir ~apply_mode:Sol_cli_release.Gitops plan
    | Dry_run | Apply -> Ok ()
  in
  Ok results
;;
