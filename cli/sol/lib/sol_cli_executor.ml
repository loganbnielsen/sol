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
  (match mode with
   | Dry_run -> Sol_cli_manifest.apply ~ctx yaml ~dry_run:true
   | Apply -> Sol_cli_manifest.apply ~ctx yaml ~dry_run:false
   | Emit_to dir ->
     let ns =
       Sol_cli_deployment_plan.namespace_to_string spec.Sol_cli_deployment_plan.namespace
     in
     let name =
       Sol_cli_deployment_plan.k8s_name_to_string spec.Sol_cli_deployment_plan.k8s_name
     in
     ignore (Sol_cli_manifest.emit_to_dir dir yaml ~ns ~name));
  make_result spec
;;

(* ── executors ───────────────────────────────────────────────────────────── *)

let local ~ctx ~workspace ~dry_run spec =
  match Sol_cli_deployment_render.render_spec ~workspace spec with
  | Error msg -> failwith msg
  | Ok yaml -> dispatch_rendered ~ctx ~mode:(if dry_run then Dry_run else Apply) spec yaml
;;

let gitops
      ~ctx
      ~workspace
      ~dir
      ?(secret_backend = Sol_cli_manifest.Kubernetes_placeholder)
      spec
  =
  match Sol_cli_deployment_render.render_spec ~workspace ~secret_backend spec with
  | Error msg -> failwith msg
  | Ok yaml -> dispatch_rendered ~ctx ~mode:(Emit_to dir) spec yaml
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
  (* Render all specs upfront; surface the first error before any side effect. *)
  let rendered =
    List.map
      (fun spec ->
         match
           Sol_cli_deployment_render.render_spec
             ~workspace
             ?env
             ~secret_backend:backend
             spec
         with
         | Error msg -> Error (spec, msg)
         | Ok yaml -> Ok (spec, yaml))
      services
  in
  match
    List.find_opt
      (function
        | Error _ -> true
        | Ok _ -> false)
      rendered
  with
  | Some (Error (_, msg)) -> Error msg
  | _ ->
    let pairs =
      List.filter_map
        (function
          | Ok x -> Some x
          | Error _ -> None)
        rendered
    in
    Ok
      (List.map
         (fun ((spec : Sol_cli_deployment_plan.service_spec), yaml) ->
            dispatch_rendered ~ctx:execution.cluster ~mode spec yaml)
         pairs)
;;
