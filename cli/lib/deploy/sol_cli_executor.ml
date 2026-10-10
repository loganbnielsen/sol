type result =
  { namespace : string
  ; name : string
  ; image : string
  }

type mode =
  | Dry_run
  | Emit_to of string
  | Apply

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

let local_development_spec (spec : Sol_cli_deployment_plan.service_spec) =
  let key = "SOL_ALLOW_UNVERIFIED_JWT" in
  { spec with config = (key, "1") :: List.remove_assoc key spec.config }
;;

let local ~ctx ~workspace ~release_id ~dry_run spec =
  let open Result.Syntax in
  let spec = local_development_spec spec in
  let* yaml = Sol_cli_deployment_render.render_spec ~workspace ~release_id spec in
  let* () = if dry_run then Ok () else Sol_cli_secret.verify_workload_secret ~ctx spec in
  dispatch_rendered ~ctx ~mode:(if dry_run then Dry_run else Apply) spec yaml
;;

let gitops ~ctx ~workspace ~release_id ~dir spec =
  Sol_cli_deployment_render.render_spec ~workspace ~release_id spec
  |> Fun.flip Result.bind (dispatch_rendered ~ctx ~mode:(Emit_to dir) spec)
;;

let write_release_bundle ~dir ~(apply_mode : Sol_cli_release.apply_mode) plan =
  let open Result.Syntax in
  let* () = Sol_cli_fs.mkdir_p dir in
  Sol_cli_release.bundle_files (Sol_cli_release.of_plan ~apply_mode plan)
  |> Sol_cli_result.map_list (fun (name, contents) ->
    Sol_cli_fs.write_atomic (Filename.concat dir name) contents)
  |> Result.map ignore
;;

let run_plan (execution : Sol_cli_execution.context) ~mode ?before_apply plan =
  let workspace = execution.workspace in
  let env = execution.env in
  let services = plan.Sol_cli_deployment_plan.services in
  let open Result.Syntax in
  (* Each workload carries its own immutable identity, not the target-wide release
     record id, so a deploy that changes one workload does not re-label and roll out
     the others. See [Sol_cli_deployment_plan.workload_release_id]. *)
  let render spec =
    let release_id =
      Sol_cli_deployment_plan.workload_release_id
        ~workspace:plan.Sol_cli_deployment_plan.workspace
        ~environment:plan.Sol_cli_deployment_plan.environment.env
        spec
    in
    Sol_cli_deployment_render.render_spec ~workspace ?env ~release_id spec
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
      let* () =
        match mode with
        | Apply ->
          let* () =
            Sol_cli_secret.verify_external_secret_destination ~ctx:execution.cluster spec
          in
          Sol_cli_secret.verify_workload_secret ~ctx:execution.cluster spec
        | Dry_run | Emit_to _ -> Ok ()
      in
      let* result = dispatch_rendered ~ctx:execution.cluster ~mode spec yaml in
      let* () =
        match mode with
        | Apply -> Sol_cli_secret.verify_external_secret_ready ~ctx:execution.cluster spec
        | Dry_run | Emit_to _ -> Ok ()
      in
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
