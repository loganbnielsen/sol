(* Deployment executors — plan-in, side-effect-out.
   Each executor renders a service_spec to YAML and dispatches to the
   appropriate Sol_cli_manifest primitive. *)

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

let dispatch_rendered ~mode spec yaml =
  (match mode with
   | Dry_run -> Sol_cli_manifest.apply yaml ~dry_run:true
   | Apply -> Sol_cli_manifest.apply yaml ~dry_run:false
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

let local ~workspace ~dry_run spec =
  match Sol_cli_deployment_render.render_spec ~workspace spec with
  | Error msg -> failwith msg
  | Ok yaml -> dispatch_rendered ~mode:(if dry_run then Dry_run else Apply) spec yaml
;;

let gitops
      ~workspace
      ~dir
      ?(secret_backend = Sol_cli_manifest.Kubernetes_placeholder)
      spec
  =
  match Sol_cli_deployment_render.render_spec ~workspace ~secret_backend spec with
  | Error msg -> failwith msg
  | Ok yaml -> dispatch_rendered ~mode:(Emit_to dir) spec yaml
;;

(* ── plan-level executor ─────────────────────────────────────────────────── *)

let run_plan
      ~workspace
      ?env
      ~mode
      ?(secret_backend = Sol_cli_manifest.Kubernetes_placeholder)
      services
  =
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
            dispatch_rendered ~mode spec yaml)
         pairs)
;;
